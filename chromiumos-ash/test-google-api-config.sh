#!/bin/bash
# Verify OAuth fallback loading without starting a real Chromium process.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="${KIBAOS_LAUNCHER_PATH:-${SCRIPT_DIR}/chromiumos-ash.sh}"
# The recipe sits beside this script in the repository. Under makepkg the
# sources are copied into a separate `src/` directory and the recipe is one
# level up. Try both, and refuse to run if neither exists: a missing file
# makes every credential guard below match nothing and report a false pass.
if [[ -n "${KIBAOS_PKGBUILD_PATH:-}" ]]; then
    PKGBUILD="${KIBAOS_PKGBUILD_PATH}"
elif [[ -r "${SCRIPT_DIR}/PKGBUILD" ]]; then
    PKGBUILD="${SCRIPT_DIR}/PKGBUILD"
else
    PKGBUILD="${SCRIPT_DIR}/../PKGBUILD"
fi
if [[ ! -r "${PKGBUILD}" ]]; then
    echo "OAuth config test: cannot read the package recipe at ${PKGBUILD}" >&2
    exit 1
fi
CI_DIR="${KIBAOS_CI_DIR:-${SCRIPT_DIR}/../ci}"
TMP_DIR="$(mktemp -d "${SCRIPT_DIR}/.google-api-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT
chmod 777 "${TMP_DIR}"

# The public release is local-account first. Guard the package recipe so a
# future refactor cannot turn optional runtime configuration into a build-time
# credential requirement or embed a client identity in GN args.
if grep -Eq ': "\$\{GOOGLE_(API_KEY|DEFAULT_CLIENT_ID|DEFAULT_CLIENT_SECRET):\?' "${PKGBUILD}"; then
    echo "OAuth config test: public builds must not require Google credentials" >&2
    exit 1
fi
if grep -Eq 'google_(api_key|default_client_id|default_client_secret)[[:space:]]*=[[:space:]]*"[^" ]+' "${PKGBUILD}"; then
    echo "OAuth config test: public package must not embed Google credentials" >&2
    exit 1
fi

if [[ -d "${CI_DIR}" ]]; then
    for build_script in \
        build-current-chromiumos-ash-package.sh \
        build-release-candidate.sh \
        build-clean-arch-chromium-package.sh; do
        if grep -Eq ': "\$\{GOOGLE_(API_KEY|DEFAULT_CLIENT_ID|DEFAULT_CLIENT_SECRET):\?' \
            "${CI_DIR}/${build_script}"; then
            echo "OAuth config test: ${build_script} still requires credentials" >&2
            exit 1
        fi
        if grep -Eq 'google_(api_key|default_client_id|default_client_secret)[[:space:]]*=[[:space:]]*"[^" ]+' \
            "${CI_DIR}/${build_script}"; then
            echo "OAuth config test: ${build_script} embeds credentials" >&2
            exit 1
        fi
    done
    if ! grep -Fq 'KIBAOS_GOOGLE_API_CONF' "${LAUNCHER}"; then
        echo "OAuth config test: launcher runtime hook is missing" >&2
        exit 1
    fi
fi

mkdir -p "${TMP_DIR}/home" "${TMP_DIR}/config" "${TMP_DIR}/runtime"
chmod 700 "${TMP_DIR}/runtime"
DEFAULT_ID='fixture-default-id'
DEFAULT_VALUE='fixture-default-value'
cat >"${TMP_DIR}/default.conf" <<EOF
GOOGLE_API_KEY=
GOOGLE_DEFAULT_CLIENT_ID=${DEFAULT_ID}
GOOGLE_DEFAULT_CLIENT_SECRET=${DEFAULT_VALUE}
GOOGLE_CLIENT_ID_MAIN=${DEFAULT_ID}
GOOGLE_CLIENT_SECRET_MAIN=${DEFAULT_VALUE}
EOF
cat >"${TMP_DIR}/chrome" <<'EOF'
#!/bin/bash
{
    printf 'default_id=%s\n' "${GOOGLE_DEFAULT_CLIENT_ID:-}"
    printf 'default_secret=%s\n' "${GOOGLE_DEFAULT_CLIENT_SECRET:-}"
    printf 'main_id=%s\n' "${GOOGLE_CLIENT_ID_MAIN:-}"
    printf 'main_secret=%s\n' "${GOOGLE_CLIENT_SECRET_MAIN:-}"
} >"${KIBAOS_TEST_OUTPUT}"
EOF
chmod 755 "${TMP_DIR}/chrome"

run_launcher() {
    local user_config="${1:-}"
    rm -f "${TMP_DIR}/output"
    rm -rf "${TMP_DIR}/config/kibaos"
    if [[ -n "${user_config}" ]]; then
        mkdir -p "${TMP_DIR}/config/kibaos"
        printf '%s\n' "${user_config}" >"${TMP_DIR}/config/kibaos/google-api.conf"
    fi
    env \
        HOME="${TMP_DIR}/home" \
        XDG_CONFIG_HOME="${TMP_DIR}/config" \
        XDG_RUNTIME_DIR="${TMP_DIR}/runtime" \
        KIBAOS_CHROME="${TMP_DIR}/chrome" \
        KIBAOS_CHROME_SANDBOX=/bin/false \
        KIBAOS_GOOGLE_API_CONF="${TMP_DIR}/default.conf" \
        KIBAOS_TEST_OUTPUT="${TMP_DIR}/output" \
        KIBAOS_SKIP_SHILL_CHECK=1 \
        KIBAOS_ENABLE_PIPEWIRE_AUDIO=0 \
        KIBAOS_ENABLE_LOCAL_ACCOUNTS=0 \
        KIBAOS_LOCAL_AI_BOOTSTRAP=0 \
        KIBAOS_FEATURE_PROFILE=standard \
        KIBAOS_OZONE_PLATFORM=x11 \
        KIBAOS_DISABLE_SANDBOX=1 \
        DBUS_SESSION_BUS_ADDRESS=disabled \
        bash "${LAUNCHER}"
}

run_launcher
grep -Fxq "default_id=${DEFAULT_ID}" "${TMP_DIR}/output"
grep -Fxq "default_secret=${DEFAULT_VALUE}" "${TMP_DIR}/output"
grep -Fxq "main_id=${DEFAULT_ID}" "${TMP_DIR}/output"
grep -Fxq "main_secret=${DEFAULT_VALUE}" "${TMP_DIR}/output"

run_launcher $'GOOGLE_DEFAULT_CLIENT_ID=user-id\nGOOGLE_CLIENT_SECRET_MAIN=user-secret'
grep -Fxq 'default_id=user-id' "${TMP_DIR}/output"
grep -Fxq 'main_secret=user-secret' "${TMP_DIR}/output"
grep -Fxq "default_secret=${DEFAULT_VALUE}" "${TMP_DIR}/output"
grep -Fxq "main_id=${DEFAULT_ID}" "${TMP_DIR}/output"

echo "Chromium OAuth configuration test: PASS"
