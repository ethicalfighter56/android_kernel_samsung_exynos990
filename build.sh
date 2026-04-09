#!/bin/bash

abort()
{
    cd -
    echo "-----------------------------------------------"
    echo "Kernel compilation failed! Exiting..."
    echo "-----------------------------------------------"
    exit -1
}

unset_flags()
{
    cat << EOF
Usage: $(basename "$0") [options]
Options:
    -m, --model [value]    Specify the model code of the phone
    -k, --ksu [y/N]        Include KernelSU
    -r, --recovery [y/N]   Compile kernel for an Android Recovery
    -d, --dtbs [y/N]	   Compile only DTBs
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model|-m)
            MODEL="$2"
            shift 2
            ;;
        --ksu|-k)
            KSU_OPTION="$2"
            shift 2
            ;;
        --recovery|-r)
            RECOVERY_OPTION="$2"
            shift 2
            ;;
        --dtbs|-d)
            DTB_OPTION="$2"
            shift 2
            ;;
        *)\
            unset_flags
            exit 1
            ;;
    esac
done

echo "Preparing the build environment..."

pushd $(dirname "$0") > /dev/null
CORES=$(nproc --all)

# --- ROBUST CLANG 18 TOOLCHAIN SETUP ---
CLANG_DIR=$PWD/toolchain/clang_18
# Verified AOSP Clang 18.x (r522817) URL
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r522817.tar.gz"

if [ ! -f "$CLANG_DIR/bin/clang" ]; then
    echo "-----------------------------------------------"
    echo "Clang 18 not found or incomplete! Downloading..."
    echo "-----------------------------------------------"
    rm -rf "$CLANG_DIR"
    mkdir -p "$CLANG_DIR"
    
    # Download with -f to fail if the URL is 404 and -L for redirects
    curl -fL "$CLANG_URL" -o "$CLANG_DIR/clang-18.tar.gz" || { echo "Download failed!"; exit 1; }
    
    tar -xf "$CLANG_DIR/clang-18.tar.gz" -C "$CLANG_DIR" || { echo "Extraction failed!"; exit 1; }
    rm "$CLANG_DIR/clang-18.tar.gz"
    echo "Toolchain ready."
fi

# Export PATH so all sub-processes (like make) can see the tools
export PATH="$CLANG_DIR/bin:$PATH"

# --- UPDATED MAKE ARGUMENTS ---
# Explicitly defining LLVM tools prevents the "not found" errors
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

# Bypass Clang 18 strictness for the Exynos 990 4.19 kernel
export KCFLAGS="-Wno-error=implicit-function-declaration \
-Wno-error=strict-prototypes \
-Wno-error=incompatible-pointer-types \
-Wno-error=int-conversion \
-Wno-error=return-type \
-Wno-unused-command-line-argument"

# --- REST OF YOUR ORIGINAL LOGIC ---
KERNEL_DEFCONFIG=extreme_"$MODEL"_defconfig
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
*)
    unset_flags
    exit
esac

if [[ "$RECOVERY_OPTION" == "y" ]]; then
    RECOVERY=recovery.config
    KSU_OPTION=n
fi

if [ -z $KSU_OPTION ]; then
    read -p "Include KernelSU (y/N): " KSU_OPTION
fi

if [[ "$KSU_OPTION" == "y" ]]; then
    KSU=ksu.config
fi

if [[ "$DTB_OPTION" == "y" ]]; then
	DTBS=y
fi

rm -rf build/out/$MODEL
mkdir -p build/out/$MODEL/zip/files
mkdir -p build/out/$MODEL/zip/META-INF/com/google/android

echo "-----------------------------------------------"
echo "Defconfig: "$KERNEL_DEFCONFIG""
echo "Clang Version: $(clang --version | head -n 1)"
echo "-----------------------------------------------"

# Configuration step
make ${MAKE_ARGS} -j$CORES exynos9830_defconfig $MODEL.config $KSU $RECOVERY || abort

