#!/bin/bash

abort()
{
    cd -
    echo "-----------------------------------------------"
    echo "Kernel compilation failed! Exiting..."
    echo "-----------------------------------------------"
    exit -1
}

while ; do
    case "$1" in
        --model|-m) MODEL="$2"; shift 2 ;;
        --ksu|-k)   KSU_OPTION="$2"; shift 2 ;;
        --recovery|-r) RECOVERY_OPTION="$2"; shift 2 ;;
        --dtbs|-d) DTB_OPTION="$2"; shift 2 ;;
        *) echo "Invalid option!"; exit 1 ;;
    esac
done

echo "=== Extreme Kernel Build Started ==="
pushd $(dirname "$0") > /dev/null
CORES=$(nproc --all)

# ==================== Clang 16 Setup ====================
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

export KCFLAGS="-Wno-error=implicit-function-declaration -Wno-error=strict-prototypes"

# ==================== Default r8s + Always KSU ====================
MODEL=${MODEL:-r8s}
KSU_OPTION=${KSU_OPTION:-y}
KSU=ksu.config

case $MODEL in
    r8s) BOARD=SRPTF26B014KU ;;
    *)
        echo "Unknown model! Using default r8s"
        MODEL=r8s
        BOARD=SRPTF26B014KU
        ;;
esac

rm -rf out/$MODEL
mkdir -p out/$MODEL/zip/files
mkdir -p out/$MODEL/zip/META-INF/com/google/android

echo "-----------------------------------------------"
echo "Model         : $MODEL"
echo "KernelSU      : Enabled"
echo "Defconfig     : extreme_$MODEL_defconfig"
echo "Clang Version : $(clang --version | head -n 1)"
echo "-----------------------------------------------"

make ${MAKE_ARGS} -j$CORES exynos9830_defconfig $MODEL.config $KSU || abort

echo "Building full kernel..."
make ${MAKE_ARGS} -j$CORES || abort

echo "Creating boot image and zip..."

./toolchain/mkdtimg cfg_create out/$MODEL/dtb.img build/dtconfigs/exynos9830.cfg -d out/arch/arm64/boot/dts/exynos
./toolchain/mkdtimg cfg_create out/$MODEL/dtbo.img build/dtconfigs/$MODEL.cfg -d out/arch/arm64/boot/dts/samsung

pushd build/ramdisk > /dev/null
find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > ../out/$MODEL/ramdisk.cpio.gz || abort
popd > /dev/null

./toolchain/mkbootimg --base 0x10000000 --board $BOARD --cmdline "androidboot.hardware=exynos990 loop.max_part=7" \
--dtb out/$MODEL/dtb.img --dtb_offset 0x00000000 --hashtype sha1 --header_version 2 --kernel out/arch/arm64/boot/Image \
--kernel_offset 0x00008000 --os_patch_level 2025-08 --os_version 16.0.0 --pagesize 2048 \
--ramdisk out/$MODEL/ramdisk.cpio.gz --ramdisk_offset 0x01000000 --second_offset 0xF0000000 --tags_offset 0x00000100 \
-o out/$MODEL/boot.img || abort

cp out/$MODEL/boot.img out/$MODEL/zip/files/boot.img
cp out/$MODEL/dtbo.img out/$MODEL/zip/files/dtbo.img
cp build/update-binary out/$MODEL/zip/META-INF/com/google/android/update-binary
cp build/updater-script out/$MODEL/zip/META-INF/com/google/android/updater-script

version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' arch/arm64/configs/exynos9830_defconfig | cut -d '"' -f 2 | sed 's/^=//')
pushd out/$MODEL/zip > /dev/null
DATE=$(date +"%d-%m-%Y_%H-%M")
NAME="\( {version}_r8s_KSU_ \){DATE}.zip"
zip -r -qq ../"$NAME" .
popd > /dev/null

popd > /dev/null
echo "✅ Build finished successfully! Output: out/r8s/${NAME}"
