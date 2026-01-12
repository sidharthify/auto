#!/usr/bin/env bash

set -e

### configuration

# kernel tree
ROOT_DIR="$(pwd)"
KERNEL_DIR="${ROOT_DIR}/aosp"

# out dirs
OUT_DIR="${KERNEL_DIR}/out"
MODULES_STAGING_DIR="${OUT_DIR}/modules_staging"

# image
IMAGE_LZ4="${OUT_DIR}/arch/arm64/boot/Image.lz4"
IMAGE_RAW="${OUT_DIR}/arch/arm64/boot/Image"

# AOSP (adjust if your rom source is elsewhere)
ROM_DIR="${HOME}/yaap"
PREBUILT_KERNEL_DIR="${ROM_DIR}/device/google/pantah-kernels/6.1"

# tools
LLVM_DIR="${ROOT_DIR}/linux-x86/clang-r487747c/bin/"
TOOL_ARGS=(LLVM="${LLVM_DIR}")
MAGISKBOOT="${ROOT_DIR}/magiskboot"
MKBOOTIMG="${ROM_DIR}/system/tools/mkbootimg/mkbootimg.py"
MKDTBOIMG="${ROM_DIR}/system/tools/mkbootimg/mkdtboimg.py"

# attempt to find avbtool, fallback to PATH
AVBTOOL="${ROM_DIR}/external/avb/avbtool.py"
if [ ! -f "${AVBTOOL}" ]; then AVBTOOL="avbtool"; fi
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

echo "========================================"
echo "Starting Kernel Build"
echo "========================================"

cd "${KERNEL_DIR}"

# build kernel and dtbs
echo "   [build] Generating config..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" gs201_defconfig

# overwrite source defconfig with full config (from auto2)
cp -v "${OUT_DIR}/.config" "arch/arm64/configs/gs201_defconfig"

echo "   [build] Compiling kernel..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" kernelrelease
make -j"$(nproc)" "${TOOL_ARGS[@]}"
make -j"$(nproc)" "${TOOL_ARGS[@]}" dtbs

# check image presence
if [ ! -f "${IMAGE_LZ4}" ]; then
    echo "ERROR: image.lz4 missing!"
    exit 1
fi

# ensure raw image exists for repack
if [ ! -f "${IMAGE_RAW}" ]; then
    echo "   [info] Decompressing LZ4 image..."
    lz4 -d -f "${IMAGE_LZ4}" "${IMAGE_RAW}"
fi

# build modules
echo "   [build] Compiling modules..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" modules
make -j"$(nproc)" "${TOOL_ARGS[@]}" INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" modules_install

#####
#####
# KSU
#####
#####

echo "========================================"
echo "KernelSU Selection"
echo "========================================"

# We are inside aosp/ but we need to reference the root for ksu.sh
read -p "   Do you want to build KernelSU? (y/n): " build_ksu_choice
KSU_KO_PATH=""

if [[ "$build_ksu_choice" =~ ^[Yy]$ ]]; then
    echo "   1) KernelSU (Standard)"
    echo "   2) KernelSU-Next"
    read -p "   Select variant [1/2]: " ksu_variant

    KSU_SCRIPT="${ROOT_DIR}/ksu.sh"

    if [ -f "${KSU_SCRIPT}" ]; then
        if [ "$ksu_variant" == "2" ]; then
            bash "${KSU_SCRIPT}" next
            KSU_KO_PATH="${OUT_DIR}/kernelsu_next.ko"
        else
            bash "${KSU_SCRIPT}" standard
            KSU_KO_PATH="${OUT_DIR}/kernelsu.ko"
        fi
    else
        echo "   [WARN] ksu.sh not found at ${KSU_SCRIPT}. Skipping KSU build."
    fi
else
    echo "   [info] Skipping KernelSU."
fi

#####
#####
# prepare staging
#####
#####

KERNEL_VER=$(cat "${OUT_DIR}/include/config/kernel.release")
DLKM_STAGING="${OUT_DIR}/dlkm_staging"
echo "   [info] Kernel Version: ${KERNEL_VER}"
echo "   [info] Cleaning staging dir: ${DLKM_STAGING}"
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

echo "========================================"
echo "Sorting & Stripping Modules"
echo "========================================"

