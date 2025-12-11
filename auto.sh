#!/usr/bin/env bash

set -e

### default config

# kernel tree
ROOT_DIR="/home/sidharthify/kernel"
KERNEL_DIR="${ROOT_DIR}/aosp"

# out dirs
OUT_DIR="${KERNEL_DIR}/out"
MODULES_STAGING_DIR="${OUT_DIR}/modules_staging"
IMAGE_DIR="${OUT_DIR}/arch/arm64/boot/Image.lz4"

# AOSP
ROM_DIR="/home/sidharthify/yaap"
PREBUILT_KERNEL_DIR="${ROM_DIR}/device/google/pantah-kernels/6.1/sidharthify"

# dtbs
DTB_DIR="${OUT_DIR}/google-devices/gs201/dts/"

# LLVM
LLVM_DIR="${ROOT_DIR}/linux-x86/clang-r487747c/bin/"
TOOL_ARGS=(LLVM="${LLVM_DIR}")


#####
#####
# build kernel image
#####
#####

cd "${KERNEL_DIR}"

# build the Image
make -j"$(nproc)" "${TOOL_ARGS[@]}" gs201_defconfig
make -j"$(nproc)" "${TOOL_ARGS[@]}"

# check if image exists
if [ -f "${OUT_DIR}/arch/arm64/boot/Image" ]; then
	echo "Kernel Built successfully"
else
	echo -e "Build Failed!"
	exit 1
fi

# build in-kernel modules

make -j"$(nproc)" "${TOOL_ARGS[@]}" modules
make -j"$(nproc)" "${TOOL_ARGS[@]}" INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" modules_install

# check if modules are actually being built
if find "${MODULES_STAGING_DIR}" -name "*.ko" | grep -q .; then
	echo "Modules Built successfully"
else
	echo -e "Modules Build Failed!"
	exit 1
fi

# copy kernel image to prebuilt kernel tree
cp "${IMAGE_DIR}" "${PREBUILT_KERNEL_DIR}"
echo "Copied Image.lz4 to prebuilt tree"

# copy dtbs to prebuilt kernel tree
cp -r "${DTB_DIR}" "${PREBUILT_KERNEL_DIR}"
echo "Copied dtbs to prebuilt tree"

#####
#####
# sync modules
#####
#####

echo "Syncing modules to prebuilt tree..."

# 1. clean old modules to prevent zombies
find "${PREBUILT_KERNEL_DIR}" -name "*.ko" -delete

# 2. copy ALL built modules
find "${MODULES_STAGING_DIR}" -type f -name "*.ko" \
    -exec cp -f {} "${PREBUILT_KERNEL_DIR}/" \;

echo "Synced $(find "${PREBUILT_KERNEL_DIR}" -name "*.ko" | wc -l) modules."

#####
#####
# dlkm partition generation
#####
#####

echo "Starting DLKM Image Generation..."

# config
BUILD_CONFIG_DIR="${KERNEL_DIR}/build_config"
VKB_LIST="${BUILD_CONFIG_DIR}/vendor_kernel_boot.txt"
VDLKM_LIST="${BUILD_CONFIG_DIR}/vendor_dlkm.txt"
SDLKM_LIST="${BUILD_CONFIG_DIR}/system_dlkm.txt"
BLOCKLIST="${BUILD_CONFIG_DIR}/blocklist.txt"

STRIP_BIN="${LLVM_DIR}llvm-strip"
KERNEL_VER_FILE="${OUT_DIR}/include/config/kernel.release"

# 1. sanity checks
if [ ! -f "${KERNEL_VER_FILE}" ]; then
    echo "Error: kernel.release not found. Build likely failed."
    exit 1
fi
KERNEL_VER=$(cat "${KERNEL_VER_FILE}")
echo "  Kernel Release: ${KERNEL_VER}"

if [ ! -f "${VKB_LIST}" ] || [ ! -f "${SDLKM_LIST}" ]; then
    echo "Error: Config lists missing in ${BUILD_CONFIG_DIR}"
    exit 1
fi

# 2. prepare for fakeroot
DLKM_STAGING="${OUT_DIR}/dlkm_staging"
rm -rf "${DLKM_STAGING}"
# create standard AOSP module paths
mkdir -p "${DLKM_STAGING}/vendor_kernel_boot/lib/modules/${KERNEL_VER}"
mkdir -p "${DLKM_STAGING}/vendor_dlkm/lib/modules/${KERNEL_VER}"
mkdir -p "${DLKM_STAGING}/system_dlkm/lib/modules/${KERNEL_VER}"

# 3. helper to check for blacklist
is_blocked() {
    local mod_name=$(basename "$1" .ko)
    if [ -f "${BLOCKLIST}" ] && grep -q "^${mod_name}" "${BLOCKLIST}" 2>/dev/null; then
        return 0
    fi
    return 1
}

