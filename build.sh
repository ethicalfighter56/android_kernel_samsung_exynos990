#!/bin/bash

# Error Handling
abort() {
    echo "-----------------------------------------------"
    echo "Kernel compilation failed! Exiting..."
    echo "-----------------------------------------------"
    exit -1
}

# Argument Handling
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model|-m) MODEL="$2"; shift 2 ;;
        --ksu|-k)   KSU_OPTION="$2"; shift 2 ;;
        --recovery|-r) RECOVERY_OPTION="$2"; shift 2 ;;
        *) echo "Invalid option"; exit 1 ;;
    esac
done

echo "Preparing the build environment..."
pushd $(dirname "$0") > /dev/null
CORES=$(nproc --all)

# ==================== Clang 16 Setup ====================
# Ensure the Clang 16 binaries exist in your repository at this path
export PATH="$PWD/toolchain/clang_16/bin:$PATH"

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
ARCH=arm64 \
O=out \
CLANG_TRIPLE=aarch64-linux-gnu- \
CROSS_COMPILE=aarch64-linux-android- \
CROSS_COMPILE_ARM32=arm-linux-androideabi-"

# Suppression of warnings specific to Clang 16 for older kernel sources
export KCFLAGS="-Wno-error=implicit-function-declaration \
-Wno-error=strict-prototypes \
-Wno-error=incompatible-pointer-types \
-Wno-error=implicit-int-float-conversion \
-Wno-inline-optimize -fno-strict-aliasing"

# ==================== Model Config ====================
KERNEL_DEFCONFIG=exynos9830_defconfig

case $MODEL in
    r8s)    BOARD=SRPTF26B014KU ;;
    *) echo "Unknown model! Only r8s is configured for this run."; exit 1 ;;
esac

# Config file handling
[[ "$RECOVERY_OPTION" == "y" ]] && RECOVERY=recovery.config && KSU_OPTION=n
[[ "$KSU_OPTION" == "y" ]] && KSU=ksu.config

# Cleanup previous builds
rm -rf out
mkdir -p out/$MODEL/zip/files
mkdir -p out/$MODEL/zip/META-INF/com/google/android

echo "-----------------------------------------------"
echo "Building for  : $MODEL"
echo "Clang Version : $(clang --version | head -n 1)"
echo "-----------------------------------------------"

# 1. Generate Configuration
make ${MAKE_ARGS} $KERNEL_DEFCONFIG $MODEL.config $KSU $RECOVERY || abort

# 2. Start Compilation (with ThinLTO)
echo "Building full kernel with ThinLTO..."
make ${MAKE_ARGS} -j$CORES || abort

# ==================== Packaging ====================
echo "Creating flashable zip..."

# Set paths according to output directory
DTB_PATH=out/$MODEL/dtb.img
KERNEL_PATH=out/arch/arm64/boot/Image
DTBO_PATH=out/arch/arm64/boot/dtbo.img
RAMDISK=out/$MODEL/ramdisk.cpio.gz
OUTPUT_FILE=out/$MODEL/boot.img

# Generate DTB/DTBO images
./toolchain/mkdtimg cfg_create $DTB_PATH build/dtconfigs/exynos9830.cfg -d out/arch/arm64/boot/dts/exynos || echo "DTB skip"
./toolchain/mkdtimg cfg_create out/$MODEL/dtbo.img build/dtconfigs/$MODEL.cfg -d out/arch/arm64/boot/dts/samsung || echo "DTBO skip"

# Build Ramdisk if directory exists
if [ -d "build/ramdisk" ]; then
    pushd build/ramdisk > /dev/null
    find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > ../../$RAMDISK
    popd > /dev/null
fi

# Create Boot Image
./toolchain/mkbootimg --base 0x10000000 --board $BOARD --cmdline "androidboot.hardware=exynos990 loop.max_part=7" \
--dtb $DTB_PATH --header_version 2 --kernel $KERNEL_PATH \
--os_patch_level 2025-08 --os_version 16.0.0 --pagesize 2048 \
--ramdisk $RAMDISK -o $OUTPUT_FILE || abort

# Stage files for ZIP
cp $OUTPUT_FILE out/$MODEL/zip/files/boot.img
cp out/$MODEL/dtbo.img out/$MODEL/zip/files/dtbo.img
[ -f "build/update-binary" ] && cp build/update-binary out/$MODEL/zip/META-INF/com/google/android/update-binary
[ -f "build/updater-script" ] && cp build/updater-script out/$MODEL/zip/META-INF/com/google/android/updater-script

# Final ZIP compression
pushd out/$MODEL/zip > /dev/null
DATE=$(date +"%d-%m-%Y")
ZIP_NAME="ArtisanKRNL_${MODEL}_${DATE}.zip"
zip -r -qq ../"$ZIP_NAME" .
popd > /dev/null

popd > /dev/null
echo "Build finished! File: out/$MODEL/$ZIP_NAME"