find "${MODULES_STAGING_DIR}" -type f -name "*.ko" | sort | while read -r module; do
    mod_name=$(basename "${module}")

    # check existing blocklist file
    if grep -q "^${mod_name}" "${BLOCKLIST}" 2>/dev/null; then continue; fi

    # exclude all these
    case "${mod_name}" in
        btpower.ko|cnss2.ko|cnss_nl.ko|cnss_plat_ipc_qmi_svc.ko|cnss_prealloc.ko|cnss_utils.ko|drv2624.ko|gcip.ko|goodix_brl_touch.ko|google_wlan_mac.ko|iovad-vendor-hooks.ko|mhi.ko|ufs-pixel-fips140.ko|panel-samsung-s6e3fc3-l10.ko|panel-samsung-s6e3fc5.ko|qmi_helpers.ko|qrtr.ko|qrtr-mhi.ko|wlan_firmware_service.ko|wlan.ko|zram.ko)
            echo "   [drop] ${mod_name} (excluded)"
            continue
            ;;
    esac

    if grep -Fq "${mod_name}" "${VKB_LIST}"; then
        DEST="${DLKM_STAGING}/vendor_kernel_boot"
        echo "   [VKB]  ${mod_name}"
    elif grep -Fq "${mod_name}" "${VDLKM_LIST}"; then
        DEST="${DLKM_STAGING}/vendor_dlkm"
        echo "   [V_DLKM] ${mod_name}"
    else
        DEST="${DLKM_STAGING}/system_dlkm"
        echo "   [S_DLKM] ${mod_name}"
    fi

    # copy and strip
    cp "${module}" "${DEST}/lib/modules/${KERNEL_VER}/"
    "${STRIP_BIN}" --strip-debug "${DEST}/lib/modules/${KERNEL_VER}/${mod_name}"
done

# === injection for KSU ===
if [ -n "$KSU_KO_PATH" ] && [ -f "$KSU_KO_PATH" ]; then
    echo "   [inject] Found built KSU module: $(basename "$KSU_KO_PATH")"
    cp "$KSU_KO_PATH" "${DLKM_STAGING}/system_dlkm/lib/modules/${KERNEL_VER}/"
    echo "      -> Copied to system_dlkm"
fi

#####
#####
# re-sign modules
#####
#####

echo "========================================"
echo "Re-signing Modules"
echo "========================================"

# check if required files exist
SIGN_FILE="${OUT_DIR}/scripts/sign-file"
SIGN_KEY="${OUT_DIR}/certs/signing_key.pem"
SIGN_CERT="${OUT_DIR}/certs/signing_key.x509"

if [ -f "${SIGN_FILE}" ] && [ -f "${SIGN_KEY}" ] && [ -f "${SIGN_CERT}" ]; then
    find "${DLKM_STAGING}" -type f -name "*.ko" | while read -r module; do
        echo "   [sign] $(basename "${module}")"
        "${SIGN_FILE}" sha1 "${SIGN_KEY}" "${SIGN_CERT}" "${module}"
    done
else
    echo "   [WARN] signing tools or keys not found. skipping module signing."
fi

#####
#####
# generate dependency maps & modules.load
#####
#####

echo "========================================"
echo "Generating Metadata"
echo "========================================"

SRC_METADATA="${MODULES_STAGING_DIR}/lib/modules/${KERNEL_VER}"
for part in vendor_kernel_boot vendor_dlkm system_dlkm; do
    echo "   [meta] Processing ${part}..."
    TARGET_DIR="${DLKM_STAGING}/${part}/lib/modules/${KERNEL_VER}"

    # copy metadata
    cp "${SRC_METADATA}/modules.builtin" "${TARGET_DIR}/"
    cp "${SRC_METADATA}/modules.builtin.modinfo" "${TARGET_DIR}/"
    cp "${SRC_METADATA}/modules.order" "${TARGET_DIR}/"

    # generate modules.load
    (
        cd "${TARGET_DIR}"
        find . -maxdepth 1 -name "*.ko" | sed 's|^\./||' | sort > modules.load
        echo "      Generated modules.load with $(wc -l < modules.load) entries."
    )

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

echo "========================================"
echo "Packing Images"
echo "========================================"

# erofs for dlkms
echo "   [img] Building vendor_dlkm.img..."
mkfs.erofs -z lz4hc "${OUT_DIR}/vendor_dlkm.img" "${DLKM_STAGING}/vendor_dlkm"

echo "   [img] Building system_dlkm.img..."
mkfs.erofs -z lz4hc "${OUT_DIR}/system_dlkm.img" "${DLKM_STAGING}/system_dlkm"

# AVB Hash Footer
# this is critical for the partitions to mount
if command -v python3 &>/dev/null && [ -f "${AVBTOOL}" ]; then
    echo "   [avb] Signing vendor_dlkm..."
    python3 "${AVBTOOL}" add_hashtree_footer \
        --partition_name vendor_dlkm \
        --hash_algorithm sha256 \
        --image "${OUT_DIR}/vendor_dlkm.img"

    echo "   [avb] Signing system_dlkm..."
    python3 "${AVBTOOL}" add_hashtree_footer \
        --partition_name system_dlkm \
        --hash_algorithm sha256 \
        --image "${OUT_DIR}/system_dlkm.img"
else
    echo "   [WARN] avbtool not found! Images might not mount."
fi


# combine dtbs
echo "   [dtb] Combining DTBs..."
DTB_PATHS=("${OUT_DIR}/arch/arm64/boot/dts/google/gs201" "${OUT_DIR}/google-devices/gs201/dts" "${OUT_DIR}/arch/arm64/boot/dts/google")
DTB_SOURCE=""
for path in "${DTB_PATHS[@]}"; do
    if [ -d "$path" ] && compgen -G "$path/*.dtb" > /dev/null; then DTB_SOURCE="$path"; break; fi
