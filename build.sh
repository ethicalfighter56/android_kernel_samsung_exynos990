#!/bin/bash

# Error Handling
abort() {
    echo "-----------------------------------------------"
    echo "Kernel compilation failed! Exiting..."
    echo "-----------------------------------------------"
    exit -1
}

# Display Usage
show_usage() {
    cat << EOF
Usage: $(basename "$0") [options]
Options:
    -m, --model [value]    Specify phone model (e.g., r8s)
    -k, --ksu [y/N]        Include KernelSU
    -r, --recovery [y/N]   Compile for Recovery
    -d, --dtbs [y/N]       Compile only DTBs
EOF
}

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model|-m) MODEL="$2"; shift 2 ;;
        --ksu|-k) KSU_OPTION="$2"; shift 2 ;;
        --recovery|-r) RECOVERY_OPTION="$2"; shift 2 ;;
        --dtbs|-d) DTB_OPTION="$2"; shift 2 ;;
        *) show_usage; exit 1 ;;
    esac
done

if [ -z "$MODEL" ]; then
    echo "Error: Model not specified!"
    show_usage; exit 1
fi

echo "Preparing build environment..."
pushd $(dirname "$0") > /dev/null
CORES=$(nproc --all)

# --- TOOLCHAIN SETUP ---
# Path for GitHub Actions toolchain
CLANG_DIR=$PWD/toolchain/clang_18
export PATH="$CLANG_DIR/bin:$PATH"

# Only download if Clang is missing (Local build fallback)
if [ ! -f "$CLANG_DIR/bin/clang" ]; then
    echo "Clang 18 not found locally. Downloading..."
    mkdir -p "$CLANG_DIR"
    CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r522817.tar.gz"
    curl -fL "$CLANG_URL" -o "$CLANG_DIR/clang.tar.gz" || exit 1
    tar -xf "$CLANG_DIR/clang.tar.gz" -C "$CLANG_DIR"
    rm "$CLANG_DIR/clang.tar.gz"
fi

# --- COMPILER ARGUMENTS ---
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

# Suppression flags for Clang 18 vs 4.19 Kernel
export KCFLAGS="-Wno-error=implicit-function-declaration \
-Wno-error=strict-prototypes \
-Wno-error=incompatible-pointer-types \
-Wno-error=int-conversion \
-Wno-error=return-type \
-Wno-unused-command-line-argument"

# --- MODEL CONFIGURATION ---
case $MODEL in
    x1slte) BOARD=SRPSJ28B018KU ;;
    x1s)    BOARD=SRPSI19A018KU ;;
    y2slte) BOARD=SRPSJ28A018KU ;;
    y2s)    BOARD=SRPSG12A018KU ;;
    z3s)    BOARD=SRPSI19B018KU ;;
    c1slte) BOARD=SRPTC30B009KU ;;
    c1s)    BOARD=SRPTB27D009KU ;;
    c2slte) BOARD=SRPTC30A009KU ;;
    c2s)    BOARD=SRPTB27C009KU ;;
    r8s)    BOARD=SRPTF26B014KU ;;
    *) echo "Unknown model!"; exit 1 ;;
esac

# Build Features
[[ "$RECOVERY_OPTION" == "y" ]] && RECOVERY=recovery.config && KSU_OPTION=n
[[ "$KSU_OPTION" == "y" ]] && KSU=ksu.config

# Setup Output Folders
OUT_DIR=build/out/$MODEL
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/zip/files"
mkdir -p "$OUT_DIR/zip/META-INF/com/google/android"

echo "-----------------------------------------------"
echo "Model: $MODEL | Board: $BOARD"
echo "Clang: $(clang --version | head -n 1)"
echo "-----------------------------------------------"

# Step 1: Configuration
make ${MAKE_ARGS} -j$CORES exynos9830_defconfig $MODEL.config $KSU $RECOVERY || abort

# Step 2: Build
if [[ "$DTB_OPTION" == "y" ]]; then
    echo "Building DTBs only..."
    make ${MAKE_ARGS} -j$CORES dtbs || abort
else
    echo "Building full kernel..."
    make ${MAKE_ARGS} -j$CORES || abort
    cp out/arch/arm64/boot/Image "$OUT_DIR/Image"
fi

# Step 3: DTB/DTBO
./toolchain/mkdtimg cfg_create "$OUT_DIR/dtb.img" build/dtconfigs/exynos9830.cfg -d out/arch/arm64/boot/dts/exynos
./toolchain/mkdtimg cfg_create "$OUT_DIR/dtbo.img" build/dtconfigs/$MODEL.cfg -d out/arch/arm64/boot/dts/samsung

# Step 4: Flashable Zip (only for full builds)
if [[ -z "$RECOVERY" && -z "$DTB_OPTION" ]]; then
    if [ -d "build/ramdisk" ]; then
        pushd build/ramdisk > /dev/null
        find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > ../out/$MODEL/ramdisk.cpio.gz || abort
        popd > /dev/null
    fi

    ./toolchain/mkbootimg --base 0x10000000 --board $BOARD --header_version 2 \
    --dtb "$OUT_DIR/dtb.img" --kernel "$OUT_DIR/Image" --ramdisk "$OUT_DIR/ramdisk.cpio.gz" \
    --os_patch_level 2025-08 --os_version 16.0.0 --pagesize 2048 \
    -o "$OUT_DIR/boot.img" || abort

    # Packaging
    cp "$OUT_DIR/boot.img" "$OUT_DIR/zip/files/boot.img"
    cp "$OUT_DIR/dtbo.img" "$OUT_DIR/zip/files/dtbo.img"
    [ -f "build/update-binary" ] && cp build/update-binary "$OUT_DIR/zip/META-INF/com/google/android/update-binary"
    [ -f "build/updater-script" ] && cp build/updater-script "$OUT_DIR/zip/META-INF/com/google/android/updater-script"

    pushd "$OUT_DIR/zip" > /dev/null
    DATE=$(date +"%d-%m-%Y_%H-%M")
    ZIP_NAME="ArtisanKRNL_${MODEL}_${DATE}.zip"
    zip -r -qq ../"$ZIP_NAME" .
    popd > /dev/null
fi

popd > /dev/null
echo "Build finished successfully!"
 
