#!/usr/bin/env bash

set -e

### configuration

# kernel tree
ROOT_DIR="/home/sidharthify/kernel"
KERNEL_DIR="${ROOT_DIR}/aosp"

# out dirs
OUT_DIR="${KERNEL_DIR}/out"
MODULES_STAGING_DIR="${OUT_DIR}/modules_staging"

# image
IMAGE_LZ4="${OUT_DIR}/arch/arm64/boot/Image.lz4"
IMAGE_RAW="${OUT_DIR}/arch/arm64/boot/Image"

# AOSP
ROM_DIR="/home/sidharthify/yaap"
PREBUILT_KERNEL_DIR="${ROM_DIR}/device/google/pantah-kernels/6.1"

# tools
LLVM_DIR="${ROOT_DIR}/linux-x86/clang-r487747c/bin/"
TOOL_ARGS=(LLVM="${LLVM_DIR}")
MAGISKBOOT="${ROOT_DIR}/magiskboot"
MKBOOTIMG="${ROM_DIR}/system/tools/mkbootimg/mkbootimg.py"
MKDTBOIMG="${ROM_DIR}/system/tools/mkbootimg/mkdtboimg.py"
STRIP_BIN="${LLVM_DIR}llvm-strip"

# build lists
BUILD_CONFIG_DIR="${KERNEL_DIR}/build_config"
VKB_LIST="${BUILD_CONFIG_DIR}/vendor_kernel_boot.txt"
VDLKM_LIST="${BUILD_CONFIG_DIR}/vendor_dlkm.txt"
SDLKM_LIST="${BUILD_CONFIG_DIR}/system_dlkm.txt"
BLOCKLIST="${BUILD_CONFIG_DIR}/blocklist.txt"

#####
#####
# build kernel & dtbs
#####
#####

cd "${KERNEL_DIR}"

# build kernel and dtbs
make -j"$(nproc)" "${TOOL_ARGS[@]}" gs201_defconfig

# overwrite source defconfig with full config (from auto2)
cp "${OUT_DIR}/.config" "arch/arm64/configs/gs201_defconfig"

make -j"$(nproc)" "${TOOL_ARGS[@]}" kernelrelease
make -j"$(nproc)" "${TOOL_ARGS[@]}"
make -j"$(nproc)" "${TOOL_ARGS[@]}" dtbs

# check image presence
if [ ! -f "${IMAGE_LZ4}" ]; then
    echo "image.lz4 missing!"
    exit 1
fi

# ensure raw image exists for repack
if [ ! -f "${IMAGE_RAW}" ]; then
    lz4 -d -f "${IMAGE_LZ4}" "${IMAGE_RAW}"
fi

# build modules
make -j"$(nproc)" "${TOOL_ARGS[@]}" modules
make -j"$(nproc)" "${TOOL_ARGS[@]}" INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" modules_install

#####
#####
# prepare staging
#####
#####

KERNEL_VER=$(cat "${OUT_DIR}/include/config/kernel.release")
DLKM_STAGING="${OUT_DIR}/dlkm_staging"
rm -rf "${DLKM_STAGING}"

# create partition paths
for part in vendor_kernel_boot vendor_dlkm system_dlkm; do
    mkdir -p "${DLKM_STAGING}/${part}/lib/modules/${KERNEL_VER}"
done

#####
#####
# sort & strip modules
#####
#####

echo "sorting modules..."

find "${MODULES_STAGING_DIR}" -type f -name "*.ko" | while read -r module; do
    mod_name=$(basename "${module}")
    
    # check blocklist
    if grep -q "^${mod_name}" "${BLOCKLIST}" 2>/dev/null; then continue; fi

    # determine destination
    if grep -Fq "${mod_name}" "${VKB_LIST}"; then DEST="${DLKM_STAGING}/vendor_kernel_boot"
    elif grep -Fq "${mod_name}" "${VDLKM_LIST}"; then DEST="${DLKM_STAGING}/vendor_dlkm"
    else DEST="${DLKM_STAGING}/system_dlkm"; fi
    
    # copy and strip
    cp "${module}" "${DEST}/lib/modules/${KERNEL_VER}/"
    "${STRIP_BIN}" --strip-debug "${DEST}/lib/modules/${KERNEL_VER}/${mod_name}"
