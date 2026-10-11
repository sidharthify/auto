#!/usr/bin/env bash

set -e

### configuration

# kernel tree
ROOT_DIR="$(pwd)"
KERNEL_DIR="${ROOT_DIR}/gs201"

# kernel version
KERNEL_MAJOR=$(sed -n 's/^VERSION = *//p' "${KERNEL_DIR}/Makefile" | head -n1)
KERNEL_MINOR=$(sed -n 's/^PATCHLEVEL = *//p' "${KERNEL_DIR}/Makefile" | head -n1)
KERNEL_BRANCH="${KERNEL_MAJOR}.${KERNEL_MINOR}"

# out dirs
OUT_DIR="${KERNEL_DIR}/out"
MODULES_STAGING_DIR="${OUT_DIR}/modules_staging"

# image
IMAGE_LZ4="${OUT_DIR}/arch/arm64/boot/Image.lz4"
IMAGE_RAW="${OUT_DIR}/arch/arm64/boot/Image"

# AOSP
ROM_DIR="${HOME}/yaap"
PREBUILT_KERNEL_DIR="${ROM_DIR}/device/google/pantah-kernels/${KERNEL_BRANCH}"
if [ ! -d "${PREBUILT_KERNEL_DIR}" ]; then
    mkdir -p "${PREBUILT_KERNEL_DIR}"
fi

# user@host in the kernel version, no matter which machine builds it
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-sidharthify}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-nixos}"

# tools
if [ "${KERNEL_BRANCH}" = "6.12" ]; then
    LLVM_DIR="${ROOT_DIR}/linux-x86/clang-r536225/bin/"
    if [ ! -d "${LLVM_DIR}" ]; then
        LLVM_DIR="${HOME}/kernel612/linux-x86/clang-r536225/bin/"
    fi
else
    LLVM_DIR="${ROOT_DIR}/linux-x86/clang-r487747c/bin/"
fi
TOOL_ARGS=(LLVM="${LLVM_DIR}")
MAGISKBOOT="${ROOT_DIR}/magiskboot"
MKBOOTIMG="${ROM_DIR}/system/tools/mkbootimg/mkbootimg.py"
MKDTIMG="${ROM_DIR}/prebuilts/kernel-build-tools/linux-x86/bin/mkdtimg"

# avbtool
AVBTOOL="${ROM_DIR}/external/avb/avbtool.py"
if [ ! -f "${AVBTOOL}" ]; then AVBTOOL="avbtool"; fi
STRIP_BIN="${LLVM_DIR}llvm-strip"

# build lists
BUILD_CONFIG_DIR="${KERNEL_DIR}/build_config"
VKB_LIST="${BUILD_CONFIG_DIR}/vendor_kernel_boot.txt"
VDLKM_LIST="${BUILD_CONFIG_DIR}/vendor_dlkm.txt"
SDLKM_LIST="${BUILD_CONFIG_DIR}/system_dlkm.txt"
BLOCKLIST="${BUILD_CONFIG_DIR}/blocklist.txt"

# dtbo overlays, packed in the same order kleaf uses
if [ "${KERNEL_BRANCH}" = "6.12" ]; then
    DTBO_DTS_DIR="google-modules/soc/gs/arch/arm64/boot/dts/google"
    DTBO_DIR="${OUT_DIR}/${DTBO_DTS_DIR}"
    DTBO_ORDER="${KERNEL_DIR}/google-modules/soc/gs/arch/arm64/boot/dts/google/Makefile"
else
    DTBO_DTS_DIR="google-devices/pantah/dts"
    DTBO_DIR="${OUT_DIR}/${DTBO_DTS_DIR}"
    DTBO_ORDER="${KERNEL_DIR}/google-devices/pantah/constants.bzl"
fi

#####
#####
# build kernel & dtbs
#####
#####

echo "========================================"
echo "Starting Kernel Build (${KERNEL_BRANCH})"
echo "========================================"

cd "${KERNEL_DIR}"

# build kernel
echo "   [build] Generating config..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" gs201_defconfig
cp -v "${OUT_DIR}/.config" "arch/arm64/configs/gs201_defconfig"

echo "   [build] Compiling kernel..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" kernelrelease
make -j"$(nproc)" "${TOOL_ARGS[@]}"
make -j"$(nproc)" "${TOOL_ARGS[@]}" dtbs
if [ "${KERNEL_BRANCH}" != "6.12" ]; then
    make -j"$(nproc)" "${TOOL_ARGS[@]}" dtstree="${DTBO_DTS_DIR}" dtbs
