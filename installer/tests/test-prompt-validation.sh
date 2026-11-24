#!/usr/bin/env bash
# Behavioural tests for the installer's input validation.
#
# These exist because the previous coverage grepped kibaos-installer for
# source text. That style of assertion passed against a keymap check whose
# find(1) group was split across newlines, so it rejected every layout
# including the default and looped forever at the prompt. Source text is not
# behaviour; this file runs the rules.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Fixture roots so the rules can be exercised on a machine that has no
# tzdata, no i18n sources and no console keymaps installed.
install -d -m 0755 \
  "$TMP/zoneinfo/America" "$TMP/zoneinfo/Europe" \
  "$TMP/locales" \
  "$TMP/keymaps/i386/qwerty" "$TMP/keymaps/i386/azerty"
: >"$TMP/zoneinfo/UTC"
: >"$TMP/zoneinfo/America/Chicago"
: >"$TMP/zoneinfo/Europe/Paris"
: >"$TMP/zoneinfo/zone.tab"
: >"$TMP/zoneinfo/leapseconds"
: >"$TMP/locales/en_US"
: >"$TMP/locales/fr_FR"
: >"$TMP/keymaps/i386/qwerty/us.map.gz"
: >"$TMP/keymaps/i386/qwerty/us-altgr-intl.map.gz"
: >"$TMP/keymaps/i386/azerty/fr.map.gz"

export KIBAOS_ZONEINFO_DIR="$TMP/zoneinfo"
export KIBAOS_LOCALE_DIR="$TMP/locales"
export KIBAOS_KEYMAP_DIR="$TMP/keymaps"

# shellcheck source=../lib/kibaos-validate.sh
. "$ROOT/installer/lib/kibaos-validate.sh"

failures=0
accept() {
  local fn=$1 value=$2
  if ! "$fn" "$value"; then
    printf 'FAIL: %s should have accepted %q\n' "$fn" "$value" >&2
    failures=$((failures + 1))
  fi
}
reject() {
  local fn=$1 value=$2
  if "$fn" "$value"; then
    printf 'FAIL: %s should have rejected %q\n' "$fn" "$value" >&2
    failures=$((failures + 1))
  fi
}

# The default offered by every prompt must be accepted by its own rule.
# This is the exact regression that hung the installer.
accept kibaos_valid_timezone UTC
accept kibaos_valid_locale en_US.UTF-8
accept kibaos_valid_keymap us
accept kibaos_valid_hostname kibaos
accept kibaos_valid_arch_snapshot 2026/07/12

# Confirmation normalization is behavioral: line delimiters are removed, but
# other control bytes remain and therefore cannot satisfy an exact token.
normalized=$(kibaos_normalize_confirmation $'ERASE:/dev/sda\r\n')
[[ $normalized == 'ERASE:/dev/sda' ]] || {
  printf 'FAIL: CR/LF confirmation delimiters were not normalized\n' >&2
  failures=$((failures + 1))
}
normalized=$(kibaos_normalize_confirmation $'\x1bERASE:/dev/sda')
[[ $normalized != 'ERASE:/dev/sda' ]] || {
  printf 'FAIL: non-line control byte was silently normalized\n' >&2
  failures=$((failures + 1))
}

accept kibaos_valid_timezone America/Chicago
accept kibaos_valid_timezone Europe/Paris
reject kibaos_valid_timezone America/Nowhere
reject kibaos_valid_timezone zone.tab
reject kibaos_valid_timezone leapseconds
reject kibaos_valid_timezone ../../etc/passwd
reject kibaos_valid_timezone ''
reject kibaos_valid_timezone 'UTC; rm -rf /'

accept kibaos_valid_locale fr_FR.UTF-8
accept kibaos_valid_locale C
accept kibaos_valid_locale C.UTF-8
accept kibaos_valid_locale POSIX
reject kibaos_valid_locale xx_YY.UTF-8
reject kibaos_valid_locale ''
reject kibaos_valid_locale '../../etc/passwd'

accept kibaos_valid_keymap us-altgr-intl
accept kibaos_valid_keymap fr
reject kibaos_valid_keymap de
reject kibaos_valid_keymap ''
reject kibaos_valid_keymap '../../etc/passwd'
reject kibaos_valid_keymap 'us; rm -rf /'

accept kibaos_valid_username kibaos
accept kibaos_valid_username a
accept kibaos_valid_username _test-user1
reject kibaos_valid_username Kibaos
reject kibaos_valid_username 1abc
reject kibaos_valid_username ''
reject kibaos_valid_username 'has space'
reject kibaos_valid_username root
reject kibaos_valid_username nobody
reject kibaos_valid_username systemd-network
reject kibaos_valid_username "$(printf 'a%.0s' {1..33})"

accept kibaos_valid_hostname kibaos-laptop
accept kibaos_valid_hostname a
accept kibaos_valid_hostname host123
reject kibaos_valid_hostname -leading
reject kibaos_valid_hostname trailing-
reject kibaos_valid_hostname 'has space'
reject kibaos_valid_hostname 'under_score'
# The one name that passes every rule above and must still be refused. Every
# machine maps it to 127.0.0.1, so a computer called this resolves its own
# name to itself and then cannot be reached by it.
reject kibaos_valid_hostname localhost
reject kibaos_valid_hostname LocalHost
reject kibaos_valid_hostname LOCALHOST
# And the names near it are ordinary names, so the rule has to be the word and
# not a pattern that swallows anything containing it.
accept kibaos_valid_hostname localhost2
accept kibaos_valid_hostname my-localhost
reject kibaos_valid_hostname ''
reject kibaos_valid_hostname "$(printf 'a%.0s' {1..64})"
reject kibaos_valid_arch_snapshot 2026/02/30
reject kibaos_valid_arch_snapshot 2026/13/01
reject kibaos_valid_arch_snapshot 2026-07-12
reject kibaos_valid_arch_snapshot ''

# The destructive confirmation gate must bind to the complete disk identity,
# not merely a reused /dev path. Virtual disks without serial/WWN remain
# usable through the size/model/transport tuple.
if ! kibaos_target_identity_matches \
  /dev/vda 16G VirtIO disk '' '' /dev/vda 16G VirtIO disk '' ''; then
  fail 'matching virtual-disk identity was rejected'
fi
if kibaos_target_identity_matches \
  /dev/vda 16G VirtIO disk SERIAL-1 WWN-1 /dev/vda 16G VirtIO disk SERIAL-2 WWN-1; then
  fail 'changed serial was accepted at the confirmation gate'
fi
if kibaos_target_identity_matches \
  /dev/vda 16G VirtIO disk '' '' /dev/vda 32G VirtIO disk '' ''; then
  fail 'changed disk size was accepted at the confirmation gate'
fi

# A missing keymap directory must reject rather than abort the front end
# under `set -e`, so the prompt can explain itself instead of exiting.
KIBAOS_KEYMAP_DIR="$TMP/does-not-exist" reject kibaos_valid_keymap us

if (( failures )); then
  printf 'installer prompt validation test: FAIL (%d)\n' "$failures" >&2
  exit 1
fi
echo 'installer prompt validation test: PASS'
