#!/bin/bash

# --- ERROR HANDLING ---
abort() {
    echo "-------------------------------------------------------"
    echo " ERROR: Build failed! Check logs above."
    echo "-------------------------------------------------------"
    exit 1
}

# --- ARGUMENT PARSING ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model|-m) MODEL="$2"; shift 2 ;;
        --ksu|-k) KSU_OPTION="$2"; shift 2 ;;
        --recovery|-r) RECOVERY_OPTION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "Starting build for $MODEL..."
pushd $(dirname "$0") > /dev/null
CORES=$(nproc --all)

# --- 1. TOOLCHAIN SETUP (Clang 18) ---
CLANG_DIR=$PWD/toolchain/clang_18
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r522817.tar.gz"

if [ ! -f "$CLANG_DIR/bin/clang" ]; then
    echo "--> Downloading Clang 18..."
    mkdir -p "$CLANG_DIR"
    curl -fL "$CLANG_URL" -o "$CLANG_DIR/clang.tar.gz" || abort
    tar -xf "$CLANG_DIR/clang.tar.gz" -C "$CLANG_DIR" || abort
    rm "$CLANG_DIR/clang.tar.gz"
fi

export PATH="$CLANG_DIR/bin:$PATH"

# --- 2. KERNELSU-NEXT LEGACY INTEGRATION ---
if [[ "$KSU_OPTION" == "y" ]]; then
    echo "--> Integrating KernelSU-Next Legacy branch..."
    KSUN_REPO="https://github.com/KernelSU-Next/KernelSU-Next"
    rm -rf drivers/kernelsu
    git clone -b legacy "$KSUN_REPO" drivers/kernelsu || abort
    
    # Structural fix for legacy branch Kconfig
    if [ -f "drivers/kernelsu/kernel/Kconfig" ]; then
        ln -sf ./kernel/Kconfig drivers/kernelsu/Kconfig
        ln -sf ./kernel/Makefile drivers/kernelsu/Makefile
    fi
    # Ensure KSU is enabled in defconfig
    grep -q "CONFIG_KSU=y" arch/arm64/configs/exynos9830_defconfig || echo "CONFIG_KSU=y" >> arch/arm64/configs/exynos9830_defconfig
fi

# --- 3. MAKE ARGUMENTS & COMPATIBILITY ---
MAKE_ARGS="
LLVM=1 \
LLVM_IAS=1 \
CC=clang \
LD=ld.lld \
AR=llvm-ar \
NM=llvm-nm \
OBJCOPY=llvm-objcopy \
OBJDUMP=llvm-objdump \
STRIP=llvm-strip \
READELF=llvm-readelf \
HOSTCC=clang \
HOSTCXX=clang++ \
HOSTLD=ld.lld \
ARCH=arm64 \
O=out \
CLANG_TRIPLE=aarch64-linux-gnu- \
CROSS_COMPILE=aarch64-linux-android- \
CROSS_COMPILE_ARM32=arm-linux-androideabi-"

# Suppression flags for Clang 18 strictness on Kernel 4.19
export KCFLAGS="-Wno-error=implicit-function-declaration \
-Wno-error=strict-prototypes \
-Wno-error=incompatible-pointer-types \
-Wno-error=int-conversion \
-Wno-error=return-type \
-Wno-error=unused-variable \
-Wno-unused-command-line-argument \
-fno-strict-aliasing"

# --- 4. BUILD EXECUTION ---
case $MODEL in
    r8s) BOARD="SRPTF26B014KU" ;;
    *) echo "Unsupported model: $MODEL"; exit 1 ;;
esac

# Workspace cleanup
rm -rf out && rm -rf build/out/$MODEL
mkdir -p build/out/$MODEL/zip/files
mkdir -p build/out/$MODEL/zip/META-INF/com/google/android

echo "--> Running Config..."
make ${MAKE_ARGS} -j$CORES exynos9830_defconfig "$MODEL.config" || abort

echo "--> Compiling Kernel..."
make ${MAKE_ARGS} -j$CORES || abort

# --- 5. PACKAGING ---
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "--> Compilation successful. Packaging ZIP..."
    cp out/arch/arm64/boot/Image build/out/$MODEL/Image
    
    # Generate DTB/DTBO
    ./toolchain/mkdtimg cfg_create build/out/$MODEL/dtb.img build/dtconfigs/exynos9830.cfg -d out/arch/arm64/boot/dts/exynos
    ./toolchain/mkdtimg cfg_create build/out/$MODEL/dtbo.img build/dtconfigs/$MODEL.cfg -d out/arch/arm64/boot/dts/samsung

    # Ramdisk Processing
    pushd build/ramdisk > /dev/null
    find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > ../out/$MODEL/ramdisk.cpio.gz
    popd > /dev/null

    # Create boot.img
    ./toolchain/mkbootimg --base 0x10000000 --board "$BOARD" --header_version 2 \
    --dtb build/out/$MODEL/dtb.img --kernel build/out/$MODEL/Image \
    --ramdisk build/out/$MODEL/ramdisk.cpio.gz --os_patch_level 2025-08 \
    --os_version 16.0.0 --pagesize 2048 -o build/out/$MODEL/boot.img || abort

    # ZIP Assembly
    cp build/out/$MODEL/boot.img build/out/$MODEL/zip/files/boot.img
    cp build/out/$MODEL/dtbo.img build/out/$MODEL/zip/files/dtbo.img
    cp build/update-binary build/out/$MODEL/zip/META-INF/com/google/android/update-binary
    cp build/updater-script build/out/$MODEL/zip/META-INF/com/google/android/updater-script

    pushd build/out/$MODEL/zip > /dev/null
    ZIP_NAME="ArtisanKRNL_${MODEL}_$(date +"%d%m%Y_%H%M").zip"
    zip -r -qq ../"$ZIP_NAME" .
    popd > /dev/null
    echo "--> Build Complete: $ZIP_NAME"
fi

popd > /dev/null
