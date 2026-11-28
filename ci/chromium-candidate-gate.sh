#!/bin/bash
# Concrete GN and Ninja gates for the warm weekly Chromium candidate checkout.
set -euo pipefail

MODE=${1:-}
CHROME_SRC=${CHROME_SRC:-}
OUT_DIR=${KIBAOS_GN_OUT_DIR:-}

case "$MODE" in
  gn|targeted|full-build) ;;
  *) echo "Usage: $0 gn|targeted|full-build" >&2; exit 2 ;;
esac
[[ -d "$CHROME_SRC" ]] || { echo 'CHROME_SRC is missing' >&2; exit 2; }
[[ "$OUT_DIR" == "$CHROME_SRC/out/"* ]] || {
  echo 'KIBAOS_GN_OUT_DIR must be below CHROME_SRC/out' >&2
  exit 2
}

source_owner=$(stat -c '%U' "$CHROME_SRC")
if [[ $(id -u) -eq 0 && $source_owner != root && $source_owner != UNKNOWN ]]; then
  exec runuser -u "$source_owner" -- "$0" "$MODE"
fi

GN=${KIBAOS_GN_BIN:-$CHROME_SRC/buildtools/linux64/gn}
NINJA=${KIBAOS_NINJA_BIN:-$CHROME_SRC/third_party/ninja/ninja}
[[ -x "$GN" ]] || { echo "GN is missing: $GN" >&2; exit 2; }
[[ -x "$NINJA" ]] || { echo "Ninja is missing: $NINJA" >&2; exit 2; }
cd "$CHROME_SRC"

case "$MODE" in
  gn)
    gn_args='target_os = "chromeos"
is_debug = false
is_component_build = false
is_official_build = false
symbol_level = 0
use_ozone = true
ozone_platform_wayland = true
use_system_minigbm = true
enable_rust = true'
    # Tools the bootstrap took from pacman need their own arguments; absent on
    # a checkout that uses Chromium's downloaded toolchain.
    if [[ -r "$CHROME_SRC/out/.kibaos/system-tools.gn" ]]; then
      gn_args+=$'\n'"$(<"$CHROME_SRC/out/.kibaos/system-tools.gn")"
    fi
    "$GN" gen "$OUT_DIR" --args="$gn_args"
    ;;
  targeted)
    read -r -a targets <<<"${KIBAOS_TARGETED_NINJA_TARGETS:-chromeos/dbus/power:power chromeos/ash/components/disks:disks ui/ozone/platform/wayland:wayland content/browser:browser ash}"
    "$NINJA" -C "$OUT_DIR" -j"${KIBAOS_NINJA_JOBS:-$(nproc)}" "${targets[@]}"
    ;;
  full-build)
    "$NINJA" -C "$OUT_DIR" -j"${KIBAOS_NINJA_JOBS:-$(nproc)}" \
      chrome chrome_sandbox
    ;;
esac