done

#####
#####
# generate dependency maps
#####
#####

echo "generating depmaps..."

SRC_METADATA="${MODULES_STAGING_DIR}/lib/modules/${KERNEL_VER}"
for part in vendor_kernel_boot vendor_dlkm system_dlkm; do
    TARGET_DIR="${DLKM_STAGING}/${part}/lib/modules/${KERNEL_VER}"
    
    # copy metadata
    cp "${SRC_METADATA}/modules.builtin" "${TARGET_DIR}/"
    cp "${SRC_METADATA}/modules.builtin.modinfo" "${TARGET_DIR}/"
    cp "${SRC_METADATA}/modules.order" "${TARGET_DIR}/"
    
    # run depmod
    depmod -b "${DLKM_STAGING}/${part}" "${KERNEL_VER}"
    
    # cleanup
    rm -f "${TARGET_DIR}/modules.alias" "${TARGET_DIR}/modules.symbols"
done

#####
#####
# pack images
#####
#####

echo "packing images..."

# erofs for dlkms
mkfs.erofs -z lz4hc "${OUT_DIR}/vendor_dlkm.img" "${DLKM_STAGING}/vendor_dlkm"
mkfs.erofs -z lz4hc "${OUT_DIR}/system_dlkm.img" "${DLKM_STAGING}/system_dlkm"

# combine dtbs
DTB_PATHS=("${OUT_DIR}/arch/arm64/boot/dts/google/gs201" "${OUT_DIR}/google-devices/gs201/dts" "${OUT_DIR}/arch/arm64/boot/dts/google")
DTB_SOURCE=""
for path in "${DTB_PATHS[@]}"; do
    if [ -d "$path" ] && compgen -G "$path/*.dtb" > /dev/null; then DTB_SOURCE="$path"; break; fi
