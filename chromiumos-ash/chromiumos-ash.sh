
#!/bin/bash
# Launcher for ChromiumOS Ash desktop on Linux.
# Runs as the calling user with data stored in their home directory.
#
# Usage:
#   chromiumos-ash                 # interactive session (login manager)
#   chromiumos-ash --login-manager # same as above
#   chromiumos-ash --guest-session # skip sign-in, go straight to guest mode
set -e

CHROME="${KIBAOS_CHROME:-/usr/lib/chromiumos-ash/chrome}"
CHROME_SANDBOX="${KIBAOS_CHROME_SANDBOX:-/usr/lib/chromiumos-ash/chrome-sandbox}"
FEATURES_CONF="${KIBAOS_FEATURES_CONF:-/etc/kibaos/features.conf}"
GOOGLE_API_CONF="${KIBAOS_GOOGLE_API_CONF:-/etc/kibaos/google-api.conf}"

KIBAOS_EXPOSE_SYSTEM_VOLUMES="${KIBAOS_EXPOSE_SYSTEM_VOLUMES:-0}"
KIBAOS_DISABLE_SANDBOX="${KIBAOS_DISABLE_SANDBOX:-0}"
KIBAOS_OZONE_PLATFORM="${KIBAOS_OZONE_PLATFORM:-}"
KIBAOS_DEV_STUB_OOBE="${KIBAOS_DEV_STUB_OOBE:-0}"
KIBAOS_ENABLE_LOCAL_ACCOUNTS="${KIBAOS_ENABLE_LOCAL_ACCOUNTS:-1}"
KIBAOS_ASH_HOST_WINDOW_BOUNDS="${KIBAOS_ASH_HOST_WINDOW_BOUNDS:-}"
KIBAOS_DISPLAY_SCALE="${KIBAOS_DISPLAY_SCALE:-}"
KIBAOS_FEATURE_PROFILE="${KIBAOS_FEATURE_PROFILE:-}"
KIBAOS_DISABLE_CHROMEVOX_HINT_TIMER="${KIBAOS_DISABLE_CHROMEVOX_HINT_TIMER:-1}"
KIBAOS_CHROME_EXTRA_FLAGS="${KIBAOS_CHROME_EXTRA_FLAGS:-}"
KIBAOS_DEFAULT_WALLPAPER="${KIBAOS_DEFAULT_WALLPAPER:-}"
KIBAOS_GOOGLE_API_CONF="${KIBAOS_GOOGLE_API_CONF:-${GOOGLE_API_CONF}}"
KIBAOS_SKIP_SHILL_CHECK="${KIBAOS_SKIP_SHILL_CHECK:-0}"
KIBAOS_USE_HOST_POWER_STATUS="${KIBAOS_USE_HOST_POWER_STATUS:-1}"
KIBAOS_ENABLE_PIPEWIRE_AUDIO="${KIBAOS_ENABLE_PIPEWIRE_AUDIO:-1}"
KIBAOS_ENABLE_LOCAL_AMBIENT_BACKEND="${KIBAOS_ENABLE_LOCAL_AMBIENT_BACKEND:-1}"
KIBAOS_SKIP_CHAPS_KEY_PERMISSION_UPDATES="${KIBAOS_SKIP_CHAPS_KEY_PERMISSION_UPDATES:-1}"
KIBAOS_DISABLE_EXTERNAL_METRICS="${KIBAOS_DISABLE_EXTERNAL_METRICS:-1}"
KIBAOS_STRUCTURED_METRICS_DIR="${KIBAOS_STRUCTURED_METRICS_DIR:-}"
KIBAOS_PERFETTO_DIR="${KIBAOS_PERFETTO_DIR:-}"
KIBAOS_DISABLE_SAMPLE_SYSTEM_WEB_APP="${KIBAOS_DISABLE_SAMPLE_SYSTEM_WEB_APP:-1}"
KIBAOS_DISABLE_CHROMEOS_CONNECTED_DEVICE_FEATURES="${KIBAOS_DISABLE_CHROMEOS_CONNECTED_DEVICE_FEATURES:-1}"
KIBAOS_DISABLE_ARC_FEATURES="${KIBAOS_DISABLE_ARC_FEATURES:-1}"
KIBAOS_USE_FLOSS_STUBS="${KIBAOS_USE_FLOSS_STUBS:-1}"
KIBAOS_ALLOW_GPU_COMPOSITING_FALLBACK="${KIBAOS_ALLOW_GPU_COMPOSITING_FALLBACK:-1}"
KIBAOS_ANDROID="${KIBAOS_ANDROID:-auto}"
KIBAOS_ENABLE_DEVTOOLS_PORT="${KIBAOS_ENABLE_DEVTOOLS_PORT:-0}"
KIBAOS_DEVTOOLS_PORT="${KIBAOS_DEVTOOLS_PORT:-9222}"
KIBAOS_ENABLE_SPEECH_DISPATCHER="${KIBAOS_ENABLE_SPEECH_DISPATCHER:-1}"