fi
if [ "${KERNEL_BRANCH}" = "6.12" ]; then
    make -j"$(nproc)" "${TOOL_ARGS[@]}" Image.lz4
fi

if [ ! -f "${IMAGE_LZ4}" ]; then
    echo "ERROR: image.lz4 missing!"
    exit 1
fi

if [ ! -f "${IMAGE_RAW}" ]; then
    echo "   [info] Decompressing LZ4 image..."
    lz4 -d -f "${IMAGE_LZ4}" "${IMAGE_RAW}"
fi

# build modules
echo "   [build] Compiling modules..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" modules
# modules_install never removes anything, so modules dropped from the
# build would otherwise keep getting shipped from earlier runs
rm -rf "${MODULES_STAGING_DIR}"
make -j"$(nproc)" "${TOOL_ARGS[@]}" INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" modules_install

#####
#####
# KSU
#####
#####

echo "========================================"
echo "KernelSU Selection"
echo "========================================"

# KSU=n|1|2|3|4 answers the prompts below for non-interactive builds
ksu_variant=""
if [ -n "${KSU}" ]; then
    case "${KSU}" in
        [Nn]) build_ksu_choice="n" ;;
        *) build_ksu_choice="y"; ksu_variant="${KSU}" ;;
    esac
else
    read -p "   Do you want to build KernelSU? (y/n): " build_ksu_choice
fi
KSU_KO_INJECT_PATH=""
KSU_SAVE_DIR="${ROOT_DIR}/KSU"
KSU_SCRIPT="${ROOT_DIR}/ksu.sh"

if [[ "$build_ksu_choice" =~ ^[Yy]$ ]]; then
    if [ ! -f "${KSU_SCRIPT}" ]; then
        echo "   [ERROR] ksu.sh not found at ${KSU_SCRIPT}"
        exit 1
    fi

    # create save dir
    mkdir -p "${KSU_SAVE_DIR}"

    if [ -z "${ksu_variant}" ]; then
        echo "   1) KernelSU (Standard)"
        echo "   2) KernelSU-Next"
        echo "   3) KernelSU-Wild"
        echo "   4) All"
        read -p "   Select variant [1/2/3/4]: " ksu_variant
    fi

    case "$ksu_variant" in
        1)
            bash "${KSU_SCRIPT}" standard
            cp "${OUT_DIR}/kernelsu.ko" "${KSU_SAVE_DIR}/kernelsu.ko"
            KSU_KO_INJECT_PATH="${KSU_SAVE_DIR}/kernelsu.ko"
            ;;
        2)
            bash "${KSU_SCRIPT}" next
            cp "${OUT_DIR}/kernelsu_next.ko" "${KSU_SAVE_DIR}/kernelsu_next.ko"
            KSU_KO_INJECT_PATH="${KSU_SAVE_DIR}/kernelsu_next.ko"
            ;;
        3)
            bash "${KSU_SCRIPT}" wild
            cp "${OUT_DIR}/kernelsu_wild.ko" "${KSU_SAVE_DIR}/kernelsu_wild.ko"
            KSU_KO_INJECT_PATH="${KSU_SAVE_DIR}/kernelsu_wild.ko"
            ;;
        4)
            echo "   [both] Building Standard..."
            bash "${KSU_SCRIPT}" standard
            cp "${OUT_DIR}/kernelsu.ko" "${KSU_SAVE_DIR}/kernelsu.ko"
            
            echo "   [both] Building Next..."
            bash "${KSU_SCRIPT}" next
            cp "${OUT_DIR}/kernelsu_next.ko" "${KSU_SAVE_DIR}/kernelsu_next.ko"

            echo "   [both] Building Wild..."
            bash "${KSU_SCRIPT}" wild
            cp "${OUT_DIR}/kernelsu_wild.ko" "${KSU_SAVE_DIR}/kernelsu_wild.ko"

            echo "   ---------------------------------"
            echo "   All modules saved to: ${KSU_SAVE_DIR}/"
    esac
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
    if grep -q "^${mod_name}" "${BLOCKLIST}" 2>/dev/null; then continue; fi

    # exclude list
    case "${mod_name}" in
        btpower.ko|cnss2.ko|cnss_nl.ko|cnss_plat_ipc_qmi_svc.ko|cnss_prealloc.ko|cnss_utils.ko|drv2624.ko|goodix_brl_touch.ko|google_wlan_mac.ko|mhi.ko|ufs-pixel-fips140.ko|panel-samsung-s6e3fc3-l10.ko|panel-samsung-s6e3fc5.ko|qmi_helpers.ko|qrtr.ko|qrtr-mhi.ko|wlan_firmware_service.ko|wlan.ko)
            echo "   [drop] ${mod_name} (excluded)"
            continue
            ;;
    esac

    # 6.1 ships Pixel's zram_gs instead of the GKI zram. 6.12 has no zram_gs,
    # so it keeps the GKI one.
    if [ "${KERNEL_BRANCH}" != "6.12" ] && [ "${mod_name}" = "zram.ko" ]; then
        echo "   [drop] ${mod_name} (excluded)"
        continue
    fi

    # the 6.12 GKI config also builds kunit suites and other test modules;
    # only ship the ones the partition lists ask for, like on 6.1
    if [ "${KERNEL_BRANCH}" = "6.12" ]; then
        case "${mod_name}" in
            *test*.ko|*kunit*.ko|regmap-ram.ko|regmap-raw-ram.ko)
                if ! grep -Fqx "${mod_name}" "${VKB_LIST}" "${VDLKM_LIST}" "${SDLKM_LIST}"; then
                    echo "   [drop] ${mod_name} (unlisted test module)"
                    continue
                fi
                ;;
        esac
    fi

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
    
    cp "${module}" "${DEST}/lib/modules/${KERNEL_VER}/"
    "${STRIP_BIN}" --strip-debug "${DEST}/lib/modules/${KERNEL_VER}/${mod_name}"
