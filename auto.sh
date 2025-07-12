#!/usr/bin/env bash

set -e

ROOT_DIR="/home/sidharthify/kernel"
KERNEL_DIR="${ROOT_DIR}/aosp"
LLVM_DIR="${ROOT_DIR}/prebuilts/clang/host/linux-x86/clang-r487747c/bin/"
OUT_DIR="${KERNEL_DIR}/out"
MODULES_STAGING_DIR="${OUT_DIR}/modules_staging"

TOOL_ARGS=(LLVM="${LLVM_DIR}")

# enter kernel tree
cd "${KERNEL_DIR}"

# build kernel image
make -j"$(nproc)" "${TOOL_ARGS[@]}" gs201_defconfig
make -j"$(nproc)""${TOOL_ARGS[@]}" Image.lz4

# build in-kernel modules
make -j"$(nproc)" "${TOOL_ARGS[@]}" modules
make -j"$(nproc)" "${TOOL_ARGS[@]}" INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" modules_install