if [ -r "${FEATURES_CONF}" ]; then
    # shellcheck source=/dev/null
    . "${FEATURES_CONF}"
fi

if [ "${KIBAOS_DISABLE_SANDBOX}" != "1" ] && \
    [ -x "${CHROME_SANDBOX}" ] && \
    [ -z "${CHROME_DEVEL_SANDBOX:-}" ]; then
    export CHROME_DEVEL_SANDBOX="${CHROME_SANDBOX}"
fi

# --- Drop root to the original user ---------------------------------
if [ "$(id -u)" -eq 0 ]; then
    REAL_USER="${SUDO_USER:-$(logname 2>/dev/null)}"
    if [ -z "${REAL_USER}" ]; then
        echo "ERROR: Running as root but cannot determine the original user."
        echo "       Run this script as a regular user instead."
        exit 1
    fi

    REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"

    exec runuser -u "${REAL_USER}" -- env \
        DISPLAY="${DISPLAY:-}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
        XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-}" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "${REAL_USER}")" \
        DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
        CHROME_DEVEL_SANDBOX="${CHROME_DEVEL_SANDBOX:-}" \
        KIBAOS_CHROME="${CHROME}" \
        KIBAOS_CHROME_SANDBOX="${CHROME_SANDBOX}" \
        KIBAOS_FEATURES_CONF="${FEATURES_CONF}" \
        KIBAOS_GOOGLE_API_CONF="${KIBAOS_GOOGLE_API_CONF}" \
        KIBAOS_EXPOSE_SYSTEM_VOLUMES="${KIBAOS_EXPOSE_SYSTEM_VOLUMES}" \
        KIBAOS_DISABLE_SANDBOX="${KIBAOS_DISABLE_SANDBOX}" \
        KIBAOS_OZONE_PLATFORM="${KIBAOS_OZONE_PLATFORM}" \
        KIBAOS_DEV_STUB_OOBE="${KIBAOS_DEV_STUB_OOBE}" \
        KIBAOS_ENABLE_LOCAL_ACCOUNTS="${KIBAOS_ENABLE_LOCAL_ACCOUNTS}" \
        KIBAOS_ASH_HOST_WINDOW_BOUNDS="${KIBAOS_ASH_HOST_WINDOW_BOUNDS}" \
        KIBAOS_DISPLAY_SCALE="${KIBAOS_DISPLAY_SCALE}" \
        KIBAOS_FEATURE_PROFILE="${KIBAOS_FEATURE_PROFILE}" \
        KIBAOS_DISABLE_CHROMEVOX_HINT_TIMER="${KIBAOS_DISABLE_CHROMEVOX_HINT_TIMER}" \
        KIBAOS_CHROME_EXTRA_FLAGS="${KIBAOS_CHROME_EXTRA_FLAGS}" \
        KIBAOS_DEFAULT_WALLPAPER="${KIBAOS_DEFAULT_WALLPAPER}" \
        KIBAOS_SKIP_SHILL_CHECK="${KIBAOS_SKIP_SHILL_CHECK}" \
        KIBAOS_USE_HOST_POWER_STATUS="${KIBAOS_USE_HOST_POWER_STATUS}" \
        KIBAOS_ENABLE_PIPEWIRE_AUDIO="${KIBAOS_ENABLE_PIPEWIRE_AUDIO}" \
        KIBAOS_ENABLE_LOCAL_AMBIENT_BACKEND="${KIBAOS_ENABLE_LOCAL_AMBIENT_BACKEND}" \
        KIBAOS_SKIP_CHAPS_KEY_PERMISSION_UPDATES="${KIBAOS_SKIP_CHAPS_KEY_PERMISSION_UPDATES}" \
        KIBAOS_DISABLE_EXTERNAL_METRICS="${KIBAOS_DISABLE_EXTERNAL_METRICS}" \
        KIBAOS_STRUCTURED_METRICS_DIR="${KIBAOS_STRUCTURED_METRICS_DIR}" \
        KIBAOS_PERFETTO_DIR="${KIBAOS_PERFETTO_DIR}" \
        KIBAOS_DISABLE_SAMPLE_SYSTEM_WEB_APP="${KIBAOS_DISABLE_SAMPLE_SYSTEM_WEB_APP}" \
        KIBAOS_DISABLE_CHROMEOS_CONNECTED_DEVICE_FEATURES="${KIBAOS_DISABLE_CHROMEOS_CONNECTED_DEVICE_FEATURES}" \
        KIBAOS_DISABLE_ARC_FEATURES="${KIBAOS_DISABLE_ARC_FEATURES}" \
        KIBAOS_USE_FLOSS_STUBS="${KIBAOS_USE_FLOSS_STUBS}" \
        KIBAOS_ALLOW_GPU_COMPOSITING_FALLBACK="${KIBAOS_ALLOW_GPU_COMPOSITING_FALLBACK}" \
        KIBAOS_SOFTWARE_RENDERING="${KIBAOS_SOFTWARE_RENDERING:-0}" \
        KIBAOS_ANDROID="${KIBAOS_ANDROID}" \
        KIBAOS_ENABLE_DEVTOOLS_PORT="${KIBAOS_ENABLE_DEVTOOLS_PORT}" \
        KIBAOS_DEVTOOLS_PORT="${KIBAOS_DEVTOOLS_PORT}" \
        KIBAOS_ENABLE_SPEECH_DISPATCHER="${KIBAOS_ENABLE_SPEECH_DISPATCHER}" \
        GOOGLE_API_KEY="${GOOGLE_API_KEY:-}" \
        GOOGLE_DEFAULT_CLIENT_ID="${GOOGLE_DEFAULT_CLIENT_ID:-}" \
        GOOGLE_DEFAULT_CLIENT_SECRET="${GOOGLE_DEFAULT_CLIENT_SECRET:-}" \
        GOOGLE_CLIENT_ID_MAIN="${GOOGLE_CLIENT_ID_MAIN:-}" \
        GOOGLE_CLIENT_SECRET_MAIN="${GOOGLE_CLIENT_SECRET_MAIN:-}" \
        HOME="${REAL_HOME}" \
        "${0}" "$@"
