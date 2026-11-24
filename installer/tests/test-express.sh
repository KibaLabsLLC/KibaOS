#!/usr/bin/env bash
# Express: an install with no questions, which only kibaos-vm asks for.
#
# Nobody is at the erase gate during an express install, so everything that
# gate is for has to be true before it is skipped: a virtual machine, a disk
# with nothing on it, every answer that matters, no encryption to type a
# passphrase for, and a real password hash. Each check here is one way the
# skip could erase something it should not, and each must fall back to the
# ordinary install with the answers filled in.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
export KIBAOS_TUI_COLUMNS=78

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-express: $*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || {
  echo 'installer express test: SKIP (openssl not available)'
  exit 0
}

install -d "$TMP/zoneinfo" "$TMP/locales" "$TMP/keymaps/i386/qwerty" \
  "$TMP/block/sda" "$TMP/block/sdb" "$TMP/dri" "$TMP/stub" \
  "$TMP/bundle" "$TMP/installer-meta"
: >"$TMP/zoneinfo/UTC"; : >"$TMP/locales/en_US"
: >"$TMP/keymaps/i386/qwerty/us.map.gz"; : >"$TMP/dri/renderD128"
cat >"$TMP/stub/loadkeys" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/stub/loadkeys"
# Nothing in this test may restart the machine running it. The done screen and
# the failure menu both offer a restart, and an earlier version of this test
# pressed enter on one as root and rebooted the developer's computer. So the
# restart is a stand in that writes a line, systemctl is a stub that refuses,
# and the live medium marker points somewhere that does not exist.
cat >"$TMP/stub/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >>"${KIBAOS_TEST_SYSTEMCTL_LOG:-/dev/null}"
exit 1
STUB
cat >"$TMP/stub/reboot-stand-in" <<'STUB'
#!/usr/bin/env bash
echo reboot >>"${KIBAOS_TEST_REBOOT_LOG:?}"
STUB
chmod +x "$TMP/stub/systemctl" "$TMP/stub/reboot-stand-in"
export PATH="$TMP/stub:$PATH"
export KIBAOS_REBOOT_CMD="$TMP/stub/reboot-stand-in"
export KIBAOS_TEST_REBOOT_LOG="$TMP/reboots"
export KIBAOS_TEST_SYSTEMCTL_LOG="$TMP/systemctl"
export KIBAOS_LIVE_MARKER="$TMP/not-a-live-medium"
printf '%s\n' '2026/07/12' >"$TMP/snapshot"
printf 'MemAvailable:   16000000 kB\n' >"$TMP/meminfo"
printf '%s\n' \
  '/dev/sda|931.5G|WDC WD10EZEX|sata|WD-WCC6Y4KP1234' \
  '/dev/sdb|28.7G|SanDisk Ultra|usb|4C5300011212' >"$TMP/disks"

PASSWORD='correct horse battery staple'
PASSPHRASE='a passphrase with spaces'

# A stub engine that records every invocation and writes journal records for
# the stages it claims to have run. KIBAOS_STUB_FAIL_AT names a stage to fail.
cat >"$TMP/stub-engine" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$KIBAOS_STUB_CALLS"
mode=dry-run
for arg in "$@"; do [[ $arg != --execute ]] || mode=execute; done
printf 'stub engine invoked in %s mode\n' "$mode"
[[ $mode == execute ]] || exit "${KIBAOS_STUB_DRYRUN_STATUS:-0}"

. "${KIBAOS_JOURNAL_LIB}"
target=''
previous=''
for arg in "$@"; do
  [[ $previous != --target ]] || target=$arg
  previous=$arg
done
kibaos_journal_init execute "$target"
printf 'stub engine running stages\n'
for stage in preflight package-check; do
  kibaos_journal_begin "$stage" "starting $stage"
  if [[ ${KIBAOS_STUB_FAIL_AT:-} == "$stage" ]]; then
    kibaos_journal_fail "$stage" 1 unexpected_exit "a step ended without reporting why" \
      retry export log shell reboot
    exit 1
  fi
  if [[ $stage == package-check ]]; then
    kibaos_journal_ok "$stage" workspace
  else
    kibaos_journal_ok "$stage" "finished $stage"
  fi
