#!/usr/bin/env bash

set -e

ROOT_DIR="/home/sidharthify/kernel"
KERNEL_DIR="${ROOT_DIR}/aosp"
OUT_DIR="${ROOT_DIR}/aosp/out"
LLVM_DIR="${ROOT_DIR}/prebuilts/clang/host/linux-x86/clang-r487747c/bin/"
MODULES_STAGING_DIR="${OUT_DIR}/modules_staging"
KERNEL_UAPI_HEADERS_DIR="${OUT_DIR}/headers"
MODULE_STRIP_FLAG="INSTALL_MOD_STRIP=1"

EXT_MODULES="private/google-modules/amplifiers \
             private/google-modules/aoc \
             private/google-modules/aoc_ipc \
             private/google-modules/bluetooth \
             private/google-modules/bms \
             private/google-modules/display \
             private/google-modules/edgetpu \
             private/google-modules/fingerprint \
             private/google-modules/gps \
             private/google-modules/gpu \
             private/google-modules/gxp \
             private/google-modules/hdcp \
             private/google-modules/lwis \
             private/google-modules/misc \
             private/google-modules/nfc \
             private/google-modules/perf \
             private/google-modules/power \
             private/google-modules/radio \
             private/google-modules/sensors \
             private/google-modules/soc \
             private/google-modules/touch \
             private/google-modules/trusty \
             private/google-modules/typec \
             private/google-modules/uwb \
             private/google-modules/video \
             private/google-modules/wlan"

MAKE_ARGS=(ARCH=arm64)
TOOL_ARGS=(LLVM="${LLVM_DIR}")

# rel path
rel_path() {
  realpath --relative-to="$2" "$1"
}

# enter kernel tree
cd "${KERNEL_DIR}"

# build kernel image
make -j"$(nproc)" O="${OUT_DIR}" "${MAKE_ARGS[@]}" "${TOOL_ARGS[@]}" gki_defconfig
make -j"$(nproc)" O="${OUT_DIR}" "${MAKE_ARGS[@]}" "${TOOL_ARGS[@]}" Image.lz4

# build in-kernel modules
make -j"$(nproc)" O="${OUT_DIR}" "${MAKE_ARGS[@]}" "${TOOL_ARGS[@]}" modules

# build external modules
for EXT_MOD in ${EXT_MODULES}; do
  ABS_EXT_MOD="${ROOT_DIR}/${EXT_MOD}"
  EXT_MOD_REL=$(rel_path "${ABS_EXT_MOD}" "${KERNEL_DIR}")
  mkdir -p "${OUT_DIR}/${EXT_MOD_REL}"
  set -x
  make -C "${ABS_EXT_MOD}" M="${EXT_MOD_REL}" KERNEL_SRC="${KERNEL_DIR}" \
       O="${OUT_DIR}" "${TOOL_ARGS[@]}" "${MAKE_ARGS[@]}" modules_install

  make -C "${ABS_EXT_MOD}" M="${EXT_MOD_REL}" KERNEL_SRC="${KERNEL_DIR}" \
       O="${OUT_DIR}" "${TOOL_ARGS[@]}" ${MODULE_STRIP_FLAG} \
       INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" \
       INSTALL_HDR_PATH="${KERNEL_UAPI_HEADERS_DIR}/usr" \
       "${MAKE_ARGS[@]}" modules_install
  set +x
done