fi

kibaos_default_feature_profile() {
    local mem_total_kib=""

    if [ -r /proc/meminfo ]; then
        mem_total_kib="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
    fi

    case "${mem_total_kib}" in
        ""|*[!0-9]*)
            echo "standard"
            ;;
        *)
            if [ "${mem_total_kib}" -ge 8388608 ]; then
                echo "plus"
            else
                echo "standard"
            fi
            ;;
    esac
}

kibaos_normalize_feature_profile() {
    local profile="${1,,}"

    profile="${profile%\"}"
    profile="${profile#\"}"
    profile="${profile%\'}"
    profile="${profile#\'}"

    case "${profile}" in
        standard|plus|advanced_plus)
            echo "${profile}"
            ;;
        *)
            return 1
            ;;
    esac
}

kibaos_read_feature_profile_config() {
    local config="$1"
    local key value

    [ -r "${config}" ] || return 0

    while IFS='=' read -r key value; do
        case "${key}" in
            KIBAOS_FEATURE_PROFILE|profile)
                echo "${value}"
                return 0
                ;;
        esac
    done <"${config}"
}

kibaos_read_config_value() {
    local config="$1"
    local requested_key="$2"
    local key value

    [ -r "${config}" ] || return 0

    while IFS='=' read -r key value; do
        case "${key}" in
            "${requested_key}")
                echo "${value}"
                return 0
                ;;
        esac
    done <"${config}"
}

