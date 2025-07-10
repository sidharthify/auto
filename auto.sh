#!/usr/bin/env bash

KERNEL_BUILD_DIR="/home/sidharthify/kernel/aosp"
LLVM_DIR="/home/sidharthify/kernel/prebuilts/clang/host/linux-x86/clang-r487747c/bin/"

cd "${KERNEL_BUILD_DIR}"

ARCH=arm64 make LLVM="${LLVM_DIR}" O=out gki_defconfig
ARCH=arm64 make -j$(nproc) LLVM="${LLVM_DIR}" O=out Image.lz4