echo "Sorting and Stripping Modules..."

# 4. main loop
# sort, copy, and strip

find "${MODULES_STAGING_DIR}" -type f -name "*.ko" | while read -r module; do
    mod_base=$(basename "${module}")
    # calculate relative path to preserve subfolders
    mod_rel_path="${module#${MODULES_STAGING_DIR}/lib/modules/${KERNEL_VER}/}"

    if is_blocked "${mod_base}"; then
        echo "  [SKIP] ${mod_base} (Blocklisted)"
        continue
    fi

    # determine partition bucket 
	# priority: vendor_kernel_boot > vendor_dlkm > system_dlkm

    DEST_ROOT=""
    if grep -Fq "${mod_base}" "${VKB_LIST}"; then
        DEST_ROOT="${DLKM_STAGING}/vendor_kernel_boot"
    elif grep -Fq "${mod_base}" "${VDLKM_LIST}"; then
        DEST_ROOT="${DLKM_STAGING}/vendor_dlkm"
    elif grep -Fq "${mod_base}" "${SDLKM_LIST}"; then
        DEST_ROOT="${DLKM_STAGING}/system_dlkm"
    else
        # fallback for modules that are unlisted
        DEST_ROOT="${DLKM_STAGING}/system_dlkm"
        echo "  [INFO] ${mod_base} unlisted -> system_dlkm"
    fi

    # copy file
    DEST_PATH="${DEST_ROOT}/lib/modules/${KERNEL_VER}/${mod_rel_path}"
    mkdir -p "$(dirname "${DEST_PATH}")"
    cp "${module}" "${DEST_PATH}"

    # strip all debug symbols
    "${STRIP_BIN}" --strip-debug "${DEST_PATH}"
done

# 5. generate modules.dep
echo "Running depmod..."
for partition in vendor_kernel_boot vendor_dlkm system_dlkm; do
    ROOT_PATH="${DLKM_STAGING}/${partition}"
    MOD_LIB_PATH="${ROOT_PATH}/lib/modules/${KERNEL_VER}"
    
    # only run if modules exist
    if [ -d "${MOD_LIB_PATH}" ]; then
        # copy required metadata files from the main staging area
        # depmod needs these to understand symbols and build order
        cp "${MODULES_STAGING_DIR}/lib/modules/${KERNEL_VER}/modules.builtin" "${MOD_LIB_PATH}/" 2>/dev/null || true
        cp "${MODULES_STAGING_DIR}/lib/modules/${KERNEL_VER}/modules.builtin.modinfo" "${MOD_LIB_PATH}/" 2>/dev/null || true
        cp "${MODULES_STAGING_DIR}/lib/modules/${KERNEL_VER}/modules.order" "${MOD_LIB_PATH}/" 2>/dev/null || true

        # copy System.map temporarily to check for symbols
        cp "${OUT_DIR}/System.map" "${ROOT_PATH}/System.map" 2>/dev/null || true
        
        # -b: basedir
        depmod -b "${ROOT_PATH}" "${KERNEL_VER}"
        
        # cleanup temp files
		# keep modules.order/builtin as they are useful for debugging
        rm -f "${ROOT_PATH}/System.map"
        rm -f "${MOD_LIB_PATH}/build"
        rm -f "${MOD_LIB_PATH}/source"
    fi
done

# 6. build the actual EROFS Images
if [ "${DRY_DLKM}" == "1" ] || [ "${1}" == "--dry-run" ]; then
    echo "Dry run: Skipping image creation."
    exit 0
fi

echo "Building EROFS images..."
if [ -d "${DLKM_STAGING}/vendor_kernel_boot" ]; then
    mkfs.erofs -z lz4hc "${OUT_DIR}/vendor_kernel_boot.img" \
        "${DLKM_STAGING}/vendor_kernel_boot"
    cp "${OUT_DIR}/vendor_kernel_boot.img" "${PREBUILT_KERNEL_DIR}/"
    echo "  -> Updated vendor_kernel_boot.img"
fi

if [ -d "${DLKM_STAGING}/vendor_dlkm" ]; then
    mkfs.erofs -z lz4hc "${OUT_DIR}/vendor_dlkm.img" \
        "${DLKM_STAGING}/vendor_dlkm"
    cp "${OUT_DIR}/vendor_dlkm.img" "${PREBUILT_KERNEL_DIR}/"
    echo "  -> Updated vendor_dlkm.img"
fi

if [ -d "${DLKM_STAGING}/system_dlkm" ]; then
    mkfs.erofs -z lz4hc "${OUT_DIR}/system_dlkm.img" \
        "${DLKM_STAGING}/system_dlkm"
    cp "${OUT_DIR}/system_dlkm.img" "${PREBUILT_KERNEL_DIR}/"
    echo "  -> Updated system_dlkm.img"
fi

echo "Done making images!"