kibaos_apply_google_api_config() {
    local config="$1"
    local value

    [ -r "${config}" ] || return 0

    if [ -z "${GOOGLE_API_KEY:-}" ]; then
        value="$(kibaos_read_config_value "${config}" "GOOGLE_API_KEY")"
        [ -z "${value}" ] || GOOGLE_API_KEY="${value}"
    fi

    if [ -z "${GOOGLE_DEFAULT_CLIENT_ID:-}" ]; then
        value="$(kibaos_read_config_value "${config}" "GOOGLE_DEFAULT_CLIENT_ID")"
        [ -z "${value}" ] || GOOGLE_DEFAULT_CLIENT_ID="${value}"
    fi

    if [ -z "${GOOGLE_DEFAULT_CLIENT_SECRET:-}" ]; then
        value="$(kibaos_read_config_value "${config}" "GOOGLE_DEFAULT_CLIENT_SECRET")"
        [ -z "${value}" ] || GOOGLE_DEFAULT_CLIENT_SECRET="${value}"
    fi

    if [ -z "${GOOGLE_CLIENT_ID_MAIN:-}" ]; then
        value="$(kibaos_read_config_value "${config}" "GOOGLE_CLIENT_ID_MAIN")"
        [ -z "${value}" ] || GOOGLE_CLIENT_ID_MAIN="${value}"
    fi

    if [ -z "${GOOGLE_CLIENT_SECRET_MAIN:-}" ]; then
        value="$(kibaos_read_config_value "${config}" "GOOGLE_CLIENT_SECRET_MAIN")"
        [ -z "${value}" ] || GOOGLE_CLIENT_SECRET_MAIN="${value}"
    fi
}

kibaos_join_csv() {
    local joined=""
    local item

    for item in "$@"; do
        if [ -z "${joined}" ]; then
            joined="${item}"
        else
            joined="${joined},${item}"
        fi
    done

    echo "${joined}"
}

if [ -z "${KIBAOS_STRUCTURED_METRICS_DIR}" ]; then
    KIBAOS_STRUCTURED_METRICS_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/kibaos/metrics/structured"
fi

if [ -z "${KIBAOS_PERFETTO_DIR}" ]; then
    KIBAOS_PERFETTO_DIR="${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/kibaos}/perfetto"
fi

export KIBAOS_USE_HOST_POWER_STATUS
export KIBAOS_ENABLE_PIPEWIRE_AUDIO
export KIBAOS_ENABLE_LOCAL_AMBIENT_BACKEND
export KIBAOS_SKIP_CHAPS_KEY_PERMISSION_UPDATES
export KIBAOS_DISABLE_EXTERNAL_METRICS
export KIBAOS_STRUCTURED_METRICS_DIR
export KIBAOS_PERFETTO_DIR
export KIBAOS_DISABLE_SAMPLE_SYSTEM_WEB_APP
export KIBAOS_DISABLE_CHROMEOS_CONNECTED_DEVICE_FEATURES
export KIBAOS_DISABLE_ARC_FEATURES
export KIBAOS_USE_FLOSS_STUBS
export KIBAOS_ALLOW_GPU_COMPOSITING_FALLBACK

# Apply the user file first so it really is an override.
# The system file fills values the user did not specify.
# Environment variables remain highest priority.
kibaos_apply_google_api_config "${XDG_CONFIG_HOME:-${HOME}/.config}/kibaos/google-api.conf"
kibaos_apply_google_api_config "${KIBAOS_GOOGLE_API_CONF}"

export GOOGLE_API_KEY
export GOOGLE_DEFAULT_CLIENT_ID
export GOOGLE_DEFAULT_CLIENT_SECRET
export GOOGLE_CLIENT_ID_MAIN
export GOOGLE_CLIENT_SECRET_MAIN

if [ -z "${KIBAOS_DISPLAY_SCALE}" ]; then
    KIBAOS_DISPLAY_CONFIG="${XDG_CONFIG_HOME:-${HOME}/.config}/kibaos/display.conf"

    if [ -r "${KIBAOS_DISPLAY_CONFIG}" ]; then
        while IFS='=' read -r key value; do
            if [ "${key}" = "scale" ] && [ -n "${value}" ]; then
                KIBAOS_DISPLAY_SCALE="${value}"
                break
            fi
        done <"${KIBAOS_DISPLAY_CONFIG}"
    fi
fi

export KIBAOS_DISPLAY_SCALE

# Pass display.conf to Ash so it can read per-monitor scale settings.
if [ -z "${KIBAOS_DISPLAY_CONF_TEXT:-}" ]; then
    KIBAOS_DISPLAY_CONFIG="${XDG_CONFIG_HOME:-${HOME}/.config}/kibaos/display.conf"

    if [ -r "${KIBAOS_DISPLAY_CONFIG}" ]; then
        KIBAOS_DISPLAY_CONF_TEXT="$(head -c 65536 -- "${KIBAOS_DISPLAY_CONFIG}")"
    fi
fi

export KIBAOS_DISPLAY_CONF_TEXT