done

#####
#####
# re-sign modules
#####
#####

echo "========================================"
echo "Re-signing Modules"
echo "========================================"

SIGN_FILE="${OUT_DIR}/scripts/sign-file"
SIGN_KEY="${OUT_DIR}/certs/signing_key.pem"
SIGN_CERT="${OUT_DIR}/certs/signing_key.x509"

if [ -f "${SIGN_FILE}" ] && [ -f "${SIGN_KEY}" ] && [ -f "${SIGN_CERT}" ]; then
    find "${DLKM_STAGING}" -type f -name "*.ko" | while read -r module; do
        echo "   [sign] $(basename "${module}")"
        "${SIGN_FILE}" sha1 "${SIGN_KEY}" "${SIGN_CERT}" "${module}"
    done
else
    echo "   [WARN] signing tools/keys missing. skipping."
fi

#####
#####
# generate dependency maps
#####
#####

echo "========================================"
echo "Generating Metadata"
echo "========================================"

SRC_METADATA="${MODULES_STAGING_DIR}/lib/modules/${KERNEL_VER}"
for part in vendor_kernel_boot vendor_dlkm system_dlkm; do
    echo "   [meta] Processing ${part}..."
    TARGET_DIR="${DLKM_STAGING}/${part}/lib/modules/${KERNEL_VER}"
    
    cp "${SRC_METADATA}/modules.builtin" "${TARGET_DIR}/"
    cp "${SRC_METADATA}/modules.builtin.modinfo" "${TARGET_DIR}/"
    cp "${SRC_METADATA}/modules.order" "${TARGET_DIR}/"
    
    (
        cd "${TARGET_DIR}"
        find . -maxdepth 1 -name "*.ko" | sed 's|^\./||' | sort > modules.load
    )

    depmod -b "${DLKM_STAGING}/${part}" "${KERNEL_VER}"
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

echo "   [img] Building vendor_dlkm.img..."
mkfs.erofs -z lz4hc "${OUT_DIR}/vendor_dlkm.img" "${DLKM_STAGING}/vendor_dlkm"

echo "   [img] Building system_dlkm.img..."
mkfs.erofs -z lz4hc "${OUT_DIR}/system_dlkm.img" "${DLKM_STAGING}/system_dlkm"

if command -v python3 &>/dev/null && [ -f "${AVBTOOL}" ]; then
    echo "   [avb] Signing images..."
    python3 "${AVBTOOL}" add_hashtree_footer --partition_name vendor_dlkm --hash_algorithm sha256 --do_not_generate_fec --image "${OUT_DIR}/vendor_dlkm.img"
    python3 "${AVBTOOL}" add_hashtree_footer --partition_name system_dlkm --hash_algorithm sha256 --do_not_generate_fec --image "${OUT_DIR}/system_dlkm.img"
else
    echo "   [WARN] avbtool not found."
fi

# combine dtbs
echo "   [dtb] Combining DTBs..."
if [ "${KERNEL_BRANCH}" = "6.12" ]; then
    DTB_SOURCE="${OUT_DIR}/google-modules/soc/gs/arch/arm64/boot/dts/google"
    DTB_FILES=$(sed -n 's/^gs201_pantah_dtbs := //p' "${DTBO_ORDER}" | sed "s|[^ ]*|${DTB_SOURCE}/&|g")
    echo "      Source: ${DTB_SOURCE}"
    cat ${DTB_FILES} > "${OUT_DIR}/combined.dtb"
