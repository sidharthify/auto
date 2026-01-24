#!/usr/bin/env bash
set -e

VARIANT="${1:-standard}"

# config
KERNEL_DIR="$(pwd)"
OUT_DIR="${KERNEL_DIR}/out"
LLVM_DIR="$(realpath ../linux-x86/clang-r487747c/bin)/"
TOOL_ARGS=(LLVM="${LLVM_DIR}")

echo "========================================"
echo "   [KSU] Building Variant: ${VARIANT}"
echo "========================================"

# Cleanup Pre-check
rm -rf drivers/kernelsu

# Fetch Source
if [ "$VARIANT" == "next" ]; then
    echo "   [setup] Fetching KernelSU-Next..."
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -
elif ["$VARIANT" == "wild" ]; then
    echo "   [setup] Fetching KernelSU-Wild..." 
    curl -LSs "https://raw.githubusercontent.com/WildKernels/Wild_KSU/wild/kernel/setup.sh" | bash -
else
    echo "   [setup] Fetching KernelSU (Standard)..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
fi

echo "   [patch] Patching modpost.c for unexported symbols..."
MODPOST_C="scripts/mod/modpost.c"
# Save backup
cp "$MODPOST_C" "${MODPOST_C}.bak"
perl -i -0777 -pe 's/(void check_exports\(struct module \*mod\)\s*\{)/$1 return;/' "$MODPOST_C"

# Force Tool Rebuild
# We delete the compiled modpost so make detects the source change
rm -rf "${OUT_DIR}/scripts/mod"
echo "   [make] Rebuilding scripts..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" O="${OUT_DIR}" modules_prepare

# Configure Module
echo "   [conf] Forcing CONFIG_KSU=m..."
sed -i '/config KSU/,/help/{s/default y/default m/}' drivers/kernelsu/Kconfig

# Append to .config just in case
if ! grep -q "CONFIG_KSU=m" "${OUT_DIR}/.config"; then
    echo "CONFIG_KSU=m" >> "${OUT_DIR}/.config"
    echo "CONFIG_KSU_DEBUG=y" >> "${OUT_DIR}/.config"
    # Refresh config
    make -j"$(nproc)" "${TOOL_ARGS[@]}" O="${OUT_DIR}" olddefconfig
fi

# Build :3
echo "   [build] Compiling ${VARIANT}..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" O="${OUT_DIR}" M=drivers/kernelsu modules

# Strip & Move
if [ -f "${OUT_DIR}/drivers/kernelsu/kernelsu.ko" ]; then
    "${LLVM_DIR}llvm-strip" --strip-debug "${OUT_DIR}/drivers/kernelsu/kernelsu.ko"

    TARGET_NAME="kernelsu.ko"
    if [ "$VARIANT" == "next" ]; then TARGET_NAME="kernelsu_next.ko"; fi

    cp "${OUT_DIR}/drivers/kernelsu/kernelsu.ko" "${OUT_DIR}/${TARGET_NAME}"
    echo "SUCCESS: Generated ${OUT_DIR}/${TARGET_NAME}"
else
    echo "ERROR: Build failed!"
    # Restore backup before exiting
    mv "${MODPOST_C}.bak" "$MODPOST_C"
    exit 1
fi

# Final Cleanup
echo "   [clean] Restoring source tree..."
rm -rf drivers/kernelsu
mv "${MODPOST_C}.bak" "$MODPOST_C"
# Revert Kconfig changes in drivers/ (setup.sh modifies drivers/Kconfig)
git checkout drivers/Kconfig drivers/Makefile 2>/dev/null || true

echo "========================================"
echo "   [KSU] Build Complete & Tree Cleaned"
echo "========================================"
