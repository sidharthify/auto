#!/usr/bin/env bash

set -e

ROOT_DIR=$(pwd)
KERNEL_DIR="${ROOT_DIR}/aosp"
OUT_DIR="${ROOT_DIR}/aosp/out"
export "${OUT_DIR}" # Needed for modules
LLVM_DIR="${ROOT_DIR}/prebuilts/clang/host/linux-x86/clang-r487747c/bin/"
MODULES_STAGING_DIR="${OUT_DIR}/modules_staging"
KERNEL_UAPI_HEADERS_DIR="${OUT_DIR}/headers"

EXT_MODULES="private/google-modules/amplifiers/snd_soc_wm_adsp \
             private/google-modules/amplifiers/cs35l41 \
             private/google-modules/amplifiers/cs35l45 \
             private/google-modules/amplifiers/cs40l25 \
             private/google-modules/amplifiers/cs40l26 \
             private/google-modules/amplifiers/drv2624 \
             private/google-modules/amplifiers/tas256x \
             private/google-modules/amplifiers/tas25xx \
             private/google-modules/amplifiers/audiometrics \
             private/google-modules/aoc \
             private/google-modules/aoc/alsa \
             private/google-modules/aoc/usb \
             private/google-modules/bluetooth/broadcom \
             private/google-modules/gps/broadcom/bcm47765 \
             private/google-modules/gpu/mali_kbase \
             private/google-modules/gpu/borr_mali_kbase \
             private/google-modules/soc/gs/drivers/soc/google/s2mpu \
             private/google-modules/soc/gs/drivers/soc/google/pkvm-s2mpu/common/hyp \
             private/google-modules/soc/gs/drivers/soc/google/pkvm-s2mpu/pkvm-s2mpu \
             private/google-modules/soc/gs/drivers/soc/google/pkvm-s2mpu/pkvm-s2mpu-v9 \
             private/google-modules/soc/gs/drivers/soc/google/pt \
             private/google-modules/soc/gs/drivers/soc/google/smra \
             private/google-modules/soc/gs/drivers/soc/google/vh/kernel \
             private/google-modules/soc/gs/drivers/soc/google/vh/kernel/cgroup \
             private/google-modules/soc/gs/drivers/soc/google/vh/kernel/fs \
             private/google-modules/soc/gs/drivers/soc/google/vh/kernel/metrics \
             private/google-modules/soc/gs/drivers/soc/google/vh/kernel/mm \
             private/google-modules/soc/gs/drivers/soc/google/vh/kernel/pixel_em \
             private/google-modules/soc/gs/drivers/soc/google/vh/kernel/sched \
             private/google-modules/soc/gs/drivers/soc/google/vh/kernel/thermal \
             private/google-modules/soc/gs/drivers/spi \
             private/google-modules/soc/gs/drivers/spmi \
             private/google-modules/soc/gs/drivers/thermal \
             private/google-modules/soc/gs/drivers/thermal/google \
             private/google-modules/soc/gs/drivers/thermal/samsung \
             private/google-modules/soc/gs/drivers/tty/serial \
             private/google-modules/soc/gs/drivers/ufs \
             private/google-modules/soc/gs/drivers/usb \
             private/google-modules/soc/gs/drivers/usb/dwc3 \
             private/google-modules/soc/gs/drivers/usb/gadget \
             private/google-modules/soc/gs/drivers/usb/gadget/function \
             private/google-modules/soc/gs/drivers/usb/host \
             private/google-modules/soc/gs/drivers/usb/typec \
             private/google-modules/soc/gs/drivers/usb/typec/tcpm \
             private/google-modules/soc/gs/drivers/usb/typec/tcpm/google \
             private/google-modules/soc/gs/drivers/video/backlight \
             private/google-modules/soc/gs/drivers/watchdog \
             private/google-modules/trusty \
             private/google-modules/trusty/drivers/trusty \
             private/google-modules/uwb/qorvo/dw3000/kernel \
             private/google-modules/uwb/qorvo/qm35/qm35s \
             private/google-modules/video/gchips \
             private/google-modules/wlan/bcm4383 \
             private/google-modules/wlan/bcm4389 \
             private/google-modules/wlan/bcm4390 \
             private/google-modules/wlan/bcm4398 \
             private/google-modules/wlan/dhd43752p \
             private/google-modules/wlan/wcn6740/cnss2 \
             private/google-modules/wlan/wcn6740/wlan/qcacld-3.0 \
             private/google-modules/wlan/wcn6740/wlan/qca-wifi-host-cmn/iot_sim \
             private/google-modules/wlan/wcn6740/wlan/qca-wifi-host-cmn/qdf \
             private/google-modules/wlan/wcn6740/wlan/qca-wifi-host-cmn/spectral \
             private/google-modules/wlan/wlan_ptracker \
             private/google-modules/sensors/hall_sensor \
             private/google-modules/touch/synaptics/syna_c10 \
             private/google-modules/touch/synaptics/syna_gtd \
             private/google-modules/touch/focaltech/ft3658 \
             private/google-modules/touch/focaltech/ft3683u \
             private/google-modules/touch/fts/fst2 \
             private/google-modules/touch/fts/ftm5_legacy \
             private/google-modules/touch/fts/ftm5 \
             private/google-modules/touch/goodix \
             private/google-modules/touch/novatek/nt36xxx \
             private/google-modules/touch/common \
             private/google-modules/touch/common/usi \
             private/google-modules/touch/sec \
             private/google-modules/power/reset \
             private/google-modules/power/mitigation \
             private/google-modules/misc/sscoredump"

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
make -j"$(nproc)" \
  O="${OUT_DIR}" \
  "${TOOL_ARGS[@]}" \
  INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" \
  "${MAKE_ARGS[@]}" \
  modules_install

cd "${ROOT_DIR}"

# build external modules
for EXT_MOD in ${EXT_MODULES}; do
  ABS_EXT_MOD="${ROOT_DIR}/${EXT_MOD}"
  EXT_MOD_REL=$(rel_path "${ABS_EXT_MOD}" "${KERNEL_DIR}")

  set -x
  mkdir -p "${OUT_DIR}/${EXT_MOD_REL}"

  make -C "${ABS_EXT_MOD}" \
  M="${EXT_MOD_REL}" \
  KERNEL_SRC="${KERNEL_DIR}" \
  O="${OUT_DIR}" \
  "${TOOL_ARGS[@]}" \
  "${MAKE_ARGS[@]}" \
  modules

  make -C "${ABS_EXT_MOD}" \
  M="${EXT_MOD_REL}" \
  KERNEL_SRC="${KERNEL_DIR}" \
  O="${OUT_DIR}" \
  "${TOOL_ARGS[@]}" \
  "${MAKE_ARGS[@]}" \
  INSTALL_MOD_PATH="${MODULES_STAGING_DIR}" \
  INSTALL_HDR_PATH="${KERNEL_UAPI_HEADERS_DIR}/usr" \
  modules_install

  set +x
done
