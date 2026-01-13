#!/usr/bin/env bash
set -e

# === Usage: ./ksu.sh [standard|next] ===
VARIANT="${1:-standard}"

# === Config ===
# We assume this is run from the kernel root (set by auto.sh)
KERNEL_DIR="$(pwd)"
OUT_DIR="${KERNEL_DIR}/out"
LLVM_DIR="$(realpath ../linux-x86/clang-r487747c/bin)/"
TOOL_ARGS=(LLVM="${LLVM_DIR}")


echo "========================================"
echo "   [KSU] Building Variant: ${VARIANT}"
echo "========================================"

# Fetch Source
if [ "$VARIANT" == "next" ]; then
    echo "   [setup] Fetching KernelSU-Next..."
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -
else
    echo "   [setup] Fetching KernelSU (Standard)..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
fi

# Patch modpost.c
echo "   [patch] Patching modpost.c for unexported symbols..."
MODPOST_C="scripts/mod/modpost.c"

# We delete the compiled modpost so make detects the source change
rm -rf "${OUT_DIR}/scripts/mod"

# Configure Module
echo "   [conf] Forcing CONFIG_KSU=m..."
# Ensure default is 'm' in source to prevent "y" overrides
sed -i '/config KSU/,/help/{s/default y/default m/}' drivers/kernelsu/Kconfig

# Build :3
echo "   [build] Compiling ${VARIANT}..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" O="${OUT_DIR}" M=drivers/kernelsu

# Move & Strip
    cp -p "${OUT_DIR}/drivers/kernelsu/kernelsu.ko" "${OUT_DIR}/${TARGET_NAME}"
    echo "SUCCESS: Generated ${OUT_DIR}/${TARGET_NAME}"
else
    echo "ERROR: Build failed!"
    # Restore backup before exiting
    git reset --hard
    exit 1
fi

if [ -f "${OUT_DIR}/drivers/kernelsu/kernelsu.ko" ]; then
    "${LLVM_DIR}llvm-strip" --strip-debug "${OUT_DIR}/drivers/kernelsu/kernelsu.ko"

    # Rename if using Next to avoid confusion, or keep standard name
    TARGET_NAME="kernelsu.ko"
    if [ "$VARIANT" == "next" ]; then TARGET_NAME="kernelsu_next.ko"; fi

# Final Cleanup
echo "   [clean] Restoring source tree..."
rm -rf KernelSU/ drivers/kernelsu
git restore drivers/ scripts/

echo "========================================"
echo "   [KSU] Build Complete & Tree Cleaned"
echo "========================================"