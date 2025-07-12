#!/usr/bin/env bash

set -e

ROM_DIR="/home/sidharthify/yaap"
ROOT_DIR="/home/sidharthify/kernel"
KERNEL_DIR="${ROOT_DIR}/aosp"
LLVM_DIR="${ROOT_DIR}/prebuilts/clang/host/linux-x86/clang-r487747c/bin/"
OUT_DIR="${KERNEL_DIR}/out"
MODULES_STAGING_DIR="${OUT_DIR}/modules_staging"
IMAGE_DIR="${OUT_DIR}/arch/arm64/boot/Image.lz4"
PREBUILT_KERNEL_DIR="${ROM_DIR}/device/google/pantah-kernels/6.1/25Q1-13202328"
GS201_A0_DIR="${OUT_DIR}/google-devices/gs201/dts/gs201-a0.dtb"
GS201_B0_DIR="${OUT_DIR}/google-devices/gs201/dts/gs201-b0.dtb"
GS201_B0_IPOP_DIR="${OUT_DIR}/google-devices/gs201/dts/gs201-b0_v2-ipop.dtb"

# LLVM
TOOL_ARGS=(LLVM="${LLVM_DIR}")

# enter kernel tree
cd "${KERNEL_DIR}"

# build kernel image
make -j"$(nproc)" "${TOOL_ARGS[@]}" gs201_defconfig
make -j"$(nproc)" "${TOOL_ARGS[@]}"
echo "Kernel built"

# build in-kernel modules
make -j"$(nproc)" "${TOOL_ARGS[@]}" modules
make -j"$(nproc)" "${TOOL_ARGS[@]}" INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" modules_install
echo "Modules built"

# copy kernel image to prebuilt kernel tree
cp "${IMAGE_DIR}" "${PREBUILT_KERNEL_DIR}"
echo "Copied Image.lz4 to prebuilt tree"

# copy dtbs to prebuilt kernel tree
cp "${GS201_A0_DIR}" "${PREBUILT_KERNEL_DIR}"
cp "${GS201_B0_DIR}" "${PREBUILT_KERNEL_DIR}"
cp "${GS201_B0_IPOP_DIR}" "${PREBUILT_KERNEL_DIR}"
echo "Copied dtbs to prebuilt tree"

# copy kernel modules (.ko files) into prebuilt kernel tree
find "${PREBUILT_KERNEL_DIR}" -name "*.ko" | while read -r prebuilt_ko; do
    filename=$(basename "${prebuilt_ko}")

    found=$(find "${MODULES_STAGING_DIR}" -name "${filename}" | head -n 1)

    if [ -n "${found}" ]; then
        cp "${found}" "${prebuilt_ko}"
        echo "Updated ${filename} in prebuilt tree"
    else
        echo "${filename} not found in built modules"
    fi
done