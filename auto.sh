#!/usr/bin/env bash

set -e

# kernel tree
ROOT_DIR="/home/sidharthify/kernel"
KERNEL_DIR="${ROOT_DIR}/aosp"

# out dirs
OUT_DIR="${KERNEL_DIR}/out"
MODULES_STAGING_DIR="${OUT_DIR}/modules_staging"
IMAGE_DIR="${OUT_DIR}/arch/arm64/boot/Image.lz4"

# AOSP
ROM_DIR="/home/sidharthify/yaap"
PREBUILT_KERNEL_DIR="${ROM_DIR}/device/google/pantah-kernels/6.1/25Q1-13202328"

# dtbs
DTB_DIR="${OUT_DIR}/google-devices/gs201/dts/"

# LLVM
LLVM_DIR="${ROOT_DIR}/prebuilts/clang/host/linux-x86/clang-r487747c/bin/"
TOOL_ARGS=(LLVM="${LLVM_DIR}")

# enter kernel tree
cd "${KERNEL_DIR}"

# build kernel image
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

# copy kernel modules (.ko files) to prebuilt kernel tree
mapfile -t prebuilt_kos < <(find "${PREBUILT_KERNEL_DIR}" -name "*.ko") # store in array

for prebuilt_ko in "${prebuilt_kos[@]}"; do
	filename=$(basename "${prebuilt_ko}")
	found=$(find "${MODULES_STAGING_DIR}" -name "${filename}" | head -n 1)

	if [ -n "${found}" ]; then
		cp "${found}" "${prebuilt_ko}"
		echo "Updated ${filename} in prebuilt tree"
	else
		echo "${filename} not found in built modules"
	fi
done

echo "Stripped and copied modules to prebuilt tree"