done
for stage in acquire confirm partition format mount pacstrap \
  configure bootloader snapshot verify-install; do
  kibaos_journal_begin "$stage" "starting $stage"
  if [[ ${KIBAOS_STUB_FAIL_AT:-} == "$stage" ]]; then
    kibaos_journal_fail "$stage" 1 unexpected_exit "a step ended without reporting why" \
      retry export log shell reboot
    exit 1
  fi
  kibaos_journal_ok "$stage" "finished $stage"
done
exit 0
STUB
chmod +x "$TMP/stub-engine"

export KIBAOS_ZONEINFO_DIR="$TMP/zoneinfo" KIBAOS_LOCALE_DIR="$TMP/locales"
export KIBAOS_KEYMAP_DIR="$TMP/keymaps" KIBAOS_BLOCK_DIR="$TMP/block"
export KIBAOS_SNAPSHOT_FILE="$TMP/snapshot" KIBAOS_DISK_TABLE="$TMP/disks"
export KIBAOS_PROBE_MEMINFO="$TMP/meminfo" KIBAOS_PROBE_DRI_DIR="$TMP/dri"
# The production probe allows five seconds for an optional eglinfo call. This
# fixture drives many independent installer flows, so bound that optional
# lookup tightly while retaining the dedicated probe test's renderer cases.
export KIBAOS_PROBE_GL_TIMEOUT=0.2
export KIBAOS_TUI_COLOR=none KIBAOS_TUI_FRAME=ascii
# Pinned so the progress screen picks the same layout everywhere.
export KIBAOS_TUI_HEIGHT=34
export KIBAOS_INSTALL_ENGINE="$TMP/stub-engine"
export KIBAOS_JOURNAL_LIB="$ROOT/installer/lib/kibaos-journal.sh"
export TMPDIR="$TMP"
export KIBAOS_BUNDLE_DIR="$TMP/bundle"
printf '%s\n' development-unsigned >"$TMP/installer-meta/repo-fingerprint"
export KIBAOS_REPO_FINGERPRINT_FILE="$TMP/installer-meta/repo-fingerprint"


# A virtual machine, and a disk that is blank.
printf '%s\n' '#!/usr/bin/env bash' 'echo "${KIBAOS_TEST_VIRT:-vmware}"' \
  '[[ ${KIBAOS_TEST_VIRT:-vmware} != none ]]' >"$TMP/stub/virt"
printf '%s\n' '#!/usr/bin/env bash' '[[ -n ${KIBAOS_TEST_SIGNATURE:-} ]] || exit 2' \
  'echo "$KIBAOS_TEST_SIGNATURE"' >"$TMP/stub/blkid"
chmod +x "$TMP/stub/virt" "$TMP/stub/blkid"
export KIBAOS_DETECT_VIRT="$TMP/stub/virt" KIBAOS_BLKID="$TMP/stub/blkid"
export KIBAOS_EXPRESS_RESTART_DELAY=0

openssl passwd -6 -salt testsalt 'a password' >"$TMP/hash"
chmod 600 "$TMP/hash"
printf '%s\n' locale=en_US.UTF-8 keymap=us timezone=UTC target=/dev/sda \
  hostname=express-box username=alex encrypt=no \
  profile=plus display_scale=125 apps=firefox,flatpak auto_snapshots=yes \
  wallpaper=quiet-rainleaves >"$TMP/answers"

run_express() {
  local name=$1 answers=${2:-$TMP/answers} hash=${3:-$TMP/hash}
  export KIBAOS_STUB_CALLS="$TMP/calls.$name"
  : >"$KIBAOS_STUB_CALLS"; : >"$TMP/keys.$name"; rm -f "$TMP/reboots"
  env KIBAOS_INSTALLER_TUI_LIB=1 \
      KIBAOS_TUI_KEYS="$TMP/keys.$name" \
      KIBAOS_JOURNAL_PATH="$TMP/journal.$name.jsonl" \
      KIBAOS_JOURNAL_RAW="$TMP/raw.$name.log" \
      bash -c '
        set -Eeuo pipefail
        . "$1"
        exec {_TUI_KEYFD}<"$KIBAOS_TUI_KEYS"
        export _TUI_KEYFD
        JOURNAL_FILE=$KIBAOS_JOURNAL_PATH
        RAW_LOG=$KIBAOS_JOURNAL_RAW
        ANSWERS_IN=$2 EXPRESS=1 EXPRESS_HASH=$3
        main_flow
      ' _ "$ROOT/installer/bin/kibaos-installer-tui" "$answers" "$hash" >"$TMP/out.$name" 2>&1
}