else
    DTB_PATHS=("${OUT_DIR}/arch/arm64/boot/dts/google/gs201" "${OUT_DIR}/google-devices/gs201/dts" "${OUT_DIR}/arch/arm64/boot/dts/google")
    DTB_SOURCE=""
    for path in "${DTB_PATHS[@]}"; do
        if [ -d "$path" ] && compgen -G "$path/*.dtb" > /dev/null; then DTB_SOURCE="$path"; break; fi
    done
    echo "      Source: ${DTB_SOURCE}"
    cat "${DTB_SOURCE}"/*.dtb > "${OUT_DIR}/combined.dtb"
fi

# generate dtbo
# the bootloader picks overlays by board_id/board_rev, so read them from each
# overlay like kleaf does instead of leaving them zeroed
if [ -x "${MKDTIMG}" ]; then
    echo "   [dtbo] Generating dtbo.img..."
    if [ "${KERNEL_BRANCH}" = "6.12" ]; then
        DTBO_FILES=$(sed -n '/^gs201_pantah_overlays :=/,/^[a-zA-Z0-9_][a-zA-Z0-9_]* *[:?+=]/p' "${DTBO_ORDER}" | grep -o '[A-Za-z0-9_.-]*\.dtbo' | sed "s|^|${DTBO_DIR}/|")
    else
        DTBO_FILES=$(sed -n '/^PANTAH_DTBOS = \[/,/^\]/p' "${DTBO_ORDER}" | grep -o '[A-Za-z0-9_.-]*\.dtbo' | sed "s|^|${DTBO_DIR}/|")
    fi
    "${MKDTIMG}" create "${OUT_DIR}/dtbo.img" --page_size=4096 --id=/:board_id --rev=/:board_rev ${DTBO_FILES}
else
    echo "   [WARN] mkdtimg not found."
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
SOURCE_BOOT="${PREBUILT_KERNEL_DIR}/boot.img"
if [ ! -f "${SOURCE_BOOT}" ]; then
    SOURCE_BOOT="${ROM_DIR}/device/google/pantah-kernels/6.1/boot.img"
fi
if [ ! -f "${SOURCE_BOOT}" ]; then echo "source boot.img not found!"; exit 1; fi

rm -rf "${OUT_DIR}/boot_repack" && mkdir -p "${OUT_DIR}/boot_repack"
echo "   [copy] Fetching stock boot.img..."
cp "${SOURCE_BOOT}" "${OUT_DIR}/boot_repack/boot.img"

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
    if [ "${KERNEL_BRANCH}" = "6.12" ]; then
        cp -f ${DTB_FILES} "${PREBUILT_KERNEL_DIR}/" 2>/dev/null || true
    else
        cp -r "${DTB_SOURCE}"/*.dtb "${PREBUILT_KERNEL_DIR}/" 2>/dev/null || true
    fi
fi
if [ -d "${DTBO_DIR}" ]; then
    echo "   [sync] DTBO files..."
    if [ "${KERNEL_BRANCH}" = "6.12" ]; then
        cp -f ${DTBO_FILES} "${PREBUILT_KERNEL_DIR}/" 2>/dev/null || true
    else
        cp -r "${DTBO_DIR}"/*.dtbo "${PREBUILT_KERNEL_DIR}/" 2>/dev/null || true
    fi
fi

# sync modules
echo "   [clean] Removing old modules from prebuilts..."
find "${PREBUILT_KERNEL_DIR}" -name "*.ko" -delete

echo "   [sync] Copying new modules..."
find "${DLKM_STAGING}" -name "*.ko" -print -exec cp -fv {} "${PREBUILT_KERNEL_DIR}/" \; | sed 's|^|      |'

# sync insmod configs
echo "   [sync] Insmod configs..."
for variant in cheetah cloudripper panther ravenclaw; do
    if find "${KERNEL_DIR}" -name "init.insmod.${variant}.cfg" 2>/dev/null | grep -q .; then
        find "${KERNEL_DIR}" -name "init.insmod.${variant}.cfg" -exec cp -f {} "${PREBUILT_KERNEL_DIR}/" \; 2>/dev/null || true
    elif [ -f "${ROM_DIR}/device/google/pantah-kernels/6.1/init.insmod.${variant}.cfg" ]; then
        cp -f "${ROM_DIR}/device/google/pantah-kernels/6.1/init.insmod.${variant}.cfg" "${PREBUILT_KERNEL_DIR}/"
    fi
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