done
cat "${DTB_SOURCE}"/*.dtb > "${OUT_DIR}/combined.dtb"

# generate dtbo
if [ -f "${MKDTBOIMG}" ]; then
    DTBO_FILES=$(find "${DTB_SOURCE}" -name "*.dtbo")
    if [ -n "${DTBO_FILES}" ]; then python3 "${MKDTBOIMG}" create "${OUT_DIR}/dtbo.img" ${DTBO_FILES}; fi
fi

# vendor ramdisk and boot image
( cd "${DLKM_STAGING}/vendor_kernel_boot" && find . | cpio -H newc -o 2>/dev/null | lz4 -l -12 --favor-decSpeed > "${OUT_DIR}/vendor_ramdisk.cpio.lz4" )
python3 "${MKBOOTIMG}" --vendor_ramdisk "${OUT_DIR}/vendor_ramdisk.cpio.lz4" --dtb "${OUT_DIR}/combined.dtb" --header_version 4 --vendor_boot "${OUT_DIR}/vendor_kernel_boot.img"

#####
#####
# repack boot.img
#####
#####

echo "repacking boot.img..."

if [ ! -f "${MAGISKBOOT}" ]; then echo "magiskboot not found!"; exit 1; fi
if [ ! -f "${PREBUILT_KERNEL_DIR}/boot.img" ]; then echo "source boot.img not found!"; exit 1; fi

rm -rf "${OUT_DIR}/boot_repack" && mkdir -p "${OUT_DIR}/boot_repack"
cp "${PREBUILT_KERNEL_DIR}/boot.img" "${OUT_DIR}/boot_repack/"

(
    cd "${OUT_DIR}/boot_repack"
    "${MAGISKBOOT}" unpack boot.img > /dev/null
    
    # replace kernel
    cp -f "${IMAGE_RAW}" kernel
    
    "${MAGISKBOOT}" repack boot.img > /dev/null
)

mv -f "${OUT_DIR}/boot_repack/new-boot.img" "${OUT_DIR}/boot.img"

#####
#####
# sync to prebuilts
#####
#####

echo "syncing files..."

safe_copy() { if [ -f "$1" ]; then cp -f "$1" "$2"; else echo "   [warn] missing $1"; fi }

# sync images
safe_copy "${OUT_DIR}/boot.img" "${PREBUILT_KERNEL_DIR}/"
safe_copy "${OUT_DIR}/vendor_dlkm.img" "${PREBUILT_KERNEL_DIR}/"
safe_copy "${OUT_DIR}/system_dlkm.img" "${PREBUILT_KERNEL_DIR}/"
safe_copy "${OUT_DIR}/vendor_kernel_boot.img" "${PREBUILT_KERNEL_DIR}/"
safe_copy "${OUT_DIR}/dtbo.img" "${PREBUILT_KERNEL_DIR}/"
safe_copy "${OUT_DIR}/vendor_ramdisk.cpio.lz4" "${PREBUILT_KERNEL_DIR}/initramfs.img"

# sync kernel
safe_copy "${IMAGE_LZ4}" "${PREBUILT_KERNEL_DIR}/"

# sync dtbs
if [ -d "${DTB_SOURCE}" ]; then
    cp -r "${DTB_SOURCE}"/*.dtb "${PREBUILT_KERNEL_DIR}/" 2>/dev/null || true
    cp -r "${DTB_SOURCE}"/*.dtbo "${PREBUILT_KERNEL_DIR}/" 2>/dev/null || true
fi

# sync modules
find "${DLKM_STAGING}" -name "*.ko" -exec cp -f {} "${PREBUILT_KERNEL_DIR}/" \;
find "${MODULES_STAGING_DIR}" -name "iovad-vendor-hooks.ko" -exec cp -f {} "${PREBUILT_KERNEL_DIR}/" \; 2>/dev/null || true

# sync insmod configs
for variant in cheetah cloudripper panther ravenclaw; do
    if [ ! -f "${PREBUILT_KERNEL_DIR}/init.insmod.${variant}.cfg" ]; then
         find "${KERNEL_DIR}" -name "init.insmod.${variant}.cfg" -exec cp -f {} "${PREBUILT_KERNEL_DIR}/" \; 2>/dev/null || true
    fi
done

# sync metadata
safe_copy "${OUT_DIR}/System.map" "${PREBUILT_KERNEL_DIR}/"
safe_copy "${OUT_DIR}/.config" "${PREBUILT_KERNEL_DIR}/"
cp -f "${SRC_METADATA}/modules.builtin" "${PREBUILT_KERNEL_DIR}/"
cp -f "${SRC_METADATA}/modules.builtin.modinfo" "${PREBUILT_KERNEL_DIR}/"

# generate load lists
gen_list() {
    local input="$1"; local output="$2"; > "$output"
    sort -u "$input" | while read -r mod; do
        if [ -f "${PREBUILT_KERNEL_DIR}/$(basename "$mod")" ]; then echo "$mod" >> "$output"; fi
    done
}
gen_list "${VKB_LIST}" "${PREBUILT_KERNEL_DIR}/vendor_kernel_boot.modules.load"
gen_list "${VDLKM_LIST}" "${PREBUILT_KERNEL_DIR}/vendor_dlkm.modules.load"
gen_list "${SDLKM_LIST}" "${PREBUILT_KERNEL_DIR}/system_dlkm.modules.load"

# archives
tar -czf "${PREBUILT_KERNEL_DIR}/vendor_dlkm_staging_archive.tar.gz" -C "${DLKM_STAGING}/vendor_dlkm/lib/modules/${KERNEL_VER}" . 2>/dev/null || true

echo "done!"