if [ ! -z "$DTBS" ]; then
    echo "Building DTBs..."
    make ${MAKE_ARGS} -j$CORES dtbs || abort
else
    echo "Building kernel..."
    make ${MAKE_ARGS} -j$CORES || abort
fi

# --- IMAGE PACKAGING (REMAINS THE SAME) ---
DTB_PATH=build/out/$MODEL/dtb.img
KERNEL_PATH=build/out/$MODEL/Image
KERNEL_OFFSET=0x00008000
DTB_OFFSET=0x00000000
RAMDISK_OFFSET=0x01000000
SECOND_OFFSET=0xF0000000
TAGS_OFFSET=0x00000100
BASE=0x10000000
CMDLINE='androidboot.hardware=exynos990 loop.max_part=7'
HASHTYPE=sha1
HEADER_VERSION=2
OS_PATCH_LEVEL=2025-08
OS_VERSION=16.0.0
PAGESIZE=2048
RAMDISK=build/out/$MODEL/ramdisk.cpio.gz
OUTPUT_FILE=build/out/$MODEL/boot.img

if [ -z "$DTBS" ]; then
    cp out/arch/arm64/boot/Image build/out/$MODEL
fi

./toolchain/mkdtimg cfg_create build/out/$MODEL/dtb.img build/dtconfigs/exynos9830.cfg -d out/arch/arm64/boot/dts/exynos
./toolchain/mkdtimg cfg_create build/out/$MODEL/dtbo.img build/dtconfigs/$MODEL.cfg -d out/arch/arm64/boot/dts/samsung

if [ -z "$RECOVERY" ] && [ -z "$DTBS" ]; then
    pushd build/ramdisk > /dev/null
     find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > ../out/$MODEL/ramdisk.cpio.gz || abort
    popd > /dev/null

     ./toolchain/mkbootimg --base $BASE --board $BOARD --cmdline "$CMDLINE" --dtb $DTB_PATH \
    --dtb_offset $DTB_OFFSET --hashtype $HASHTYPE --header_version $HEADER_VERSION --kernel $KERNEL_PATH \
    --kernel_offset $KERNEL_OFFSET --os_patch_level $OS_PATCH_LEVEL --os_version $OS_VERSION --pagesize $PAGESIZE \
    --ramdisk $RAMDISK --ramdisk_offset $RAMDISK_OFFSET \
    --second_offset $SECOND_OFFSET --tags_offset $TAGS_OFFSET -o $OUTPUT_FILE || abort

    cp build/out/$MODEL/boot.img build/out/$MODEL/zip/files/boot.img
    cp build/out/$MODEL/dtbo.img build/out/$MODEL/zip/files/dtbo.img
    cp build/update-binary build/out/$MODEL/zip/META-INF/com/google/android/update-binary
    cp build/updater-script build/out/$MODEL/zip/META-INF/com/google/android/updater-script

    version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' arch/arm64/configs/exynos9830_defconfig | cut -d '"' -f 2)
    version=${version:1}
    pushd build/out/$MODEL/zip > /dev/null
    DATE=`date +"%d-%m-%Y_%H-%M-%S"`
    NAME="$version"_"$MODEL"_UNOFFICIAL_$( [[ "$KSU_OPTION" == "y" ]] && echo "KSU_" )$DATE.zip
    zip -r -qq ../"$NAME" .
    popd > /dev/null
fi

popd > /dev/null
echo "Build finished successfully!"
KERNEL_DEFCONFIG=extreme_"$MODEL"_defconfig
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
*)
    unset_flags
    exit
esac

if [[ "$RECOVERY_OPTION" == "y" ]]; then
    RECOVERY=recovery.config
    KSU_OPTION=n
fi

if [ -z $KSU_OPTION ]; then
    read -p "Include KernelSU (y/N): " KSU_OPTION
fi

if [[ "$KSU_OPTION" == "y" ]]; then
    KSU=ksu.config
fi

if [[ "$DTB_OPTION" == "y" ]]; then
	DTBS=y