KIBAOS_USER_FEATURES_CONFIG="${XDG_CONFIG_HOME:-${HOME}/.config}/kibaos/features.conf"
KIBAOS_CONFIGURED_FEATURE_PROFILE="$(kibaos_read_feature_profile_config "${KIBAOS_USER_FEATURES_CONFIG}")"

if [ -n "${KIBAOS_CONFIGURED_FEATURE_PROFILE}" ]; then
    KIBAOS_FEATURE_PROFILE="${KIBAOS_CONFIGURED_FEATURE_PROFILE}"
fi

KIBAOS_REQUESTED_FEATURE_PROFILE="${KIBAOS_FEATURE_PROFILE}"

if KIBAOS_NORMALIZED_FEATURE_PROFILE="$(kibaos_normalize_feature_profile "${KIBAOS_FEATURE_PROFILE}")"; then
    KIBAOS_FEATURE_PROFILE="${KIBAOS_NORMALIZED_FEATURE_PROFILE}"
else
    if [ -n "${KIBAOS_REQUESTED_FEATURE_PROFILE}" ]; then
        echo "WARNING: unknown KIBAOS_FEATURE_PROFILE=${KIBAOS_REQUESTED_FEATURE_PROFILE}; using automatic profile." >&2
    fi

    KIBAOS_FEATURE_PROFILE="$(kibaos_default_feature_profile)"
fi

export KIBAOS_FEATURE_PROFILE

# --- Now running as the real user -----------------------------------
KIBAOS_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/kibaos"
USER_DATA_DIR="${KIBAOS_DATA_HOME}/chromiumos-ash"
LEGACY_USER_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/chromiumos-ash"

# Ensure DBus is running.
if [ -z "${DBUS_SESSION_BUS_ADDRESS}" ]; then
    eval "$(dbus-launch --sh-syntax)"
    export DBUS_SESSION_BUS_ADDRESS
    trap 'kill "${DBUS_SESSION_BUS_PID}"' EXIT
fi

# Ensure shill-nm-adapter is running.
if [ "${KIBAOS_SKIP_SHILL_CHECK}" != "1" ] && \
    ! dbus-send --system --dest=org.chromium.flimflam \
    / org.chromium.flimflam.Manager.GetProperties \
    >/dev/null 2>&1; then

    echo "Starting shill-nm-adapter..."

    if command -v systemctl &>/dev/null; then
        systemctl --user start shill-nm-adapter 2>/dev/null || \
        sudo systemctl start shill-nm-adapter 2>/dev/null || true
    fi

    echo "WARNING: shill-nm-adapter not running. Network may not work."
fi

if [ "${KIBAOS_ENABLE_PIPEWIRE_AUDIO}" = "1" ] && \
    command -v kibaos-audio >/dev/null 2>&1; then

    if ! kibaos-audio ensure >/dev/null 2>&1; then
        echo "WARNING: PipeWire audio stack is not ready. Run 'kibaos-audio status' for details." >&2
    fi
fi

# Ensure user data directory exists.
# Migrate the old pre-XDG KibaOS path once.
if [ ! -e "${USER_DATA_DIR}" ] && [ -d "${LEGACY_USER_DATA_DIR}" ]; then
    mkdir -p "${KIBAOS_DATA_HOME}"
    mv "${LEGACY_USER_DATA_DIR}" "${USER_DATA_DIR}"
fi

mkdir -p "${USER_DATA_DIR}"

