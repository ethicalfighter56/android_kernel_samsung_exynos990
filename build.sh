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
 