fi

rm -rf build/out/$MODEL
mkdir -p build/out/$MODEL/zip/files
mkdir -p build/out/$MODEL/zip/META-INF/com/google/android

echo "-----------------------------------------------"
echo "Defconfig: "$KERNEL_DEFCONFIG""
echo "Clang Version: $(clang --version | head -n 1)"
echo "-----------------------------------------------"

# Configuration step
make ${MAKE_ARGS} -j$CORES exynos9830_defconfig $MODEL.config $KSU $RECOVERY || abort

if [ ! -z "$DTBS" ]; then
    echo "Building DTBs..."
    make ${MAKE_ARGS} -j$CORES dtbs || abort
else
    echo "Building kernel..."
    make ${MAKE_ARGS} -j$CORES || abort
fi

# --- IMAGE PACKAGING (REMAINS THE SAME) ---
DTB_PATH=build/out/$MODEL/dtb.img
KERNEL_PATH=build/out/$MODEL/Image
KERNEL_OFFSET=0x00008000
DTB_OFFSET=0x00000000
RAMDISK_OFFSET=0x01000000
SECOND_OFFSET=0xF0000000
TAGS_OFFSET=0x00000100
BASE=0x10000000
CMDLINE='androidboot.hardware=exynos990 loop.max_part=7'
HASHTYPE=sha1
HEADER_VERSION=2
OS_PATCH_LEVEL=2025-08
OS_VERSION=16.0.0
PAGESIZE=2048
RAMDISK=build/out/$MODEL/ramdisk.cpio.gz
OUTPUT_FILE=build/out/$MODEL/boot.img

if [ -z "$DTBS" ]; then
    cp out/arch/arm64/boot/Image build/out/$MODEL
fi

./toolchain/mkdtimg cfg_create build/out/$MODEL/dtb.img build/dtconfigs/exynos9830.cfg -d out/arch/arm64/boot/dts/exynos
./toolchain/mkdtimg cfg_create build/out/$MODEL/dtbo.img build/dtconfigs/$MODEL.cfg -d out/arch/arm64/boot/dts/samsung

if [ -z "$RECOVERY" ] && [ -z "$DTBS" ]; then
    pushd build/ramdisk > /dev/null
     find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > ../out/$MODEL/ramdisk.cpio.gz || abort
    popd > /dev/null

     ./toolchain/mkbootimg --base $BASE --board $BOARD --cmdline "$CMDLINE" --dtb $DTB_PATH \
    --dtb_offset $DTB_OFFSET --hashtype $HASHTYPE --header_version $HEADER_VERSION --kernel $KERNEL_PATH \
    --kernel_offset $KERNEL_OFFSET --os_patch_level $OS_PATCH_LEVEL --os_version $OS_VERSION --pagesize $PAGESIZE \
    --ramdisk $RAMDISK --ramdisk_offset $RAMDISK_OFFSET \
    --second_offset $SECOND_OFFSET --tags_offset $TAGS_OFFSET -o $OUTPUT_FILE || abort

    cp build/out/$MODEL/boot.img build/out/$MODEL/zip/files/boot.img
    cp build/out/$MODEL/dtbo.img build/out/$MODEL/zip/files/dtbo.img
    cp build/update-binary build/out/$MODEL/zip/META-INF/com/google/android/update-binary
    cp build/updater-script build/out/$MODEL/zip/META-INF/com/google/android/updater-script

    version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' arch/arm64/configs/exynos9830_defconfig | cut -d '"' -f 2)
    version=${version:1}
    pushd build/out/$MODEL/zip > /dev/null
    DATE=`date +"%d-%m-%Y_%H-%M-%S"`
    NAME="$version"_"$MODEL"_UNOFFICIAL_$( [[ "$KSU_OPTION" == "y" ]] && echo "KSU_" )$DATE.zip
    zip -r -qq ../"$NAME" .
    popd > /dev/null
fi

popd > /dev/null
echo "Build finished successfully!"
 