# Refresh the browser icon cache after icon changes.
if [ ! -e "${USER_DATA_DIR}/.kibaos-browser-icon-2" ]; then
    rm -rf "${USER_DATA_DIR}"/*/app_service/icons/mgndgikekgjfcpckkfioiadnlibdjbkf
    : >"${USER_DATA_DIR}/.kibaos-browser-icon-2"
fi

mkdir -p \
    "${KIBAOS_STRUCTURED_METRICS_DIR}/chromium/storage/flushed" \
    "${KIBAOS_STRUCTURED_METRICS_DIR}/chromium" \
    "${KIBAOS_PERFETTO_DIR}"

export PERFETTO_PRODUCER_SOCK_NAME="${PERFETTO_PRODUCER_SOCK_NAME:-${KIBAOS_PERFETTO_DIR}/traced-producer.sock}"
export PERFETTO_CONSUMER_SOCK_NAME="${PERFETTO_CONSUMER_SOCK_NAME:-${KIBAOS_PERFETTO_DIR}/traced-consumer.sock}"

if [ "${KIBAOS_ENABLE_LOCAL_ACCOUNTS}" = "1" ]; then
    KIBAOS_LOCAL_USERNAME="${USER:-$(id -un)}"

    mkdir -p \
        "${HOME}/Desktop" \
        "${HOME}/Documents" \
        "${HOME}/Downloads" \
        "${HOME}/Music" \
        "${HOME}/Pictures" \
        "${HOME}/Videos" \
        "${USER_DATA_DIR}/.home_user/local-${KIBAOS_LOCAL_USERNAME}"
fi

if [ -z "${KIBAOS_OZONE_PLATFORM}" ]; then
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        KIBAOS_OZONE_PLATFORM=wayland
    else
        KIBAOS_OZONE_PLATFORM=x11
    fi
fi

LOGIN_FLAGS=(--login-manager)

# Default flags for ChromeOS Ash desktop on Linux.
FLAGS=(
    "${LOGIN_FLAGS[@]}"
    --ozone-platform="${KIBAOS_OZONE_PLATFORM}"
    --user-data-dir="${USER_DATA_DIR}"
    --enable-logging=stderr
    --log-level=0
    --v=0
    --disable-sync
    --enable-wayland-server
)

# Chrome keeps only the last --enable-features argument.
KIBAOS_ENABLED_FEATURES=(AudioFocusEnforcement)

# Chrome keeps only the last --disable-features argument.
KIBAOS_DISABLED_FEATURES=()

if [ "${KIBAOS_FEATURE_PROFILE}" = "plus" ] || \
    [ "${KIBAOS_FEATURE_PROFILE}" = "advanced_plus" ]; then

    # Expose stable local Chromebook Plus-style features.
    KIBAOS_PLUS_FEATURES=(
        FeatureManagementRoundedWindows
        FeatureManagement16Desks
        FeatureManagementTimeOfDayWallpaper
        FeatureManagementTimeOfDayScreenSaver
        FeatureManagementLocalImageSearch
        FilesLocalImageSearch
    )

    if [ "${KIBAOS_FEATURE_PROFILE}" = "advanced_plus" ]; then
        # Experimental non-AI feature surface.
        KIBAOS_PLUS_FEATURES+=(
            FeatureManagementBorealis
            FeatureManagementGameDashboardRecordGame
            FeatureManagementShowoff
            FeatureManagementVideoConference
        )
    fi

    KIBAOS_ENABLED_FEATURES+=("${KIBAOS_PLUS_FEATURES[@]}")
fi

# Apply the configured default wallpaper.
if [ -n "${KIBAOS_DEFAULT_WALLPAPER}" ]; then
    if [ -r "${KIBAOS_DEFAULT_WALLPAPER}" ]; then
        FLAGS+=(
            --default-wallpaper-large="${KIBAOS_DEFAULT_WALLPAPER}"
            --default-wallpaper-small="${KIBAOS_DEFAULT_WALLPAPER}"
        )

        KIBAOS_KEPT_FEATURES=()

        for feature in "${KIBAOS_ENABLED_FEATURES[@]}"; do
            case "${feature}" in
                FeatureManagementTimeOfDayWallpaper|FeatureManagementTimeOfDayScreenSaver)
                    ;;
                *)
                    KIBAOS_KEPT_FEATURES+=("${feature}")
                    ;;
            esac
        done

        KIBAOS_ENABLED_FEATURES=("${KIBAOS_KEPT_FEATURES[@]}")

        KIBAOS_DISABLED_FEATURES+=(
            FeatureManagementTimeOfDayWallpaper
            FeatureManagementTimeOfDayScreenSaver
        )
    else
        echo "WARNING: KIBAOS_DEFAULT_WALLPAPER=${KIBAOS_DEFAULT_WALLPAPER} cannot be read; keeping the default wallpaper." >&2
    fi
fi

if [ -n "${KIBAOS_ASH_HOST_WINDOW_BOUNDS}" ]; then
    FLAGS+=(--ash-host-window-bounds="${KIBAOS_ASH_HOST_WINDOW_BOUNDS}")
fi

if [ "${KIBAOS_ENABLE_LOCAL_ACCOUNTS}" = "1" ]; then
    FLAGS+=(--kibaos-enable-local-accounts)
    FLAGS+=(--disable-first-run-ui)
fi

if [ "${KIBAOS_DISABLE_CHROMEVOX_HINT_TIMER}" = "1" ]; then
    FLAGS+=(--disable-oobe-chromevox-hint-timer-for-testing)
fi

if [ "${KIBAOS_DISABLE_SAMPLE_SYSTEM_WEB_APP}" = "1" ]; then
    FLAGS+=(--kibaos-disable-sample-system-web-app)
fi

if [ "${KIBAOS_DEV_STUB_OOBE}" = "1" ]; then
    FLAGS+=(--stub-config --stub-auth)
fi

if [ "${KIBAOS_DISABLE_ARC_FEATURES}" = "1" ]; then
    FLAGS+=(--kibaos-disable-arc-features)
fi

if [ "${KIBAOS_USE_FLOSS_STUBS}" = "1" ]; then
    FLAGS+=(--kibaos-use-floss-stubs)
fi

if [ "${KIBAOS_DISABLE_SANDBOX}" = "1" ]; then
    FLAGS+=(--no-sandbox --disable-gpu-sandbox)
fi

if [ "${KIBAOS_EXPOSE_SYSTEM_VOLUMES}" = "1" ]; then
    FLAGS+=(--kibaos-expose-system-volumes)
fi

if [ "${KIBAOS_DISABLE_CHROMEOS_CONNECTED_DEVICE_FEATURES}" = "1" ]; then
    FLAGS+=(--kibaos-disable-chromeos-connected-device-features)

    KIBAOS_DISABLED_FEATURES+=(
        PhoneHub
        EcheSWA
        EcheSWASendStartSignaling
        EcheSWACheckAndroidNetworkInfo
    )
fi

# The DevTools port grants broad access to browser sessions.
# It remains disabled unless explicitly enabled.
if [ "${KIBAOS_ENABLE_DEVTOOLS_PORT}" = "1" ]; then
    FLAGS+=(
        --remote-debugging-address=127.0.0.1
        "--remote-debugging-port=${KIBAOS_DEVTOOLS_PORT}"
    )
fi

if [ "${KIBAOS_ENABLE_SPEECH_DISPATCHER}" = "1" ]; then
    FLAGS+=(--enable-speech-dispatcher)
fi

# Android apps: Ash ARC integration through the KibaOS Android service.
if [ "${KIBAOS_ANDROID}" = "auto" ]; then
    if [ -x /usr/lib/kibaos-android/kibaos-android ]; then
        KIBAOS_ANDROID=1
    else
        KIBAOS_ANDROID=0
    fi
fi

if [ "${KIBAOS_ANDROID}" = "1" ]; then
    timeout 15 busctl --system call org.kibaos.Android1 /org/kibaos/Android1 \
        org.freedesktop.DBus.Peer Ping >/dev/null 2>&1 || true

    FLAGS+=(
        --kibaos-android
        --arc-availability=officially-supported
        --arc-start-mode=always-start-with-no-play-store
    )
fi

# Allow software rendering when explicitly requested.
if [ "${KIBAOS_SOFTWARE_RENDERING:-0}" = "1" ]; then
    KIBAOS_ALLOW_GPU_COMPOSITING_FALLBACK=1
    export KIBAOS_ALLOW_GPU_COMPOSITING_FALLBACK

    FLAGS+=(--disable-gpu-compositing)

    SOFTWARE_FLAGS=()

    for flag in "${FLAGS[@]}"; do
        [ "${flag}" = "--enable-wayland-server" ] || SOFTWARE_FLAGS+=("${flag}")
    done

    FLAGS=("${SOFTWARE_FLAGS[@]}")
fi

if [ "${#KIBAOS_ENABLED_FEATURES[@]}" -gt 0 ]; then
    FLAGS+=(--enable-features="$(kibaos_join_csv "${KIBAOS_ENABLED_FEATURES[@]}")")
fi

if [ "${#KIBAOS_DISABLED_FEATURES[@]}" -gt 0 ]; then
    FLAGS+=(--disable-features="$(kibaos_join_csv "${KIBAOS_DISABLED_FEATURES[@]}")")
fi

if [ -n "${KIBAOS_CHROME_EXTRA_FLAGS}" ]; then
    read -r -a EXTRA_FLAGS <<<"${KIBAOS_CHROME_EXTRA_FLAGS}"
    FLAGS+=("${EXTRA_FLAGS[@]}")
fi

# Forward any extra CLI arguments.
FLAGS+=("$@")

exec "${CHROME}" "${FLAGS[@]}"
