#!/usr/bin/env bash
set -e

VARIANT="${1:-standard}"

# config
KERNEL_DIR="$(pwd)"
OUT_DIR="${KERNEL_DIR}/out"
KERNEL_MAJOR=$(sed -n 's/^VERSION = *//p' Makefile | head -n1)
KERNEL_MINOR=$(sed -n 's/^PATCHLEVEL = *//p' Makefile | head -n1)
KERNEL_BRANCH="${KERNEL_MAJOR}.${KERNEL_MINOR}"
if [ "${KERNEL_BRANCH}" = "6.12" ]; then
    # same tools as auto.sh, or modules_prepare sees the system rustc, drops
    # CONFIG_RUST and the module no longer matches the kernel
    LLVM_DIR="$(realpath ../linux-x86/clang-r536225/bin)/"
    RUST_DIR="$(realpath ../linux-x86/rust-prebuilts/linux-x86/1.82.0.p2)"
    ELFUTILS_DIR="$(realpath ../host/elfutils)"
    export LIBCLANG_PATH="${LLVM_DIR}../lib"
    TOOL_ARGS=(
        LLVM="${LLVM_DIR}"
        RUSTC="${RUST_DIR}/bin/rustc"
        HOSTRUSTC="${RUST_DIR}/bin/rustc"
        BINDGEN="${HOME}/yaap/prebuilts/clang-tools/linux-x86/bin/bindgen"
        HOSTCFLAGS="-I${ELFUTILS_DIR}/include"
        HOSTLDFLAGS="-L${ELFUTILS_DIR}/lib -Wl,-rpath,${ELFUTILS_DIR}/lib"
    )
else
    LLVM_DIR="$(realpath ../linux-x86/clang-r487747c/bin)/"
    TOOL_ARGS=(LLVM="${LLVM_DIR}")
fi

echo "========================================"
echo "   [KSU] Building Variant: ${VARIANT}"
echo "========================================"

# cleanup existing
rm -rf drivers/kernelsu KernelSU Wild_KSU KernelSU-Next
git restore arch/arm64/configs/gs201_defconfig drivers/Kconfig drivers/Makefile scripts/mod/modpost.c

if [ "$VARIANT" == "next" ]; then
    echo "   [setup] Fetching KernelSU-Next..."
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -
elif [ "$VARIANT" == "wild" ]; then
    echo "   [setup] Fetching KernelSU-Wild..."
    curl -LSs "https://raw.githubusercontent.com/WildKernels/Wild_KSU/wild/kernel/setup.sh" | bash -
else
    echo "   [setup] Fetching KernelSU (Standard)..."
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
fi

# scripts/Makefile.build resolves a relative M= against the build directory,
# where drivers/kernelsu doesn't exist under O=. Pass the module path absolute so
# kbuild takes its $(filter /%,$(src)) branch and finds the Kbuild. The .ko is
# then built in the source directory rather than under $OUT_DIR.
MOD_DIR="$(realpath drivers/kernelsu)"
if [ ! -f "${MOD_DIR}/Kbuild" ] && [ ! -f "${MOD_DIR}/Makefile" ]; then
    echo "ERROR: no Kbuild or Makefile in ${MOD_DIR}"
    exit 1
fi

echo "   [patch] Patching modpost.c for unexported symbols..."
MODPOST_C="scripts/mod/modpost.c"
cp "$MODPOST_C" "${MODPOST_C}.bak"
perl -i -0777 -pe 's/(void check_exports\(struct module \*mod\)\s*\{)/$1 return;/' "$MODPOST_C"

# Skipping check_exports() leaves every unresolved symbol without version info,
# so CONFIG_EXTENDED_MODVERSIONS makes modpost emit an empty initializer for
# ____version_ext_names[], which is not valid C. Emit "" in that case. The crc
# table is empty too, so the two stay aligned.
python3 - "$MODPOST_C" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
head = ("static void add_extended_versions(struct buffer *b, struct module *mod)\n"
        "{\n\tstruct symbol *s;\n")
assert s.count(head) == 1, "add_extended_versions head"
s = s.replace(head, head + "\tbool have_ext_names = false;\n")
tail = ('\t\tbuf_printf(b, "\\t\\"%s\\\\0\\"\\n", s->name);\n'
        '\t}\n\tbuf_printf(b, ";\\n");\n')
assert s.count(tail) == 1, "add_extended_versions tail"
s = s.replace(tail,
              '\t\tbuf_printf(b, "\\t\\"%s\\\\0\\"\\n", s->name);\n'
              '\t\thave_ext_names = true;\n'
              '\t}\n'
              '\tif (!have_ext_names)\n'
              '\t\tbuf_printf(b, "\\t\\"\\"\\n");\n'
              '\tbuf_printf(b, ";\\n");\n')
open(p, "w").write(s)
print("   [patch] modpost.c: empty __version_ext_names initializer fixed")
PY

# force rebuild
rm -rf "${OUT_DIR}/scripts/mod"
echo "   [make] Rebuilding scripts..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" O="${OUT_DIR}" modules_prepare

# build
echo "   [build] Compiling ${VARIANT}..."
make -j"$(nproc)" "${TOOL_ARGS[@]}" O="${OUT_DIR}" M="${MOD_DIR}" \
    KCFLAGS="-I${MOD_DIR} -I${MOD_DIR}/include" modules

# strip n move
if [ -f "${MOD_DIR}/kernelsu.ko" ]; then
    "${LLVM_DIR}llvm-strip" --strip-debug "${MOD_DIR}/kernelsu.ko"

        TARGET_NAME="kernelsu.ko"
        if [ "$VARIANT" == "next" ]; then
            TARGET_NAME="kernelsu_next.ko"
        elif [ "$VARIANT" == "wild" ]; then
            TARGET_NAME="kernelsu_wild.ko"
        fi


    cp "${MOD_DIR}/kernelsu.ko" "${OUT_DIR}/${TARGET_NAME}"
    echo "SUCCESS: Generated ${OUT_DIR}/${TARGET_NAME}"
else
    echo "ERROR: Build failed!"
    # Restore backup before exiting
    mv "${MODPOST_C}.bak" "$MODPOST_C"
    exit 1
fi

# cleanup
echo "   [clean] Restoring source tree..."
rm -rf drivers/kernelsu KernelSU Wild_KSU KernelSU-Next
mv "${MODPOST_C}.bak" "$MODPOST_C"
git checkout drivers/Kconfig drivers/Makefile 2>/dev/null || true

echo "========================================"
echo "   [KSU] Build Complete & Tree Cleaned"
echo "========================================"