done
echo "      Source: ${DTB_SOURCE}"
cat "${DTB_SOURCE}"/*.dtb > "${OUT_DIR}/combined.dtb"

# generate dtbo
if [ -f "${MKDTBOIMG}" ]; then
    echo "   [dtbo] Generating dtbo.img..."
    DTBO_FILES=$(find "${DTB_SOURCE}" -name "*.dtbo")
    if [ -n "${DTBO_FILES}" ]; then python3 "${MKDTBOIMG}" create "${OUT_DIR}/dtbo.img" ${DTBO_FILES}; fi
fi

# vendor ramdisk and boot image
echo "   [ramdisk] Creating vendor ramdisk..."
( cd "${DLKM_STAGING}/vendor_kernel_boot" && find . | cpio -H newc -o 2>/dev/null | lz4 -l -12 --favor-decSpeed > "${OUT_DIR}/vendor_ramdisk.cpio.lz4" )

echo "   [boot] Creating vendor_kernel_boot.img..."
python3 "${MKBOOTIMG}" --vendor_ramdisk "${OUT_DIR}/vendor_ramdisk.cpio.lz4" --dtb "${OUT_DIR}/combined.dtb" --header_version 4 --vendor_boot "${OUT_DIR}/vendor_kernel_boot.img"

#####
#####
# repack boot.img
#####
#####

echo "========================================"
echo "Repacking boot.img"
echo "========================================"

if [ ! -f "${MAGISKBOOT}" ]; then echo "magiskboot not found!"; exit 1; fi
if [ ! -f "${PREBUILT_KERNEL_DIR}/boot.img" ]; then echo "source boot.img not found!"; exit 1; fi

rm -rf "${OUT_DIR}/boot_repack" && mkdir -p "${OUT_DIR}/boot_repack"
echo "   [copy] Fetching stock boot.img..."
cp "${PREBUILT_KERNEL_DIR}/boot.img" "${OUT_DIR}/boot_repack/"

(
    cd "${OUT_DIR}/boot_repack"
    echo "   [unpack] Unpacking boot.img..."
    "${MAGISKBOOT}" unpack boot.img > /dev/null

    # replace kernel
    echo "   [replace] Swapping kernel..."
    cp -f "${IMAGE_RAW}" kernel

    echo "   [repack] Repacking boot.img..."
    "${MAGISKBOOT}" repack boot.img > /dev/null
)

mv -f "${OUT_DIR}/boot_repack/new-boot.img" "${OUT_DIR}/boot.img"

#####
#####
# sync to prebuilts
#####
#####

echo "========================================"
echo "Syncing to Prebuilts"
echo "========================================"

safe_copy() {
    if [ -f "$1" ]; then
        echo "   [sync] $(basename "$1")"
        cp -f "$1" "$2"
    else
        echo "   [WARN] missing $1"
    fi
}

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
    echo "   [sync] DTB files..."
    cp -r "${DTB_SOURCE}"/*.dtb "${PREBUILT_KERNEL_DIR}/" 2>/dev/null || true
    cp -r "${DTB_SOURCE}"/*.dtbo "${PREBUILT_KERNEL_DIR}/" 2>/dev/null || true
fi

# sync modules
echo "   [clean] Removing old modules from prebuilts..."
find "${PREBUILT_KERNEL_DIR}" -name "*.ko" -delete

echo "   [sync] Copying new modules..."
find "${DLKM_STAGING}" -name "*.ko" -print -exec cp -fv {} "${PREBUILT_KERNEL_DIR}/" \; | sed 's|^|      |'

# sync insmod configs
echo "   [sync] Insmod configs..."
for variant in cheetah cloudripper panther ravenclaw; do
    find "${KERNEL_DIR}" -name "init.insmod.${variant}.cfg" -exec cp -f {} "${PREBUILT_KERNEL_DIR}/" \; 2>/dev/null || true
done

# sync metadata
safe_copy "${OUT_DIR}/System.map" "${PREBUILT_KERNEL_DIR}/"
safe_copy "${OUT_DIR}/.config" "${PREBUILT_KERNEL_DIR}/"
cp -v "${SRC_METADATA}/modules.builtin" "${PREBUILT_KERNEL_DIR}/"
cp -v "${SRC_METADATA}/modules.builtin.modinfo" "${PREBUILT_KERNEL_DIR}/"

# archives
echo "   [archive] Creating vendor_dlkm archive..."
tar -czf "${PREBUILT_KERNEL_DIR}/vendor_dlkm_staging_archive.tar.gz" -C "${DLKM_STAGING}/vendor_dlkm/lib/modules/${KERNEL_VER}" . 2>/dev/null || true

echo "========================================"
echo "Done!"
echo "========================================"