# --- everything in place: it installs and restarts ---------------------------
run_express happy || fail "the express install returned non-zero: $(tail -3 "$TMP/out.happy")"
calls=$TMP/calls.happy
(( $(wc -l <"$calls") == 2 )) || fail "expected a dry run and an install, got $(wc -l <"$calls") engine calls"
tail -1 "$calls" | grep -Fq -- '--execute' || fail 'the express install never executed'
tail -1 "$calls" | grep -Fq -- '--confirm ERASE:/dev/sda' || fail 'the express install did not confirm the disk it was given'
tail -1 "$calls" | grep -Fq -- '--username alex' || fail 'the express install lost the username'
tail -1 "$calls" | grep -Fq -- '--hostname express-box' || fail 'the express install lost the computer name'
! tail -1 "$calls" | grep -Fq -- '--encrypt' || fail 'the express install encrypted the disk'
tail -1 "$calls" | grep -Fq -- '--password-hash-file ' || fail 'the express install passed no password hash'
# The desktop answers ride along like any other.
for arg in '--feature-profile plus' '--display-scale 125' '--apps firefox,flatpak' '--auto-snapshots yes' \
    '--wallpaper quiet-rainleaves'; do
  tail -1 "$calls" | grep -Fq -- "$arg" || fail "the express install lost $arg"
done
! grep -Fq "$(cat "$TMP/hash")" "$TMP/out.happy" || fail 'the password hash was drawn on screen'
grep -Fq 'KibaOS is installed' "$TMP/out.happy" || fail 'the finished screen was never shown'
[[ $(cat "$TMP/reboots" 2>/dev/null) == reboot ]] || fail 'an express install did not restart by itself'
! grep -Fq 'Where should KibaOS be installed' "$TMP/out.happy" || fail 'an express install asked a question'

# --- every reason to stop, and each one stops before the engine runs --------
stopped() {
  local name=$1 why=$2
  ! grep -Fq -- '--execute' "$TMP/calls.$name" || fail "$name: the engine executed"
  grep -Fq 'The express install stopped before doing anything' "$TMP/out.$name" ||
    fail "$name: the stop was not explained"
  grep -Fq "$why" "$TMP/out.$name" || fail "$name: the reason was not '$why'"
  [[ ! -s $TMP/reboots ]] || fail "$name: restarted"
}

KIBAOS_TEST_VIRT=none run_express physical || true
stopped physical 'not a virtual machine'

KIBAOS_TEST_SIGNATURE=gpt run_express used-disk || true
stopped used-disk 'is not blank (it holds gpt)'

install -d "$TMP/block/sda/sda1"; : >"$TMP/block/sda/sda1/partition"
run_express partitioned || true
stopped partitioned 'already has partitions'
rm -rf "${TMP:?}/block/sda/sda1"

sed 's/^encrypt=no/encrypt=yes/' "$TMP/answers" >"$TMP/answers.enc"
run_express encrypted "$TMP/answers.enc" || true
stopped encrypted 'Encryption needs a passphrase'

grep -v '^username=' "$TMP/answers" >"$TMP/answers.nouser"
run_express no-user "$TMP/answers.nouser" || true
stopped no-user 'have no usable username'

run_express no-hash "$TMP/answers" "$TMP/missing" || true
stopped no-hash 'No password came with the answers'

printf 'hunter2\n' >"$TMP/plain"
run_express plain-password "$TMP/answers" "$TMP/plain" || true
stopped plain-password 'is not a password'

echo 'installer express test: PASS'
