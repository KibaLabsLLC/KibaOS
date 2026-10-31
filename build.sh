#!/bin/bash
set -ex

KIBA_ARCH="x86_64"
for _a in "$@"; do
  case "${_a}" in
    --mobile) KIBA_ARCH="mobile" ;;
  esac
done
[ "${KIBA_ARCH}" = "x86_64" ] && [ "${KIBA_MOBILE:-0}" = "1" ] && KIBA_ARCH="mobile"
export KIBA_ARCH
echo "=== KibaOS build target: ${KIBA_ARCH} ==="

sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf

grep -q '^alpm:' "${AIROOTFS}/etc/passwd" 2>/dev/null || \
  echo 'alpm:x:951:951::/var/cache/pacman/pkg:/usr/bin/nologin' >> "${AIROOTFS}/etc/passwd"
grep -q '^alpm:' "${AIROOTFS}/etc/group" 2>/dev/null || \
  echo 'alpm:x:951:' >> "${AIROOTFS}/etc/group"
grep -q '^alpm:' "${AIROOTFS}/etc/shadow" 2>/dev/null || \
  echo 'alpm:!*:19000::::::' >> "${AIROOTFS}/etc/shadow"
mkdir -p "${AIROOTFS}/var/cache/pacman/pkg"
chmod 755 "${AIROOTFS}/var/cache/pacman" "${AIROOTFS}/var/cache/pacman/pkg"

pacman-key --init
pacman-key --populate archlinux
pacman -Syy --noconfirm
pacman -Su  --noconfirm
if [ "${KIBA_ARCH}" = "mobile" ]; then
  pacman -S --noconfirm --needed \
    base-devel git arch-install-scripts openssl curl jq e2fsprogs zip unzip imagemagick
else
  pacman -S --noconfirm --needed \
    base-devel git squashfs-tools libisoburn mtools dosfstools \
    cmake ninja meson \
    grub syslinux \
    arch-install-scripts \
    openssl curl imagemagick jq \
    python-docutils
fi

build_kibaos_mobile() {
  local _root="/w/mobile-rootfs"
  local _out="/w/out"
  rm -rf "${_root}"
  mkdir -p "${_root}" "${_out}"

  pacman-key --init
  pacman-key --populate archlinux
  pacman-key --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6 \
    --keyserver keyserver.ubuntu.com
  pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6

  cat > /etc/pacman.d/mobile-mirrorlist << 'MIRRORLIST'
Server = http://mirror.archlinuxarm.org/aarch64/$repo
MIRRORLIST

  cat > /tmp/mobile-pacman.conf << 'PACMANCONF'
[options]
Architecture = aarch64
CheckSpace
ParallelDownloads = 10
SigLevel = Required DatabaseOptional

[core]
Include = /etc/pacman.d/mobile-mirrorlist
[extra]
Include = /etc/pacman.d/mobile-mirrorlist
[alarm]
Include = /etc/pacman.d/mobile-mirrorlist
PACMANCONF

  mkdir -p "${_root}/var/lib/pacman"

  pacstrap -C /tmp/mobile-pacman.conf -c -G "${_root}" \
    base sudo networkmanager \
     labwc-is-not-used-placeholder 2>/dev/null || true

  pacstrap -C /tmp/mobile-pacman.conf -c -G "${_root}" \
    base sudo networkmanager dbus polkit \
     budgie-control-center \
    phoc squeekboard waybar wtype \
    bluez bluez-utils upower \
    wireplumber pipewire pipewire-pulse \
    mesa vulkan-icd-loader \
    openssh git base-devel \
    ell gnome-calls chatty

  awk '
    /^\[aur\]/ { skip=1; next }
    skip && /^\[/ { skip=0 }
    !skip { print }
  ' "${_root}/etc/pacman.conf" > "${_root}/etc/pacman.conf.new" \
    && mv "${_root}/etc/pacman.conf.new" "${_root}/etc/pacman.conf"

  sed -i 's/^CheckSpace/#CheckSpace/' "${_root}/etc/pacman.conf"

  arch-chroot "${_root}" pacman-key --init
  arch-chroot "${_root}" pacman-key --populate archlinux
  arch-chroot "${_root}" pacman-key --recv-keys \
    68B3537F39A313B3E574D06777193F152BDBE6A6 \
    --keyserver keyserver.ubuntu.com
  arch-chroot "${_root}" pacman-key --lsign-key \
    68B3537F39A313B3E574D06777193F152BDBE6A6

  arch-chroot "${_root}" pacman -Syy --noconfirm

  arch-chroot "${_root}" useradd -m -G wheel builder || true
  echo 'builder ALL=(ALL) NOPASSWD: ALL' > "${_root}/etc/sudoers.d/builder"

  _aur_build() {
    local _pkg="$1"
    local _extra_args="${2:-}"
    arch-chroot "${_root}" bash -c "
      su - builder -c '
        cd /tmp &&
        rm -rf ${_pkg} &&
        git clone --depth 1 https://aur.archlinux.org/${_pkg}.git &&
        cd ${_pkg} &&
        makepkg -si --noconfirm --needed ${_extra_args}
      '
    "
  }

  _aur_build_retry() {
    local _pkg="$1"
    local _extra_args="${2:-}"
    local _tries
    for _tries in 1 2 3 4 5; do
      if _aur_build "${_pkg}" "${_extra_args}"; then
        return 0
      fi
      if [ "${_tries}" -lt 5 ]; then
        echo "!! ${_pkg} AUR build attempt ${_tries}/5 failed -- retrying in 10s (this is usually a transient AUR git/TLS blip, not a real package error)..." >&2
        sleep 10
      fi
    done
    return 1
  }

  _aur_build_retry ofono || {
    echo "ERROR: ofono AUR build failed -- refusing to ship a mobile rootfs with no working telephony stack. Check the makepkg log above." >&2
    rm -f "${_root}/etc/sudoers.d/builder"
    arch-chroot "${_root}" userdel -r builder || true
    exit 1
  }

  for _pkg in wlrctl; do
    _aur_build_retry "${_pkg}" || echo "!! ${_pkg} AUR build failed -- check the log above, continuing" >&2
  done
  rm -f "${_root}/etc/sudoers.d/builder"
  arch-chroot "${_root}" userdel -r builder || true

  if ! arch-chroot "${_root}" pacman -S --noconfirm --needed sddm; then
    echo "ERROR: sddm not available -- refusing to build a mobile rootfs with no lock/login screen. Check the ALARM [extra] repo/mirror." >&2
    exit 1
  fi
  arch-chroot "${_root}" systemctl enable sddm

  arch-chroot "${_root}" bash -c "
    grep -q '^liveuser:' /etc/passwd || \
      echo 'liveuser:x:1000:1000:KibaOS Live User (Password is live):/home/liveuser:/bin/bash' >> /etc/passwd
    grep -q '^liveuser:' /etc/group || \
      echo 'liveuser:x:1000:liveuser' >> /etc/group
    mkdir -p /home/liveuser
    chown 1000:1000 /home/liveuser
  "

  KIBA_WALLPAPER_URL="https://github.com/KibaLabsLLC/KibaOS/blob/main/assets/wallpapers/2C6001BA-2AB5-4B2D-A75D-6224E92E20AC.png?raw=true"
  KIBA_BOOT_SPLASH_URL="https://github.com/WolfTech-Innovations/Kiba/blob/main/assets/splash/splash.png?raw=true"
  mkdir -p "${_root}/usr/share/kibaos"

  curl -fL --retry 5 --retry-delay 3 -o "${_root}/usr/share/kibaos/wallpaper.jpg" \
    "${KIBA_WALLPAPER_URL}" || \
    magick -size 1080x2400 gradient:"#003f5c-#0099cc" "${_root}/usr/share/kibaos/wallpaper.jpg"

  curl -fL --retry 5 --retry-delay 3 -o /tmp/kiba-boot-splash-raw.png "${KIBA_BOOT_SPLASH_URL}" || true
  if [ -f /tmp/kiba-boot-splash-raw.png ] && file /tmp/kiba-boot-splash-raw.png | grep -qi image; then
    magick /tmp/kiba-boot-splash-raw.png -filter Lanczos -resize 256x256 "${_root}/usr/share/kibaos/logo-256.png"
    rm -f /tmp/kiba-boot-splash-raw.png
  else
    magick -size 256x256 xc:none \
      -fill '#0099cc' -draw 'circle 128,128 128,1' \
      -fill white -pointsize 128 -gravity Center -annotate 0 'K' \
      "${_root}/usr/share/kibaos/logo-256.png"
  fi

  SDDM_THEME_DIR="${_root}/usr/share/sddm/themes/kibaos"
  mkdir -p "${SDDM_THEME_DIR}"
  cp "${_root}/usr/share/kibaos/wallpaper.jpg" "${SDDM_THEME_DIR}/background.png" 2>/dev/null || true
  cp "${_root}/usr/share/kibaos/logo-256.png"  "${SDDM_THEME_DIR}/logo.png"       2>/dev/null || true

  cat > "${SDDM_THEME_DIR}/metadata.desktop" << 'SDDMMETA'
[SddmGreeterTheme]
Name=KibaOS
Description=KibaOS frosted-glass greeter
Author=Kiba Labs, LLC
Copyright=2026, Kiba Labs, LLC
License=GPLv3
Type=sddm-theme
Version=1.0
Website=https://github.com/WolfTech-Innovations/Kiba
MainScript=Main.qml
Font=Nunito
QuickVersion=6
SDDMMETA

  cat > "${SDDM_THEME_DIR}/Main.qml" << 'SDDMQML'
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Single shared greeter for both the desktop ISO and KibaOS Mobile --
// this exact file is written byte-for-byte into both images (see the
// desktop copy inside install_archiso's customize_airootfs.sh heredoc).
// Rather than branching into two separate QML files, the layout adapts
// itself at runtime off Screen.width, so a genuinely single theme
// covers a 1920x1080 desktop panel and a ~1080x2400 phone panel without
// drifting out of sync on brand/behavior over time.
Rectangle {
    id: root
    width: Screen.width  > 0 ? Screen.width  : 1920
    height: Screen.height > 0 ? Screen.height : 1080
    color: "#0d1b2a"
    focus: true

    // phoc's own config scales the DSI panel output 2x at the Wayland
    // protocol level (see phoc.ini's [output:DSI-1] scale=2) -- Qt's
    // Wayland QPA backend reads that wl_output scale itself and already
    // renders this file's logical pixels at the right physical density,
    // so nothing extra is needed here for HiDPI; this width/height check
    // is purely about aspect ratio/orientation, not pixel density.
    readonly property bool isPhone: width < 700
    readonly property int touchH: isPhone ? 56 : 44
    readonly property int fieldR: isPhone ? 18 : 14

    property int sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0

    // ── Background wallpaper, darkened so the glass card pops ──────────────
    Image {
        anchors.fill: parent
        source: "background.png"
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
    Rectangle {
        anchors.fill: parent
        color: "#0d1b2a"
        opacity: 0.42
    }

    // ── Clock ────────────────────────────────────────────────────────────
    // Desktop: small pill, top-right, matches the KibaOS panel style.
    // Phone: big lockscreen-style clock, top-center, clear of any status
    // bar / camera-cutout safe area -- Android/iOS lockscreen convention,
    // and it doubles as a landmark while your thumb finds the card below.
    Column {
        id: clockCol
        anchors {
            top: parent.top
            topMargin: isPhone ? 64 : 28
        }
        anchors.horizontalCenter: isPhone ? parent.horizontalCenter : undefined
        anchors.right: isPhone ? undefined : parent.right
        anchors.rightMargin: isPhone ? 0 : 28
        spacing: isPhone ? 4 : 0
        Text {
            id: clockTime
            text: Qt.formatTime(new Date(), "h:mm AP")
            color: "#ffffff"
            font.pixelSize: isPhone ? 56 : 18
            font.weight: Font.Medium
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: Qt.formatDate(new Date(), "ddd, MMM d")
            color: "#aebccd"
            font.pixelSize: isPhone ? 16 : 11
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Timer { interval: 1000; running: true; repeat: true; onTriggered: clockTime.text = Qt.formatTime(new Date(), "h:mm AP") }
    }

    // ── Central frosted-glass login card ────────────────────────────────────
    // Desktop: fixed 360px, dead-centered, unchanged from before.
    // Phone: full-width (minus margins), anchored in the lower half
    // rather than dead-center -- that's within comfortable one-handed
    // thumb reach, and critically it leaves the *upper* half of the
    // screen clear for squeekboard to pop up underneath without ever
    // covering the password field it's currently focused on.
    Rectangle {
        id: card
        anchors {
            horizontalCenter: isPhone ? parent.horizontalCenter : undefined
            centerIn: isPhone ? undefined : parent
            bottom: isPhone ? parent.bottom : undefined
            bottomMargin: isPhone ? 96 : 0
        }
        width: isPhone ? parent.width - 48 : 360
        height: cardCol.implicitHeight + (isPhone ? 40 : 56)
        radius: isPhone ? 32 : 26
        color: "#101828"
        opacity: 0.001
        // emulated glass: just a solid translucent fill, no real blur.
        // KWin's own Blur effect is real and available in the actual
        // session, but the SDDM greeter renders on its own standalone
        // Qt Quick surface before any session (or its compositor) is
        // even running — see KWIN CONFIG notes for the full story on
        // why this greeter can't just borrow it — so this fake-glass
        // approach is doing all the work here now, not just backstopping
        // a spot where real blur wouldn't reach anyway.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Qt.rgba(0.063, 0.094, 0.157, 0.72)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
        }

        ColumnLayout {
            id: cardCol
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: isPhone ? 24 : 28 }
            spacing: isPhone ? 16 : 14

            Image {
                Layout.alignment: Qt.AlignHCenter
                source: "logo.png"
                width: isPhone ? 56 : 64; height: isPhone ? 56 : 64
                fillMode: Image.PreserveAspectFit
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: userModel.count > 0 ? userModel.data(userModel.index(userList.currentIndex, 0), 257) : "User"
                color: "#e8eef5"; font.pixelSize: isPhone ? 19 : 17; font.weight: Font.Medium
            }

            ListView {
                id: userList
                Layout.fillWidth: true
                height: 0; visible: false  // names shown via combo below instead
                model: userModel
                currentIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
            }

            ComboBox {
                id: userBox
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                model: userModel
                textRole: "name"
                currentIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
                font.pixelSize: isPhone ? 16 : 13
                background: Rectangle { radius: fieldR; color: Qt.rgba(1,1,1,0.07); border.width: 1; border.color: Qt.rgba(1,1,1,0.10) }
                contentItem: Text { text: userBox.displayText; color: "#e8eef5"; font: userBox.font; padding: 10; verticalAlignment: Text.AlignVCenter }
            }

            TextField {
                id: passwordField
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                placeholderText: "Password"
                echoMode: TextInput.Password
                color: "#e8eef5"
                font.pixelSize: isPhone ? 16 : 13
                placeholderTextColor: "#8a99ad"
                background: Rectangle { radius: fieldR; color: Qt.rgba(1,1,1,0.07); border.width: 1; border.color: Qt.rgba(1,1,1,0.10) }
                onAccepted: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
                Keys.onReturnPressed: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
            }

            Button {
                id: loginButton
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                text: "Sign In"
                onClicked: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
                background: Rectangle { radius: fieldR; color: "#0099cc" }
                contentItem: Text { text: loginButton.text; color: "#ffffff"; font.pixelSize: isPhone ? 16 : 13; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
            }

            // Session picker: only worth showing where there's actually
            // more than one to pick from. Desktop offers Budgie/etc
            // session choices; the phone image ships exactly one
            // (kibaos-mobile, Exec=phoc) so this is dead weight there --
            // one less thing to accidentally fat-finger on a small card.
            ComboBox {
                Layout.fillWidth: true
                Layout.preferredHeight: isPhone ? 0 : undefined
                visible: !isPhone
                model: sessionModel
                textRole: "name"
                currentIndex: root.sessionIndex
                onActivated: root.sessionIndex = currentIndex
                background: Rectangle { radius: fieldR; color: "transparent" }
                contentItem: Text { text: parent.displayText; color: "#aebccd"; font.pixelSize: 11; padding: 6; horizontalAlignment: Text.AlignHCenter }
            }
        }
    }

    // ── Power row ────────────────────────────────────────────────────────
    // Desktop: small 44px pills, bottom-right, unchanged.
    // Phone: bigger 56px targets (comfortable thumb-tap size), moved to
    // top-right instead -- bottom-right on a phone sits right where the
    // login card's bottom edge and any on-screen-keyboard region already
    // are, so it's both more reachable and less likely to be covered.
    Row {
        anchors {
            top: isPhone ? parent.top : undefined
            bottom: isPhone ? undefined : parent.bottom
            right: parent.right
            margins: isPhone ? 24 : 28
        }
        spacing: isPhone ? 14 : 10
        Repeater {
            model: [
                { label: "⏻", visible: sddm.canPowerOff, action: function(){ sddm.powerOff() } },
                { label: "⟲", visible: sddm.canReboot,   action: function(){ sddm.reboot()   } }
            ]
            delegate: Rectangle {
                visible: modelData.visible
                width: touchH; height: touchH; radius: fieldR
                color: "#1c2433"; opacity: 0.78
                Text { anchors.centerIn: parent; text: modelData.label; color: "#e8eef5"; font.pixelSize: isPhone ? 22 : 18 }
                MouseArea { anchors.fill: parent; onClicked: modelData.action() }
            }
        }
    }

    Connections {
        target: sddm
        function onLoginFailed() { passwordField.text = ""; passwordField.placeholderText = "Incorrect password"; }
    }

    Component.onCompleted: passwordField.forceActiveFocus()
}
SDDMQML

  mkdir -p "${_root}/usr/share/wayland-sessions"
  cat > "${_root}/usr/share/wayland-sessions/kibaos-mobile.desktop" << 'MOBILESESSION'
[Desktop Entry]
Name=KibaOS Mobile
Comment=Budgie panel/raven on phoc
Exec=phoc
Type=Application
DesktopNames=Budgie
MOBILESESSION

  mkdir -p "${_root}/etc/sddm.conf.d"
  cat > "${_root}/etc/sddm.conf.d/kibaos-mobile.conf" << 'SDDMMOBILECONF'
[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=phoc

[Theme]
Current=kibaos

[Autologin]
User=liveuser
Session=kibaos-mobile
SDDMMOBILECONF

  arch-chroot "${_root}" bash -c "
    mkdir -p /var/lib/sddm
    chown sddm:sddm /var/lib/sddm 2>/dev/null || true
    chmod 750 /var/lib/sddm
  "

  install -d -m 755 -o 1000 -g 1000 "${_root}/home/liveuser/.config/dconf" 2>/dev/null || true
  cat > "${_root}/etc/resolv.conf" << 'RESOLVCONF'
nameserver 1.1.1.1
nameserver 1.0.0.1
RESOLVCONF

  mkdir -p "${_root}/etc/phoc"
  cat > "${_root}/etc/phoc/phoc.ini" << 'PHOCINI'
[core]
xwayland=true

[output:DSI-1]
scale=2
PHOCINI

  mkdir -p "${_root}/etc/xdg/waybar"
  cat > "${_root}/etc/xdg/waybar/config" << 'WAYBARCONFIG'
{
    "layer": "top",
    "position": "bottom",
    "height": 76,
    "margin-bottom": 0,
    "modules-left": ["custom/back"],
    "modules-center": ["custom/home"],
    "modules-right": ["custom/recents"],

    "custom/back": {
        "format": "←",
        "tooltip": false,
        "on-click": "wtype -k Escape"
    },
    "custom/home": {
        "format": "⌂",
        "tooltip": false,
        "on-click": "budgie-panel --toggle-appswitch 2>/dev/null || pkill -SIGUSR1 budgie-panel"
    },
    "custom/recents": {
        "format": "▦",
        "tooltip": false,
        "on-click": "kibaos-mobile-recents"
    }
}
WAYBARCONFIG

  cat > "${_root}/etc/xdg/waybar/style.css" << 'WAYBARCSS'
/* KibaOS Mobile nav bar -- same accent/timing tokens as oobe.css, just
 * applied to the bar that's actually on-screen every day after setup.
 * Sized noticeably above Material's 48dp minimum touch target -- this
 * bar gets tapped constantly, one-handed, often without looking, so
 * bigger/simpler beats dense every time. Plain classic Unicode glyphs
 * (← ⌂ ▦) instead of an icon font dependency -- render everywhere with
 * zero extra packages, and read clearly even at a glance. */
* {
    font-family: "Nunito", sans-serif;
    border: none;
    border-radius: 0;
    min-height: 0;
}

window#waybar {
    background: rgba(18, 22, 29, 0.92);
    border-top: 1px solid rgba(255, 255, 255, 0.08);
}

#custom-back, #custom-home, #custom-recents {
    color: #e2e8f0;
    font-size: 26px;
    min-width: 76px;
    min-height: 56px;
    margin: 10px 10px;
    border-radius: 999px;
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
                transform 90ms cubic-bezier(0.22, 1, 0.36, 1);
}
#custom-back:hover, #custom-home:hover, #custom-recents:hover {
    background: rgba(255, 255, 255, 0.08);
}
#custom-back:active, #custom-home:active, #custom-recents:active {
    background: rgba(0, 113, 227, 0.35);
    transform: scale(0.90);
}

/* Home gets the accent treatment -- it's the "you are always one tap from
 * a known place" affordance, same role the OOBE's primary button plays:
 * exactly one clearly-weighted action, unmistakable at a glance. */
#custom-home {
    color: #ffffff;
    background: #0071e3;
    min-width: 84px;
}
#custom-home:hover  { background: #0077ed; }
#custom-home:active { background: #0068d6; }
WAYBARCSS

  mkdir -p "${_root}/etc/xdg/waybar"
  cat > "${_root}/etc/xdg/waybar/statusbar-config" << 'STATUSBARCONFIG'
{
    "layer": "top",
    "position": "top",
    "height": 34,
    "spacing": 2,
    "modules-left": ["clock"],
    "modules-center": [],
    "modules-right": ["custom/cellular", "network", "bluetooth", "battery"],

    "clock": {
        "format": "{:%I:%M %p}",
        "tooltip-format": "{:%A, %B %d}"
    },

    "custom/cellular": {
        "exec": "/usr/local/bin/kibaos-mobile-cellular",
        "interval": 8,
        "return-type": "json",
        "tooltip": true
    },

    "network": {
        "format-wifi": "{icon}",
        "format-disconnected": "",
        "format-icons": ["▁", "▂", "▄", "▆", "█"],
        "tooltip-format-wifi": "{essid} · {signalStrength}%",
        "on-click": "budgie-control-center wifi 2>/dev/null || true"
    },

    "bluetooth": {
        "format": "◇",
        "format-connected": "◆",
        "format-disabled": "",
        "format-off": "",
        "tooltip-format": "{controller_alias} ({controller_address})",
        "tooltip-format-connected": "{device_alias}",
        "on-click": "budgie-control-center bluetooth 2>/dev/null || true"
    },

    "battery": {
        "format": "{icon} {capacity}%",
        "format-charging": "{icon} {capacity}% ↑",
        "format-icons": ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"],
        "states": {
            "warning": 20,
            "critical": 10
        }
    }
}
STATUSBARCONFIG

  cat > "${_root}/etc/xdg/waybar/statusbar-style.css" << 'STATUSBARCSS'
/* KibaOS Mobile status bar -- same tokens as the nav bar/oobe.css, sized
 * for a compact always-on strip instead of a tap target: small text,
 * tight padding, no hover/active states (nothing here is a button except
 * the network/bluetooth quick-launch clicks, and those don't need a
 * press-state animation on a strip this thin). */
* {
    font-family: "Nunito", sans-serif;
    border: none;
    border-radius: 0;
    min-height: 0;
}

window#waybar {
    background: rgba(18, 22, 29, 0.92);
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}

#clock {
    color: #f1f5f9;
    font-size: 13px;
    font-weight: 700;
    padding: 0 12px;
}

#custom-cellular, #network, #bluetooth, #battery {
    color: #e2e8f0;
    font-size: 13px;
    font-weight: 700;
    padding: 0 6px;
}

#bluetooth { font-size: 15px; }

/* Battery warning/critical tint -- same red used for oobe.css's
 * .oobe-error, same amber Material typically reserves for a low-battery
 * state, so a glance at the bar reads consistently with the rest of the
 * UI's color language. */
#battery.warning  { color: #f59e0b; }
#battery.critical { color: #f87171; }
STATUSBARCSS

  cat > "${_root}/usr/local/bin/kibaos-mobile-cellular" << 'CELLULARSCRIPT'
#!/bin/bash
set -u

_empty() { echo '{"text":"","tooltip":"No SIM/modem detected","class":"none"}'; }

command -v gdbus >/dev/null 2>&1 || { _empty; exit 0; }

_modem_path="$(
  gdbus call --system --dest org.ofono --object-path / \
    --method org.ofono.Manager.GetModems 2>/dev/null \
    | grep -oP "(?<=objpath ')[^']+" | head -n1
)"
[ -z "${_modem_path}" ] && { _empty; exit 0; }

_netreg="$(
  gdbus call --system --dest org.ofono --object-path "${_modem_path}" \
    --method org.ofono.NetworkRegistration.GetProperties 2>/dev/null
)"
[ -z "${_netreg}" ] && { _empty; exit 0; }

_status="$(echo "${_netreg}"   | grep -oP "'Status': <'\K[^']+")"
_strength="$(echo "${_netreg}" | grep -oP "'Strength': <(uint16 |byte )?\K[0-9]+" | head -n1)"
_tech="$(echo "${_netreg}"     | grep -oP "'Technology': <'\K[^']+")"
_carrier="$(echo "${_netreg}"  | grep -oP "'Name': <'\K[^']+")"

if [ "${_status}" != "registered" ] && [ "${_status}" != "roaming" ]; then
  echo "{\"text\":\"✕\",\"tooltip\":\"No service\",\"class\":\"none\"}"
  exit 0
fi

_strength="${_strength:-0}"
if   [ "${_strength}" -ge 80 ]; then _bar="█"
elif [ "${_strength}" -ge 60 ]; then _bar="▆"
elif [ "${_strength}" -ge 40 ]; then _bar="▄"
elif [ "${_strength}" -ge 20 ]; then _bar="▂"
else                                 _bar="▁"
fi

_tech_label="$(echo "${_tech}" | tr '[:lower:]' '[:upper:]')"
_roam_suffix=""
[ "${_status}" = "roaming" ] && _roam_suffix=" (roaming)"

echo "{\"text\":\"${_bar} ${_tech_label}\",\"tooltip\":\"${_carrier}${_roam_suffix} · ${_strength}%\",\"class\":\"connected\"}"
CELLULARSCRIPT
  chmod +x "${_root}/usr/local/bin/kibaos-mobile-cellular"

  cat > "${_root}/usr/local/bin/kibaos-mobile-recents" << 'RECENTSSCRIPT'
#!/bin/bash
if command -v wlrctl >/dev/null 2>&1; then
  wlrctl toplevel list
else
  echo "kibaos-mobile-recents: wlrctl not installed, no toplevel list available" >&2
fi
RECENTSSCRIPT
  chmod +x "${_root}/usr/local/bin/kibaos-mobile-recents"

  cat > "${_root}/etc/xdg/autostart/kibaos-mobile-navbar.desktop" << 'NAVBARAUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Navigation Bar
Exec=waybar -c /etc/xdg/waybar/config -s /etc/xdg/waybar/style.css
X-GNOME-Autostart-enabled=true
NAVBARAUTOSTART

  cat > "${_root}/etc/xdg/autostart/kibaos-mobile-statusbar.desktop" << 'STATUSBARAUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Status Bar
Exec=waybar -c /etc/xdg/waybar/statusbar-config -s /etc/xdg/waybar/statusbar-style.css
X-GNOME-Autostart-enabled=true
STATUSBARAUTOSTART

  arch-chroot "${_root}" systemctl enable bluetooth upower || true

  cat > "${_root}/etc/xdg/autostart/kibaos-mobile-shell.desktop" << 'AUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Shell
Exec=budgie-panel
X-GNOME-Autostart-enabled=true
AUTOSTART

  pacstrap -C /tmp/mobile-pacman.conf -c -G "${_root}" \
    gtk4 libadwaita vala meson ninja glib2 networkmanager

  mkdir -p "${_root}/root/kibaos-mobile-oobe/src"

  cat > "${_root}/root/kibaos-mobile-oobe/meson.build" << 'MESONBUILD'
project('kibaos-mobile-oobe', 'vala', 'c')
gtk_dep = dependency('gtk4')
adw_dep = dependency('libadwaita-1')
gio_dep = dependency('gio-2.0')
executable('kibaos-mobile-oobe', 'src/main.vala',
  dependencies: [gtk_dep, adw_dep, gio_dep],
  install: true)
MESONBUILD

  mkdir -p "${_root}/usr/share/kibaos-mobile-oobe"
  cat > "${_root}/usr/share/kibaos-mobile-oobe/oobe.css" << 'MOBILEOOBECSS'
/* ═══════════════════════════════════════════════════════════════════════
 * KibaOS Mobile OOBE — desktop oobe.css tokens + Material 3 shape/elevation.
 * Timing: settle cubic-bezier(0.22,1,0.36,1) / spring cubic-bezier(0.34,1.56,0.64,1)
 * ═══════════════════════════════════════════════════════════════════════ */

window.kibaos-oobe-window { background: transparent; }

.oobe-background {
    background: #ffffff;
    transition: background 260ms cubic-bezier(0.22, 1, 0.36, 1);
}
window.dark .oobe-background { background: #12161d; }

/* ── Top app bar: brand + corner toggles, Material top-app-bar height ── */
.oobe-topbar { min-height: 56px; padding: 8px 14px; }
.oobe-brand {
    font-size: 14px;
    font-weight: 700;
    letter-spacing: 0.4px;
    color: rgba(15,23,42,0.80);
}
window.dark .oobe-brand { color: rgba(255,255,255,0.75); }

.oobe-corner-button {
    background:    rgba(15,23,42,0.05);
    color:         #334155;
    border:        1px solid rgba(15,23,42,0.10);
    border-radius: 999px;
    min-width:     48px;
    min-height:    48px;
    padding:       8px;
    font-size:     15px;
    font-weight:   650;
    transition:
        background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
        transform         120ms cubic-bezier(0.34, 1.56, 0.64, 1);
}
.oobe-corner-button:hover  { background: rgba(15,23,42,0.09); }
.oobe-corner-button:active { transform: scale(0.92); transition-duration: 70ms; }
window.dark .oobe-corner-button {
    background: rgba(30,41,59,0.65);
    color:      #e2e8f0;
    border-color: rgba(255,255,255,0.12);
}
window.dark .oobe-corner-button:hover { background: rgba(51,65,85,0.85); }

/* ── Top linear progress (Material stepper / Android SetupWizard style) ── */
.oobe-linear-progress { min-height: 4px; }
.oobe-linear-progress trough {
    background:    rgba(15,23,42,0.08);
    border-radius: 999px;
    min-height:    4px;
}
.oobe-linear-progress progress {
    background:    linear-gradient(90deg, #0071e3, #409cff);
    border-radius: 999px;
    transition:    all 420ms cubic-bezier(0.22, 1, 0.36, 1);
}
window.dark .oobe-linear-progress trough { background: rgba(255,255,255,0.10); }

/* ── Step dots (secondary indicator, sits under the linear track) ──── */
.oobe-step-dot {
    min-width: 6px; min-height: 6px;
    border-radius: 999px;
    background: rgba(0,0,0,0.15);
    transition: all 300ms cubic-bezier(0.22, 1, 0.36, 1);
}
.oobe-step-dot-active { min-width: 18px; background: #0071e3; }
window.dark .oobe-step-dot { background: rgba(255,255,255,0.18); }
window.dark .oobe-step-dot-active { background: #409cff; }
.oobe-step-label {
    font-size: 12px; font-weight: 600;
    color: rgba(0,0,0,0.38); letter-spacing: 0.2px;
}
window.dark .oobe-step-label { color: rgba(255,255,255,0.40); }

/* ── Card: Material "extra-large" 28px shape scale, real elevation ──
 * Phones don't get the desktop's borderless full-bleed treatment --
 * there's no cursor/hover state to carry hierarchy on touch, so the
 * card boundary + soft elevation shadow is doing that work instead. */
.oobe-card {
    background:    #ffffff;
    border:        1px solid rgba(15,23,42,0.06);
    border-radius: 28px;
    box-shadow:    0 1px 2px rgba(15,23,42,0.04), 0 8px 24px rgba(15,23,42,0.08);
    animation: card-in 460ms cubic-bezier(0.22, 1, 0.36, 1) both;
}
window.dark .oobe-card {
    background:    #1a2029;
    border-color:  rgba(255,255,255,0.06);
    box-shadow:    0 1px 2px rgba(0,0,0,0.3), 0 8px 24px rgba(0,0,0,0.35);
}
@keyframes card-in {
    from { opacity: 0; transform: translateY(18px) scale(0.98); }
    to   { opacity: 1; transform: translateY(0) scale(1); }
}
.oobe-inner { padding: 20px 20px 16px; }

/* ── Page icon: one big, friendly, unmistakable symbolic icon per
 *    screen. A single large icon reads instantly without reading a
 *    word of text -- the whole point of "simple enough for anyone",
 *    so every page gets one before the title, never buried in a
 *    paragraph. Rendered as a themed Gtk.Image (pixel_size set in
 *    code), deliberately not an emoji glyph, so it renders consistently
 *    regardless of what emoji coverage the device's font stack has. ── */
.oobe-page-icon {
    color: #0071e3;
    margin-bottom: 4px;
    animation: pop-in 480ms cubic-bezier(0.34, 1.56, 0.64, 1) both;
}
window.dark .oobe-page-icon { color: #4d9fff; }

/* ── Typography -- sized for a hand held at arm's length, not a desk
 *    monitor: bigger everything, shorter lines, nothing squints. ───── */
.oobe-welcome-greeting {
    font-size: 36px; font-weight: 750; color: #1d1d1f;
    letter-spacing: -0.3px; margin-top: 4px; line-height: 1.15;
    animation: fade-up 460ms cubic-bezier(0.22, 1, 0.36, 1) both;
}
window.dark .oobe-welcome-greeting { color: #f1f5f9; }
.oobe-title {
    font-size: 28px; font-weight: 750; color: #0f172a;
    letter-spacing: -0.3px; line-height: 1.2; margin-bottom: 4px;
    animation: fade-up 380ms cubic-bezier(0.22, 1, 0.36, 1) 60ms both;
}
.oobe-subtitle {
    font-size: 16px; color: #64748b; line-height: 1.5;
    animation: fade-up 380ms cubic-bezier(0.22, 1, 0.36, 1) 100ms both;
}
@keyframes fade-up { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
window.dark .oobe-title    { color: #f1f5f9; }
window.dark .oobe-subtitle { color: #94a3b8; }
.oobe-error {
    font-size: 15px; color: #dc2626; line-height: 1.5;
    animation: fade-up 220ms cubic-bezier(0.22, 1, 0.36, 1) both;
}
window.dark .oobe-error { color: #f87171; }

/* ── Skip: a plain text link, not a bordered button -- there should only
 *    ever be ONE strongly-weighted action on screen (the big accent
 *    button). A second bordered button competes with it visually and
 *    is exactly the kind of "which one do I press" ambiguity a
 *    dog-simple flow can't have. ─────────────────────────────────────── */
.oobe-skip-link {
    background: transparent;
    color: #94a3b8;
    border: none;
    font-size: 15px;
    font-weight: 600;
    padding: 12px;
    min-height: 44px;
}
.oobe-skip-link:hover { color: #64748b; }
window.dark .oobe-skip-link { color: #64748b; }
window.dark .oobe-skip-link:hover { color: #94a3b8; }

/* ── Language rows: code badge + name, one tap, no dropdown. A dropdown
 *    needs opening then a second tap to choose -- two motions where one
 *    obvious list of big rows only needs one, same reasoning as the
 *    Wi-Fi list already uses tap-to-select rows instead of a picker.
 *    Plain-text code badge (EN-US, ES, ...) rather than a flag emoji --
 *    see build_language_page for why. Class name kept as oobe-lang-flag
 *    to avoid churning every reference below; it's just a badge now. ── */
.oobe-lang-flag { font-size: 15px; font-weight: 700; min-width: 40px; color: #0071e3; }
window.dark .oobe-lang-flag { color: #4d9fff; }
.oobe-lang-name { font-size: 17px; font-weight: 600; }
window.dark .oobe-lang-name { color: #f1f5f9; }

/* ── Wi-Fi list: Material elevated list items, ripple-ish press state ── */
.oobe-signal-glyph {
    font-family: monospace; font-size: 15px; font-weight: 700;
    color: #0071e3; min-width: 32px;
}
window.dark .oobe-signal-glyph { color: #409cff; }

.oobe-list row, listview > row {
    background:    #f8fafc;
    border:        1px solid rgba(0,0,0,0.06);
    border-radius: 20px;
    margin:        6px 0;
    padding:       18px 18px;
    color:         #1e293b;
    transition:
        background-color 160ms cubic-bezier(0.22, 1, 0.36, 1),
        border-color     160ms cubic-bezier(0.22, 1, 0.36, 1),
        box-shadow       160ms cubic-bezier(0.22, 1, 0.36, 1),
        transform         90ms cubic-bezier(0.22, 1, 0.36, 1);
    animation: fade-up 260ms cubic-bezier(0.22, 1, 0.36, 1) both;
}
.oobe-list row:hover    { background: #f0f9ff; border-color: rgba(0,113,227,0.25); }
.oobe-list row:active   { transform: scale(0.98); transition-duration: 60ms; }
.oobe-list row:selected {
    background:  rgba(0,113,227,0.10);
    border-color: rgba(0,113,227,0.55);
    box-shadow:  0 0 0 3px rgba(0,113,227,0.14);
}
window.dark .oobe-list row, window.dark listview > row {
    background: #212836; border-color: rgba(255,255,255,0.07); color: #e2e8f0;
}
window.dark .oobe-list row:hover    { background: rgba(0,113,227,0.16); border-color: rgba(0,113,227,0.4); }
window.dark .oobe-list row:selected { background: rgba(0,113,227,0.22); border-color: rgba(0,113,227,0.6); }

/* ── Done check: pop-in, spring easing. Rendered as a themed Gtk.Image
 *    symbolic icon (pixel_size set in code), not a unicode check
 *    glyph, to stay consistent with the rest of the wizard's icons. ── */
.oobe-done-check {
    color: #0071e3;
    animation: pop-in 520ms cubic-bezier(0.34, 1.56, 0.64, 1) both;
}
window.dark .oobe-done-check { color: #4d9fff; }
@keyframes pop-in { from { opacity: 0; transform: scale(0.4); } to { opacity: 1; transform: scale(1); } }

/* ── Buttons: fully-rounded pill, Material state-layer press feedback ── */
.oobe-primary-button {
    background:    #0071e3;
    color:         #ffffff;
    border:        none;
    border-radius: 999px;
    padding:       18px 32px;
    font-weight:   700;
    font-size:     17px;
    min-height:    60px;
    box-shadow:    0 1px 2px rgba(15,23,42,0.14), 0 3px 8px rgba(0,113,227,0.18);
    transition:
        background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
        box-shadow       140ms cubic-bezier(0.22, 1, 0.36, 1),
        transform          90ms cubic-bezier(0.22, 1, 0.36, 1);
}
.oobe-primary-button:hover  { background: #0077ed; }
.oobe-primary-button:active {
    background: #0068d6; transform: scale(0.97);
    box-shadow: 0 1px 3px rgba(0,113,227,0.20);
    transition-duration: 70ms;
}
.oobe-primary-button:disabled {
    background: rgba(15,23,42,0.12); color: rgba(15,23,42,0.35); box-shadow: none;
}
window.dark .oobe-primary-button:disabled { background: rgba(255,255,255,0.10); color: rgba(255,255,255,0.30); }

.oobe-secondary-button {
    background:    transparent;
    color:         #475569;
    border:        1px solid rgba(0,0,0,0.14);
    border-radius: 999px;
    padding:       18px 28px;
    font-size:     17px;
    min-height:    60px;
    transition:
        background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
        border-color     140ms cubic-bezier(0.22, 1, 0.36, 1),
        transform          90ms cubic-bezier(0.22, 1, 0.36, 1);
}
.oobe-secondary-button:hover  { background: #f1f5f9; border-color: rgba(0,0,0,0.22); }
.oobe-secondary-button:active { background: #e2e8f0; transform: scale(0.97); transition-duration: 70ms; }
window.dark .oobe-secondary-button { color: #cbd5e1; border-color: rgba(255,255,255,0.16); }
window.dark .oobe-secondary-button:hover  { background: rgba(255,255,255,0.08); border-color: rgba(255,255,255,0.26); }
window.dark .oobe-secondary-button:active { background: rgba(255,255,255,0.14); }

.oobe-nav-row { margin-top: 8px; }

/* ── Form entries: Material filled-field look (tonal fill vs desktop's
 *    outline-first treatment -- reads better against the card's own
 *    28px-radius background on a small screen) ─────────────────────── */
entry, row.entry {
    background:    #f1f5f9;
    border:        1px solid transparent;
    border-radius: 16px;
    color:         #0f172a;
    min-height:    56px;
    font-size:     17px;
    transition:
        border-color     160ms cubic-bezier(0.22, 1, 0.36, 1),
        background-color 160ms cubic-bezier(0.22, 1, 0.36, 1),
        box-shadow        160ms cubic-bezier(0.22, 1, 0.36, 1);
}
entry:focus-within, row.entry:focus-within {
    border-color: #0071e3;
    background:   #ffffff;
    box-shadow:   0 0 0 3px rgba(0,113,227,0.16);
}
window.dark entry, window.dark row.entry { background: rgba(255,255,255,0.06); color: #f1f5f9; }
window.dark entry:focus-within, window.dark row.entry:focus-within { background: rgba(255,255,255,0.09); }

/* ── Bottom-sheet password dialog: Material bottom-sheet shape --
 *    rounded top corners only, flush to the bottom edge, matching how
 *    Android/LineageOS present the Wi-Fi password prompt as a sheet
 *    sliding up rather than a centered desktop-style dialog. ───────── */
.oobe-sheet {
    border-radius: 28px 28px 0 0;
    background: #ffffff;
}
window.dark .oobe-sheet { background: #1a2029; }
MOBILEOOBECSS

  cat > "${_root}/root/kibaos-mobile-oobe/src/main.vala" << 'OOBEVALA'
/*
 * KibaOS Mobile OOBE -- first-boot wizard.
 * Marker-gated (runs once), no disk-partitioning step: this only ever
 * runs after the GSI + rootfs are already flashed onto the phone.
 * Pages: Welcome -> Language/Region -> Wi-Fi -> SIM/Carrier (ofono) ->
 * Account (mandatory) -> Done.
 *
 * Design language: same tokens as the desktop installer's oobe.css
 * (#0071e3 accent, pill buttons, easeOutQuint card-ins, step dots) laid
 * over Material 3 shape + elevation for the touch surface specifically
 * -- 28px "extra-large" card radius instead of desktop's borderless
 * full-bleed page, a top linear progress track like Android/LineageOS
 * SetupWizard use, filled-tonal form fields, and a bottom-sheet Wi-Fi
 * password prompt instead of a centered dialog. See oobe.css for the
 * actual values; this file just wires widgets to those CSS classes.
 */
public class KibaMobileOobe : Adw.Application {
    const string MARKER = "/var/lib/kibaos/.oobe-done";
    const string CSS_PATH = "/usr/share/kibaos-mobile-oobe/oobe.css";

    // Steps shown in the top progress track + dots. "done" is
    // deliberately excluded -- same convention as the desktop OOBE and
    // Android's own SetupWizard, where the final celebratory screen
    // drops the step chrome entirely rather than showing "6 of 6".
    const string[] STEPS = { "welcome", "language", "wifi", "sim", "account" };

    Adw.ApplicationWindow window;
    Gtk.Stack stack;
    Gtk.ProgressBar top_progress;
    Gtk.Box dots_row;
    Gtk.Label wifi_status_label;
    Gtk.Label sim_status_label;
    bool dark_mode = false;
    string display_name = "";

    public KibaMobileOobe () {
        Object (application_id: "com.wolftechinnovations.kibaos.MobileOobe");
    }

    protected override void activate () {
        if (FileUtils.test (MARKER, FileTest.EXISTS)) {
            // already ran -- get out of the way, let the normal session
            // (budgie-panel) take over instead of showing the wizard again
            this.quit ();
            return;
        }

        var provider = new Gtk.CssProvider ();
        provider.load_from_path (CSS_PATH);
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        window = new Adw.ApplicationWindow (this) {
            default_width = 480,
            default_height = 854,
            fullscreened = true,
            deletable = false
        };
        window.add_css_class ("kibaos-oobe-window");
        // No window-close escape hatch: the account step is mandatory
        // (see build_account_page), so block any close request until
        // finish_oobe has actually written the marker file. Without
        // this, deletable=false alone still leaves things like Alt+F4
        // or a compositor-level close gesture able to tear the window
        // down mid-wizard.
        window.close_request.connect (() => {
            return !FileUtils.test (MARKER, FileTest.EXISTS);
        });

        var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        root.add_css_class ("oobe-background");

        // ── top bar: brand + language/dark-mode corner toggles ──────────
        var topbar = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        topbar.add_css_class ("oobe-topbar");
        var brand = new Gtk.Label ("KIBAOS MOBILE") { xalign = 0, hexpand = true };
        brand.add_css_class ("oobe-brand");
        var lang_btn = corner_button ("preferences-desktop-locale-symbolic");
        lang_btn.clicked.connect (() => stack.visible_child_name = "language");
        var dark_btn = corner_button ("weather-clear-night-symbolic");
        dark_btn.clicked.connect (toggle_dark_mode);
        topbar.append (brand);
        topbar.append (lang_btn);
        topbar.append (dark_btn);
        root.append (topbar);

        // ── linear progress + step dots (Material stepper pairing) ──────
        top_progress = new Gtk.ProgressBar ();
        top_progress.add_css_class ("oobe-linear-progress");
        root.append (top_progress);

        dots_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            halign = Gtk.Align.CENTER, margin_top = 10, margin_bottom = 4
        };
        root.append (dots_row);

        stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT,
            vexpand = true
        };

        stack.add_named (build_welcome_page (), "welcome");
        stack.add_named (build_language_page (), "language");
        stack.add_named (build_wifi_page (), "wifi");
        stack.add_named (build_sim_page (), "sim");
        stack.add_named (build_account_page (), "account");
        stack.add_named (build_done_page (), "done");
        stack.notify["visible-child-name"].connect (update_progress);
        stack.visible_child_name = "welcome";
        update_progress ();

        root.append (stack);

        var toolbar_view = new Adw.ToolbarView ();
        toolbar_view.content = root;
        window.content = toolbar_view;
        window.present ();
    }

    Gtk.Button corner_button (string icon_name) {
        var btn = new Gtk.Button ();
        btn.icon_name = icon_name;
        btn.add_css_class ("oobe-corner-button");
        return btn;
    }

    void toggle_dark_mode () {
        dark_mode = !dark_mode;
        if (dark_mode) {
            window.add_css_class ("dark");
        } else {
            window.remove_css_class ("dark");
        }
    }

    // Updates both the top linear track and the dot row to reflect
    // wherever the stack currently is. Pages outside STEPS (just "done")
    // push the track to full and clear the dots, matching the desktop
    // OOBE's own summary/done page treatment.
    void update_progress () {
        var current = stack.visible_child_name;
        int idx = -1;
        for (int i = 0; i < STEPS.length; i++) {
            if (STEPS[i] == current) { idx = i; break; }
        }

        while (dots_row.get_first_child () != null) {
            dots_row.remove (dots_row.get_first_child ());
        }

        if (idx < 0) {
            top_progress.fraction = 1.0;
            return;
        }

        top_progress.fraction = (double) (idx + 1) / STEPS.length;
        for (int i = 0; i < STEPS.length; i++) {
            var dot = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            dot.add_css_class ("oobe-step-dot");
            if (i == idx) dot.add_css_class ("oobe-step-dot-active");
            dots_row.append (dot);
        }
    }

    // ── page builders ───────────────────────────────────────────────────
    // Every page follows the same "dog simple" rule: one big icon so the
    // page reads before any text is parsed, one short line of title, one
    // short line of subtitle, and exactly one strongly-weighted action.
    // Selections that can safely auto-advance (language, a successful
    // Wi-Fi connect) do -- fewer taps beats a technically-more-complete
    // flow every time here.

    Gtk.Widget build_welcome_page () {
        var box = wizard_box ("start-here-symbolic", "Welcome to\nKibaOS Mobile",
            "Switch to simple -- now in your pocket.", true);
        box.append (nav_row (null, next_button ("Get started", "language")));
        return box;
    }

    // Big tap-anywhere rows instead of a dropdown -- picking a language
    // is a single decision, so it gets a single tap. Selecting a row
    // both sets the language AND advances to Wi-Fi; Back still works if
    // someone taps the wrong flag.
    Gtk.Widget build_language_page () {
        var box = wizard_box ("preferences-desktop-locale-symbolic", "Language & Region",
            "Tap the one that feels like home.", false);

        var list = new Gtk.ListBox ();
        list.add_css_class ("oobe-list");
        list.selection_mode = Gtk.SelectionMode.NONE;

        // Plain-text language/region codes instead of flag emoji -- a
        // flag glyph also conflates "country" with "language" (English
        // isn't only spoken in the US/UK), and emoji flag rendering is
        // spotty on minimal mobile font stacks. A short code badge reads
        // reliably everywhere.
        string[,] langs = {
            {"EN-US", "English (US)"}, {"EN-UK", "English (UK)"},
            {"ES", "Español"}, {"FR", "Français"}, {"DE", "Deutsch"}
        };
        for (int i = 0; i < langs.length[0]; i++) {
            var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
                margin_top = 4, margin_bottom = 4, margin_start = 6, margin_end = 6
            };
            var code = new Gtk.Label (langs[i, 0]);
            code.add_css_class ("oobe-lang-flag");
            var name = new Gtk.Label (langs[i, 1]) { xalign = 0, hexpand = true };
            name.add_css_class ("oobe-lang-name");
            row_box.append (code);
            row_box.append (name);
            var row = new Gtk.ListBoxRow () { child = row_box };
            list.append (row);
        }
        list.row_activated.connect ((row) => {
            // language choice itself isn't wired to a locale backend
            // yet -- this is a first-boot cosmetic pick until that lands
            stack.visible_child_name = "wifi";
        });
        box.append (list);
        box.append (nav_row (back_button ("welcome"), null));
        return box;
    }

    Gtk.Widget build_wifi_page () {
        var box = wizard_box ("network-wireless-symbolic", "Connect to Wi-Fi",
            "Needed for setup and updates.", false);

        var list = new Gtk.ListBox ();
        list.add_css_class ("oobe-list");
        list.selection_mode = Gtk.SelectionMode.SINGLE;
        list.row_activated.connect (on_wifi_row_activated);
        wifi_status_label = new Gtk.Label ("Scanning...") { xalign = 0 };
        wifi_status_label.add_css_class ("oobe-step-label");
        box.append (wifi_status_label);
        box.append (list);
        refresh_wifi_list.begin (list);

        var skip = new Gtk.Button.with_label ("Skip for now");
        skip.add_css_class ("oobe-skip-link");
        skip.halign = Gtk.Align.CENTER;
        skip.clicked.connect (() => stack.visible_child_name = "sim");
        box.append (nav_row (back_button ("language"), null));
        box.append (skip);
        return box;
    }

    async void refresh_wifi_list (Gtk.ListBox list) {
        // shells out to nmcli rather than talking to NetworkManager's
        // D-Bus API directly -- nmcli's terse output is plenty for a
        // pick-a-network list and keeps this file from ballooning with
        // GDBus proxy boilerplate for a first-boot wizard.
        try {
            var proc = new Subprocess (SubprocessFlags.STDOUT_PIPE,
                "nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list");
            var stdout_pipe = proc.get_stdout_pipe ();
            var dis = new DataInputStream (stdout_pipe);
            string? line;
            wifi_status_label.label = "Available networks:";
            while ((line = yield dis.read_line_async ()) != null) {
                if (line.strip () == "") continue;
                var parts = line.split (":");
                var ssid = parts.length > 0 && parts[0] != "" ? parts[0] : "(hidden)";
                var secured = parts.length > 2 && parts[2] != "" && parts[2] != "--";

                var row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
                    margin_top = 6, margin_bottom = 6, margin_start = 8, margin_end = 8
                };
                row_box.append (new Gtk.Label (ssid) { xalign = 0, hexpand = true });
                if (secured) {
                    row_box.append (new Gtk.Image.from_icon_name ("network-wireless-encrypted-symbolic"));
                }
                var row = new Gtk.ListBoxRow ();
                row.child = row_box;
                row.set_data<string> ("ssid", ssid);
                row.set_data<bool> ("secured", secured);
                list.append (row);
            }
        } catch (Error e) {
            wifi_status_label.label = "Couldn't scan for networks: %s".printf (e.message);
        }
    }

    void on_wifi_row_activated (Gtk.ListBoxRow row) {
        var ssid = row.get_data<string> ("ssid");
        var secured = row.get_data<bool> ("secured");
        if (secured) {
            prompt_wifi_password (ssid);
        } else {
            connect_wifi.begin (ssid, null);
        }
    }

    // Material bottom-sheet shape (rounded top corners only, flush to
    // the bottom edge via .oobe-sheet) rather than a centered desktop
    // dialog -- matches how Android/LineageOS present the Wi-Fi password
    // prompt as a sheet sliding up from the keyboard's own edge.
    void prompt_wifi_password (string ssid) {
        var dialog = new Adw.AlertDialog (
            "Connect to %s".printf (ssid), null);
        dialog.add_css_class ("oobe-sheet");

        var pw_entry = new Gtk.PasswordEntry () { show_peek_icon = true };
        pw_entry.add_css_class ("entry");
        dialog.set_extra_child (pw_entry);
        dialog.add_response ("cancel", "Cancel");
        dialog.add_response ("connect", "Connect");
        dialog.set_response_appearance ("connect", Adw.ResponseAppearance.SUGGESTED);
        dialog.default_response = "connect";
        dialog.response.connect ((response) => {
            if (response == "connect") {
                connect_wifi.begin (ssid, pw_entry.text);
            }
        });
        dialog.present (window);
    }

    async void connect_wifi (string ssid, string? password) {
        wifi_status_label.label = "Connecting to %s...".printf (ssid);
        try {
            string[] argv;
            if (password != null) {
                argv = { "nmcli", "device", "wifi", "connect", ssid, "password", password };
            } else {
                argv = { "nmcli", "device", "wifi", "connect", ssid };
            }
            var proc = new Subprocess.newv (argv,
                SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            yield proc.wait_async ();
            if (proc.get_successful ()) {
                wifi_status_label.label = "Connected to %s.".printf (ssid);
                // auto-advance -- a successful connect needs no further
                // confirmation tap, same reasoning as the language rows
                Timeout.add (700, () => {
                    if (stack.visible_child_name == "wifi") {
                        stack.visible_child_name = "sim";
                    }
                    return false;
                });
            } else {
                wifi_status_label.label = "Couldn't connect to %s -- check the password.".printf (ssid);
            }
        } catch (Error e) {
            wifi_status_label.label = "Connection failed: %s".printf (e.message);
        }
    }

    Gtk.Widget build_sim_page () {
        var box = wizard_box ("network-cellular-symbolic", "SIM & Carrier", "Checking for a SIM.", false);
        sim_status_label = new Gtk.Label ("Checking...") { xalign = 0 };
        sim_status_label.add_css_class ("oobe-subtitle");
        box.append (sim_status_label);
        check_sim.begin ();
        box.append (nav_row (back_button ("wifi"), next_button ("Next", "account")));
        return box;
    }

    async void check_sim () {
        // org.ofono.Manager -> GetModems, then org.ofono.SimManager's
        // Present/SubscriberIdentity properties on whichever modem shows
        // up. ofono owns telephony here, same as Calls/Chatty use.
        try {
            var conn = yield Bus.get (BusType.SYSTEM);
            var manager = yield conn.get_proxy<OfonoManagerIface> (
                "org.ofono", "/");
            var modems = yield manager.get_modems ();
            if (modems.length == 0) {
                sim_status_label.label = "No modem detected.";
                return;
            }
            sim_status_label.label = "Modem found: %s".printf (modems[0]);
            // deeper SIM-present/carrier-name lookup would proxy
            // org.ofono.SimManager on this modem path; left as a
            // follow-up once real hardware is available to test against
        } catch (Error e) {
            sim_status_label.label = "No SIM/modem available (%s).".printf (e.message);
        }
    }

    // Account is mandatory -- no skip link on this page (unlike wifi's),
    // matching Android's own SetupWizard, where the Google-account step
    // has no skip option because it's the anchor the rest of first-run
    // setup (sync, backup, restore) hangs off of. Next stays disabled
    // until a non-empty name is entered, and the window itself can't be
    // closed out from under the wizard (see close_request in activate).
    Gtk.Widget build_account_page () {
        var box = wizard_box ("avatar-default-symbolic", "What's your name?",
            "Shown on your lock screen and in Files.", false);

        var entry = new Gtk.Entry () { placeholder_text = "Your name" };
        entry.add_css_class ("entry");
        box.append (entry);

        var hint = new Gtk.Label ("") { xalign = 0 };
        hint.add_css_class ("oobe-error");
        hint.visible = false;
        box.append (hint);

        var next = new Gtk.Button.with_label ("Next");
        next.add_css_class ("oobe-primary-button");
        next.sensitive = false;
        entry.changed.connect (() => {
            next.sensitive = entry.text.strip () != "";
            hint.visible = false;
        });
        next.clicked.connect (() => {
            var trimmed = entry.text.strip ();
            if (trimmed == "") {
                hint.label = "Enter a name to continue.";
                hint.visible = true;
                return;
            }
            display_name = trimmed;
            stack.visible_child_name = "done";
        });
        box.append (nav_row (back_button ("sim"), next));
        return box;
    }

    Gtk.Widget build_done_page () {
        var box = wizard_box ("", "You're all set!", "Welcome to KibaOS Mobile.", false);

        var check = new Gtk.Image.from_icon_name ("object-select-symbolic") { halign = Gtk.Align.CENTER };
        check.pixel_size = 72;
        check.add_css_class ("oobe-done-check");
        box.append (check);

        var finish = new Gtk.Button.with_label ("Start using KibaOS");
        finish.add_css_class ("oobe-primary-button");
        finish.clicked.connect (finish_oobe);
        box.append (nav_row (null, finish));
        return box;
    }

    void finish_oobe () {
        try {
            DirUtils.create_with_parents ("/var/lib/kibaos", 0755);
            FileUtils.set_contents (MARKER, "1\n");
        } catch (FileError e) {
            warning ("couldn't write OOBE marker: %s", e.message);
        }
        this.quit ();
    }

    // ── helpers ──────────────────────────────────────────────────────────

    // Wraps every page in the same .oobe-card / .oobe-inner treatment as
    // the desktop OOBE, just with Material's 28px shape scale + real
    // elevation instead of desktop's borderless full-bleed page (see
    // oobe.css for why -- no cursor/hover to carry hierarchy on touch).
    // is_welcome swaps in the larger .oobe-welcome-greeting title style,
    // same distinction the desktop installer makes for its first page.
    // icon_name is a themed/symbolic GTK icon name (e.g.
    // "network-wireless-symbolic"), never an emoji glyph -- the mobile
    // OOBE renders every page icon and status mark through Gtk.Image
    // so the wizard reads cleanly regardless of emoji font support.
    Gtk.Box wizard_box (string icon_name, string title, string subtitle, bool is_welcome) {
        var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
        card.add_css_class ("oobe-card");
        card.add_css_class ("oobe-inner");

        if (icon_name != "") {
            var icon_image = new Gtk.Image.from_icon_name (icon_name) { halign = Gtk.Align.START };
            icon_image.pixel_size = 64;
            icon_image.add_css_class ("oobe-page-icon");
            card.append (icon_image);
        }

        var title_label = new Gtk.Label (title) { xalign = 0, wrap = true };
        title_label.add_css_class (is_welcome ? "oobe-welcome-greeting" : "oobe-title");
        var subtitle_label = new Gtk.Label (subtitle) { xalign = 0, wrap = true };
        subtitle_label.add_css_class ("oobe-subtitle");

        card.append (title_label);
        card.append (subtitle_label);

        var outer = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
            margin_top = 12, margin_bottom = 24, margin_start = 18, margin_end = 18,
            vexpand = true, valign = Gtk.Align.FILL
        };
        outer.append (card);
        return outer;
    }

    // Bottom nav row: back (optional, left) + primary action (right),
    // pinned to the bottom of the page like Android SetupWizard's own
    // persistent nav bar rather than inline with the content above it.
    Gtk.Box nav_row (Gtk.Button? back, Gtk.Button? primary) {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            valign = Gtk.Align.END, vexpand = true, margin_top = 16
        };
        row.add_css_class ("oobe-nav-row");
        if (back != null) {
            row.append (back);
        }
        var spacer = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0) { hexpand = true };
        row.append (spacer);
        if (primary != null) {
            row.append (primary);
        }
        return row;
    }

    Gtk.Button back_button (string target_page) {
        var btn = new Gtk.Button.with_label ("Back");
        btn.add_css_class ("oobe-secondary-button");
        btn.clicked.connect (() => stack.visible_child_name = target_page);
        return btn;
    }

    Gtk.Button next_button (string label, string target_page) {
        var btn = new Gtk.Button.with_label (label);
        btn.add_css_class ("oobe-primary-button");
        btn.clicked.connect (() => stack.visible_child_name = target_page);
        return btn;
    }

    public static int main (string[] args) {
        var app = new KibaMobileOobe ();
        return app.run (args);
    }
}

[DBus (name = "org.ofono.Manager")]
interface OfonoManagerIface : Object {
    public abstract async string[] get_modems () throws Error;
}
OOBEVALA

  arch-chroot "${_root}" bash -c "
    cd /root/kibaos-mobile-oobe &&
    meson setup build &&
    ninja -C build &&
    ninja -C build install
  " || echo "!! kibaos-mobile-oobe failed to build -- check the meson/ninja log above" >&2

  cat > "${_root}/etc/xdg/autostart/kibaos-mobile-oobe.desktop" << 'OOBEAUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Setup
Exec=kibaos-mobile-oobe
X-GNOME-Autostart-enabled=true
OOBEAUTOSTART

  : "${KIBA_MOBILE_GSI_URL:=https://mirrors.lolinet.com/firmware/halium/GSI/ubports_GSI_installer_v10.zip}"
  if [ "${KIBA_SKIP_GSI_FETCH:-0}" = "1" ]; then
    echo "=== KIBA_SKIP_GSI_FETCH=1 -- skipping Halium GSI fetch (see README-INSTALL.md for a manual pointer) ==="
  else
    mkdir -p /w/halium-gsi && cd /w/halium-gsi
    if curl -fL -o gsi-fetch.zip "${KIBA_MOBILE_GSI_URL}"; then
      unzip -o gsi-fetch.zip -d extracted >/dev/null
      _gsi_img="$(find extracted -maxdepth 3 \( -iname 'system.img' -o -iname '*.img' \) 2>/dev/null | head -n1)"
      if [ -n "${_gsi_img}" ] && [ -f "${_gsi_img}" ]; then
        cp "${_gsi_img}" "${_out}/kibaos-mobile-gsi-arm64.img"
        sha256sum "${_out}/kibaos-mobile-gsi-arm64.img" > "${_out}/kibaos-mobile-gsi-arm64.img.sha256"
        echo "=== Fetched Halium GSI: ${_out}/kibaos-mobile-gsi-arm64.img ==="
      else
        echo "ERROR: GSI zip downloaded from ${KIBA_MOBILE_GSI_URL} but no .img found inside -- check KIBA_MOBILE_GSI_URL / mirror layout. Refusing to continue with a mobile build that has no bundled GSI (the installer zip stage would fail anyway, just later and with a more confusing error). Set KIBA_SKIP_GSI_FETCH=1 if you intend to ship a thin installer and push the GSI manually per README-INSTALL.md." >&2
        cd /w
        return 1
      fi
    else
      echo "ERROR: GSI fetch failed -- curl could not retrieve ${KIBA_MOBILE_GSI_URL} (bad URL, 404, or network issue). Refusing to continue with a mobile build that has no bundled GSI (the installer zip stage would fail anyway, just later and with a more confusing error). Set KIBA_SKIP_GSI_FETCH=1 if you intend to ship a thin installer and push the GSI manually per README-INSTALL.md." >&2
      cd /w
      return 1
    fi
    cd /w
  fi

  : "${KIBA_MOBILE_HALIUM_RAMDISK_URL:=https://github.com/halium/initramfs-tools-halium/releases/download/continuous/initrd.img-touch-arm64}"

  echo "=== Fetching boot.img repack ingredients (generic Halium ramdisk + magiskboot) ==="
  mkdir -p /w/boot-repack-tools && cd /w/boot-repack-tools

  curl -fL -o halium-generic-ramdisk.cpio.gz "${KIBA_MOBILE_HALIUM_RAMDISK_URL}" \
    || { echo "!! Halium generic ramdisk fetch failed (${KIBA_MOBILE_HALIUM_RAMDISK_URL}) -- see docs.halium.org for the current generic-ramdisk artifact and re-run with a corrected KIBA_MOBILE_HALIUM_RAMDISK_URL. No fallback -- failing the build." >&2; exit 1; }

  _magisk_apk_url="$(curl -fsL https://api.github.com/repos/topjohnwu/Magisk/releases/latest \
    | jq -r '.assets[] | select(.name | test("\\.apk$")) | .browser_download_url' | head -n1)"
  [ -n "${_magisk_apk_url}" ] && [ "${_magisk_apk_url}" != "null" ] \
    || { echo "!! couldn't resolve the latest Magisk release APK via the GitHub API -- can't fetch magiskboot. No fallback -- failing the build." >&2; exit 1; }
  curl -fL -o magisk-latest.apk "${_magisk_apk_url}" \
    || { echo "!! Magisk release APK fetch failed (${_magisk_apk_url}) -- can't fetch magiskboot. No fallback -- failing the build." >&2; exit 1; }
  unzip -o -j magisk-latest.apk 'lib/arm64-v8a/libmagiskboot.so' -d . \
    || { echo "!! couldn't extract libmagiskboot.so (arm64-v8a) from the Magisk APK -- release layout may have changed. No fallback -- failing the build." >&2; exit 1; }
  [ -f libmagiskboot.so ] \
    || { echo "!! Magisk APK didn't contain lib/arm64-v8a/libmagiskboot.so -- can't repack boot images on-device. No fallback -- failing the build." >&2; exit 1; }
  mv libmagiskboot.so magiskboot
  chmod 0755 magiskboot
  echo "=== Bundled magiskboot + generic Halium ramdisk for on-device boot.img repack ==="
  cd /w

  tar -C "${_root}" --numeric-owner -cpf "${_out}/kibaos-mobile-rootfs.tar" .
  gzip -9 "${_out}/kibaos-mobile-rootfs.tar"
  sha256sum "${_out}/kibaos-mobile-rootfs.tar.gz" > "${_out}/kibaos-mobile-rootfs.tar.gz.sha256"

  _rootfs_kb="$(du -sk "${_root}" | cut -f1)"
  _img_kb=$(( _rootfs_kb + (_rootfs_kb / 5) + 262144 ))   # +20% headroom, +256MB floor for OOBE/updates/writes
  mkfs.ext4 -q -F -L kibaos-rootfs -d "${_root}" -m 0 \
    "${_out}/kibaos-mobile-rootfs.img" "${_img_kb}K"
  sha256sum "${_out}/kibaos-mobile-rootfs.img" > "${_out}/kibaos-mobile-rootfs.img.sha256"

  _zip_root="/w/kibaos-mobile-installer-zip"
  rm -rf "${_zip_root}"
  mkdir -p "${_zip_root}/META-INF/com/google/android"
  cp "${_out}/kibaos-mobile-rootfs.img" "${_zip_root}/rootfs.img"
  if [ -f "${_out}/kibaos-mobile-gsi-arm64.img" ]; then
    cp "${_out}/kibaos-mobile-gsi-arm64.img" "${_zip_root}/android-rootfs.img"
  fi
  cp /w/boot-repack-tools/magiskboot "${_zip_root}/magiskboot"
  cp /w/boot-repack-tools/halium-generic-ramdisk.cpio.gz "${_zip_root}/halium-generic-ramdisk.cpio.gz"
  echo "# this zip is installed by update-binary directly, not parsed as edify" \
    > "${_zip_root}/META-INF/com/google/android/updater-script"
  cat > "${_zip_root}/META-INF/com/google/android/update-binary" << 'UPDATEBINARY'
#!/sbin/sh

OUTFD="$2"
ZIPFILE="$3"

ui_print() {
  echo "ui_print $1" >> "/proc/self/fd/${OUTFD}"
  echo "ui_print" >> "/proc/self/fd/${OUTFD}"
}
abort_install() {
  ui_print "!! $1"
  exit 1
}

ui_print "=== KibaOS Mobile installer ==="

_slot=""
if command -v getprop >/dev/null 2>&1; then
  _slot="$(getprop ro.boot.slot_suffix 2>/dev/null)"
fi

_find_by_name() {
  for _cand in \
    "/dev/block/bootdevice/by-name/$1${_slot}" \
    "/dev/block/by-name/$1${_slot}" \
    "/dev/block/platform/*/by-name/$1${_slot}"; do
    for _p in ${_cand}; do
      [ -b "${_p}" ] && echo "${_p}" && return 0
    done
  done
  return 1
}

_boot_dev="$(_find_by_name boot)"
_init_boot_dev="$(_find_by_name init_boot)"
_boot_repacked=0

if [ -z "${_boot_dev}" ] && [ -z "${_init_boot_dev}" ]; then
  ui_print "!! couldn't find a known boot or init_boot partition path on"
  ui_print "!! this device -- skipping the boot image repack entirely."
  ui_print "!! Samsung and some other OEMs don't expose these via"
  ui_print "!! by-name symlinks in recovery; you'll need to sort out"
  ui_print "!! halium-boot.img by hand for this device."
else
  rm -rf /tmp/kibaos-boot && mkdir -p /tmp/kibaos-boot
  cd /tmp/kibaos-boot || abort_install "no /tmp to stage the boot repack in"
  unzip -o "${ZIPFILE}" 'magiskboot' 'halium-generic-ramdisk.cpio.gz' -d /tmp/kibaos-boot >/dev/null 2>&1
  [ -f magiskboot ] || abort_install "magiskboot missing from zip -- can't repack the boot image"
  chmod 0755 magiskboot
  gzip -dc halium-generic-ramdisk.cpio.gz > halium-generic-ramdisk.cpio 2>/dev/null \
    || abort_install "couldn't decompress the bundled Halium ramdisk"

  mkdir -p /data/kibaos-boot-backup

  if [ -n "${_init_boot_dev}" ]; then
    _target_dev="${_init_boot_dev}"
    _target_name="init_boot"
  else
    _target_dev="${_boot_dev}"
    _target_name="boot"
  fi

  ui_print "backing up stock ${_target_name} to /data/kibaos-boot-backup/..."
  dd if="${_target_dev}" of="/data/kibaos-boot-backup/${_target_name}${_slot}.img" bs=4M \
    || abort_install "couldn't back up ${_target_dev} -- refusing to touch it unbacked-up"

  ui_print "unpacking stock ${_target_name} image..."
  cp "/data/kibaos-boot-backup/${_target_name}${_slot}.img" ./stock.img
  ./magiskboot unpack -h stock.img
  _unpack_rc=$?
  if [ "${_unpack_rc}" = "2" ]; then
    ui_print "!! ${_target_name} is a ChromeOS-format image -- magiskboot"
    ui_print "!! can't repack this layout. Skipping the boot repack;"
    ui_print "!! sort out halium-boot.img by hand for this device."
  elif [ ! -f ramdisk.cpio ]; then
    ui_print "!! no generic ramdisk section found in ${_target_name} --"
    ui_print "!! this device's boot layout isn't one this installer"
    ui_print "!! recognizes. Skipping the boot repack; sort out"
    ui_print "!! halium-boot.img by hand for this device."
  else
    ui_print "swapping in the generic Halium ramdisk..."
    cp halium-generic-ramdisk.cpio ramdisk.cpio
    ./magiskboot repack stock.img new-boot.img \
      || abort_install "magiskboot repack failed -- ${_target_name} left untouched"
    ui_print "flashing repacked ${_target_name} to ${_target_dev}..."
    dd if=new-boot.img of="${_target_dev}" bs=4M \
      || abort_install "write failed to ${_target_dev} -- restore from /data/kibaos-boot-backup/${_target_name}${_slot}.img via fastboot if this device won't boot"
    ui_print "${_target_name} repacked and flashed."
    _boot_repacked=1
  fi
  cd /
  rm -rf /tmp/kibaos-boot
fi

mount /data 2>/dev/null
if ! mountpoint -q /data 2>/dev/null && ! grep -q ' /data ' /proc/mounts; then
  abort_install "couldn't mount /data -- format it ext4 and unencrypted first"
fi

ui_print "extracting installer payload..."
rm -rf /tmp/kibaos-installer
mkdir -p /tmp/kibaos-installer
cd /tmp/kibaos-installer || abort_install "no /tmp to stage in"
unzip -o "${ZIPFILE}" 'rootfs.img' 'android-rootfs.img' -d /tmp/kibaos-installer >/dev/null 2>&1

[ -f /tmp/kibaos-installer/rootfs.img ] || abort_install "rootfs.img missing from zip"

ui_print "writing KibaOS Mobile rootfs to /data/rootfs.img..."
cp /tmp/kibaos-installer/rootfs.img /data/rootfs.img || abort_install "failed writing rootfs.img"

if [ -f /tmp/kibaos-installer/android-rootfs.img ]; then
  ui_print "writing Halium GSI to /data/android-rootfs.img..."
  cp /tmp/kibaos-installer/android-rootfs.img /data/android-rootfs.img || abort_install "failed writing android-rootfs.img"
else
  ui_print "!! no GSI bundled in this zip -- push a system image to /data/android-rootfs.img yourself before rebooting"
fi

touch /data/.writable_image /data/.writable_device_image 2>/dev/null

rm -rf /tmp/kibaos-installer

ui_print "=== done -- reboot into KibaOS Mobile ==="
if [ "${_boot_repacked}" = "1" ]; then
  ui_print "(${_target_name} was repacked and flashed by this zip --"
  ui_print " no separate fastboot step needed. Stock backup is at"
  ui_print " /data/kibaos-boot-backup/ if you ever need to revert.)"
else
  ui_print "(this zip didn't touch the boot partition -- make sure a"
  ui_print " Halium-compatible boot.img is already flashed separately)"
fi
exit 0
UPDATEBINARY
  chmod 0755 "${_zip_root}/META-INF/com/google/android/update-binary"
  ( cd "${_zip_root}" && zip -r -X "${_out}/kibaos-mobile-installer.zip" . >/dev/null )
  sha256sum "${_out}/kibaos-mobile-installer.zip" > "${_out}/kibaos-mobile-installer.zip.sha256"
  rm -rf "${_zip_root}"

  cat > "${_out}/README-INSTALL.md" << 'READMEDOC'
# KibaOS Mobile — install

This is the KibaOS Mobile *userspace only* (Budgie panel/raven on phoc,
ofono, Calls, Chatty, squeekboard, libgestures, sddm for lock/login),
shipped in three forms:

- `kibaos-mobile-installer.zip` — flash this from TWRP, easiest path.
- `kibaos-mobile-rootfs.img` — the same thing pre-built as a raw ext4
  image (what's inside the zip), if you'd rather push it yourself.
- `kibaos-mobile-rootfs.tar.gz` — the raw tarball, for
  `halium-install`/manual use if neither of the above fits your setup.

None of these are bootable by themselves. You still need, per your
device's Halium port status:

1. `boot.img`/`init_boot.img` — repacked automatically, **on the phone,
   during install** — not pre-built by this pipeline. The zip carries
   `magiskboot` (a static unpacker/repacker) and a generic Halium
   ramdisk; update-binary dumps whatever's actually sitting on this
   device's own `boot`/`init_boot` partition, swaps in the Halium
   ramdisk, and flashes the result back — so the kernel, dtb, and header
   metadata always come from *this exact phone's* stock image instead of
   being downloaded or guessed from a version string. This works
   regardless of Android version/GKI status, since magiskboot
   auto-detects the boot image layout (plain boot.img, GKI header v3/v4
   with a split `init_boot`, etc.) rather than this pipeline assuming one
   ahead of time.

   Defensive by design: update-binary only ever touches a `boot`/
   `init_boot` partition it can positively identify via known by-name
   symlinks with A/B slot-suffix detection, backs up whatever's already
   there to `/data/kibaos-boot-backup/` *before* writing anything, and
   skips the repack outright (rather than guessing) if it can't confirm
   a safe target, if the image is a layout magiskboot doesn't recognize,
   or if it can't find a generic-ramdisk section to swap. Samsung devices
   (no fastboot-flashable boot partition) fall through to the manual
   step regardless. There's no per-device kernel build required either
   way — if the automatic repack can't proceed on a given device, you're
   pointed at building/supplying a `halium-boot.img` yourself rather than
   this silently shipping a broken one.
2. The Halium GSI `system.img` (arm64) -- fetched via the Halium-boot
   porting method (prebuilt, device-agnostic GSI, no AOSP repo sync)
   unless `KIBA_SKIP_GSI_FETCH=1` was set for this run, and already
   bundled into the installer zip as `android-rootfs.img` if the fetch
   succeeded. Standalone copy at `kibaos-mobile-gsi-arm64.img`
   (+ `.sha256`) alongside these files. Source defaults to the lolinet
   mirror (build.lolinet.com/file/halium/GSI); override
   `KIBA_MOBILE_GSI_URL` to pin a specific build/mirror. If the fetch was
   skipped or failed, grab a GSI build manually from the same mirror or
   devices.ubuntu-touch.io -- the zip will say so on install if it's
   missing.

## Install steps (recommended: the zip)

1. Boot (not flash) TWRP or another Busybox-capable recovery, and confirm
   `/data` is unencrypted and formatted ext4 -- wipe/reformat in recovery
   if it isn't.

2. Push and flash the zip:

       adb push kibaos-mobile-installer.zip /sdcard/
       adb shell twrp install /sdcard/kibaos-mobile-installer.zip

   (or do the same from TWRP's own UI: Install → pick the zip → swipe).
   This repacks and flashes `boot`/`init_boot` in place (see item 1
   above — it'll say plainly in the TWRP log if it couldn't and you need
   to sort out a `halium-boot.img` by hand instead), writes `rootfs.img`
   to `/data/rootfs.img`, and writes the bundled GSI to
   `/data/android-rootfs.img`.

3. Reboot. boot.img's initramfs mounts `/data`, loop-mounts
   `/data/rootfs.img`, and `switch_root`s into it -- that's KibaOS
   Mobile's `kibaos-mobile-oobe` first-boot flow starting up, no separate
   disk installer involved.

## Alternative: halium-install (if the zip doesn't fit your device)

Some devices/recoveries don't play well with the shell-script
update-binary trick, or you may want image conversion/renaming handled
for you instead of doing it by hand. `halium-install`
(https://github.com/jbruechert/halium-install -- stages everything on
your host machine first, avoiding old-TWRP/no-busybox headaches) does
the same job from a PC instead of inside recovery:

    git clone https://github.com/jbruechert/halium-install
    cd halium-install
    sudo ./halium-install -p none \
      kibaos-mobile-rootfs.tar.gz kibaos-mobile-gsi-arm64.img

`-p none` tells it this isn't one of Halium's bundled distros
(reference/neon/ut/debian-pm/etc.) -- just install the tarball as-is.
`sudo` is required (the script loop-mounts image files via
qemu-user-static/simg2img). The official on-device installer
(https://github.com/Halium/halium-scripts, `halium-install` in that
repo) works too, but runs its steps over adb shell instead of on the
host, so it depends on the recovery's own userspace being complete
enough (working busybox etc.).

Full background: docs.ubports.com/en/latest/porting/build_and_boot/Halium_install.html
READMEDOC

  echo "╔══════════════════════════════════════╗"
  echo "║  KibaOS Mobile rootfs build complete! ║"
  echo "║  ${_out}/kibaos-mobile-rootfs.tar.gz  ║"
  echo "╚══════════════════════════════════════╝"
}

if [ "${KIBA_ARCH}" = "mobile" ]; then
  build_kibaos_mobile
  exit 0
fi

install_archiso() {
  pacman -S --noconfirm --needed archiso
}
install_archiso

WORKDIR="/w"
ISO="kibaos-v${RUN_NUM}"
PROFILE="${WORKDIR}/kiba-profile"
AIROOTFS="${PROFILE}/airootfs"

cd "${WORKDIR}"
cp -r /usr/share/archiso/configs/releng/ "${PROFILE}"

if [ -f "${PROFILE}/airootfs/usr/lib/initcpio/install/archiso" ]; then
  sed -i '/11-dm-initramfs\.rules/d' \
    "${PROFILE}/airootfs/usr/lib/initcpio/install/archiso"
fi

mkdir -p "${AIROOTFS}"
sed -i 's/^CheckSpace/#CheckSpace/' "${PROFILE}/pacman.conf"
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' "${PROFILE}/pacman.conf"
if [ "${KIBA_ARCH}" = "x86_64" ]; then
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "${PROFILE}/pacman.conf"
fi

# ═══════════════════════════════════════════════════════════════════════════
# KibaOS kernel: Arch's own `linux` package + the KibaOS DRM panic screen
#
#   The patch below makes the kernel's DRM panic handler (drm_panic.c) paint
#   the KibaOS crash screen (":(" / Kiba on the shore) instead of the plain
#   "KERNEL PANIC!" text. It is generated by gen_kiba_panic.py and verified
#   to apply to Linux v6.18 .. v7.3 (offsets only).
#
#   The kernel is built from Arch's official PKGBUILD for the exact `linux`
#   version currently in [core], with the patch added and CONFIG_DRM_PANIC=y,
#   then served to mkarchiso from a local repo placed ahead of [core].
#
#   This takes a while and needs ~15 GB of disk. Set KIBA_STOCK_KERNEL=1 to
#   skip it. If anything in here fails (patch no longer applies to a newer
#   kernel, network blip, ...) the ISO is built with the stock kernel instead.
# ═══════════════════════════════════════════════════════════════════════════
KIBA_KERNEL_DIR="/w/kiba-kernel"
KIBA_KERNEL_REPO="/w/kiba-repo"
KIBA_PANIC_PATCH_NAME="0001-drm-panic-draw-embedded-KibaOS-crash-screen.patch"
KIBA_CUSTOM_KERNEL=0

if [ "${KIBA_ARCH}" = "x86_64" ] && [ "${KIBA_STOCK_KERNEL:-0}" != "1" ]; then
  rm -rf "${KIBA_KERNEL_DIR}" "${KIBA_KERNEL_REPO}"
  mkdir -p "${KIBA_KERNEL_DIR}" "${KIBA_KERNEL_REPO}"

  base64 -d << 'KIBAPANICPATCH' | gunzip > "${KIBA_KERNEL_DIR}/${KIBA_PANIC_PATCH_NAME}"
H4sICHzU5WoCA3BhdGNoLnR4dACsWntz2za2/1v+FGh2prVj2SGeJJsmU6dJG99tHuOk2/Z2MhqK
pGwlsqgryYm9u/3uCxwABwBFJb13bndb0yTO7xwcnDfczGczcnJyOd+S6kGznn9s15sHl6sb/Xxt
/p2squW8Pq3J9HNfD+bLpr0lrcxVLfLT06KcNjyvCc0yJcTBycnJ59EPjo+Pv8Dh++/JCRdjRY71
f3Py/fcH5ID8bb6sFzdNS+6ZpfV6W0/my227XlaL06t7/e/NuvqUfD9OvwOryYf5tJrMr6vLFiAO
yItXT3/5+dnk7Je3z19dHN77r65uF3dL8mO1aK9X7b2jh7jk6bM3P1ycv357/url4b2nFy8IIJKr
atks2rVZaXYhJDfbEFKMKRN6J2SzrbZ63cdu3hAQcnu7nazbelstLxft4Wa7vqm3xIi4qatld7Od
TG9ms3ZN7m+m4wMy+vOA6P8fHDucadctCGxjU6/bdkkeEY3QPjw4vu6am0WrN7qurg+jFWOgGRNz
WlrKY7ef12cXL2BTydqD49GI3Huq5STbq5a019O2adqG/F2vefWGVOvtp279gXRL+GxV4AT5o2ln
1c1i+8jI884o5Pjg+MF90rSb+eWSbFZV3ZKTx345/D4mVJ1SRWbzW81k1ekDHJPrbtltO0DuyPpm
uSHLVpsOuaxW5P4D1IT+oHE1mSbyGtHHdpi8/zgmN5wR+DKZrY4Ojv+lt7hutzfrJTn8SO6HT+Tx
Yy2NlvpPK/jBsf76ujIo3bIlFz8/I4vqrl2fkmdamjsjGZm2dXfdbmBBsLLZfLE4PCJ4yGO9EUDb
Xs03xChwQ2bdmlTLO+IOnbhD396tIiSyuVmtuvV2Qw6vq9WqbcZa5ZdtA2AaYNNuJyutugWZVpu2
OdKIDSIbZ7jUkPrX2bqqt/NOewZq3+z61OAEhYKJgiLBTmGzX7JPbS4jov+pu+VmS9xiwLCqABBy
H370V5uDub+qtGmCjm/dz7vBI3MkhabQJg94J4+balvpAxslR/5ef8/A+EafruaLlhy+J995itXV
ETFwKcm6NaD3V8fHD3e+zR3caGR+u6Njcscs+mg+I4dfadoj2Jg1qof+w3tyDLiPI9ZuXbSD1RU5
Ie8d3h3VH7o7TRiZs1to3r7Xp+5+vSIPAsQ4KAvY37HP43jZjv4SnkF0ipxHivzkFNnTVnMbazL9
uEw+mTe3Wp23Xp1Wn0urpaBO+PUWVHM7uCXzdh628inayqe+aka37PNAeo/HZHn0l+BQaLPrrx6R
v58/OdNx9eX5D5O3F2cv3+gQ++zlW/L116CW7+LvL3949fOrizf6GzqFluyxVohZfmce76jX8Chy
QhNUyFrvQaegycWzH95Ozl+evz00irwDZWp7gl/Mg4bwYo564Uk7L/l6beLJ4g8t3Tunnj/tnsjx
I2JNGV68N79rgzFv/kwD5N5UUa+rzRXxKahul9u1/mgC1KLd6jQ97UzI33bkQ6sdYr7dAFy1WcEG
dUDqTslbzDE6idTr+coEMXLYnl6eknv/+PHNt+SXZTXVlqlhrrsb48ldtyWzzb0jQNPRdrPVuyWr
tYmGDfk0316BtB90naDD5qzTNNN20dk96FC+MbUBEF+AAepIXS02LdHHbFa48KmBt11HNtfVYmGi
O3zTlqErAf1jaWhMTK4/6GUu8rdk2a31erJtb7cOpxeAIbdD7O1XK38lDI96UdjsbWL0Ru6bRxdH
TWg1Z75ri+/M6e5YGhYRa8DaibaN9olGR4y5/qEjeHP30DHxjmJ+9/G9u7PmCI4eFzH//jfZTLWv
zRt9PomjvDh/OfnVf79q55dX290FzyFmuKwO52X5PDBevL5sjVLm/9RmclVpvWhbi88SbcIVN99s
EiuEAwKJg4T3YwGek+8exdIlH391Ptx8Io/CFsGzmiv9Sr/vgT1IyMHjSGss8F9IFJg9ROymJ9Wv
KdBz57qjzsTnaCsnWoQjvdYE4ZHOGe6j24v+eoVf/Yma4HP+j8nFq19ePp388vpQ8//uO106jdON
2yMw1cihzaFkPhgD9fvjYzhAiEXvzGZ8QV93i249ma2768nt+nJa6H8Oo+pCE5hYoomcC9hISkBD
M+NuW//zKFiEDz/EoN+sdXG17VYQmabddttd65p+MTsaG5uwZS6E/433Z11NmagBZrEOVXgajzNd
b4/DgY9jA9HqhGg7GJHR33pO+uSnyfnT32yY/hzXlM8+EU7+H+RhKNDAMZ9dXJz9Pnlz/t/PDvvV
4OYonPhOtWl47hCY8yVQKNogspOF9alCFgk9ybqtNjpVfJxv5lNTgOsWeG69vlsu7nQ6md5c6vg1
60wr47SJjm55X28u/8CnyWK+1HX+CaHvThft0nv17UAxESnJtFeT3/o1SHM3UJ71qX7fLTWMaI0h
M+E8BMMk+OjiAUoNEKrBGs0G7x17sRF77Fcbd9dvYnhXFgw1rlO7Uh/Y5/WlezzvndozITqDYRmJ
dswK9o6GDhELqg0f3F2va971Omtvu4vusgMxD/u57L757/gLSVIrjICmAce0okaH0NqX1LT2imbj
crCxt/ytMU1uNl9qno4co68c41DyEmeHe0oBp/ijKOkZCyH/p2hkJhyjIe3pEzK/OF5GqOYvjZOS
Gcvn5j7JwoNl+0lnZl3KXXdN62dLdvKU2X9OT2nbZHXGYeT0oGk/PljeLBZfGi+lbMxBZuOMHNMx
pWVhRk1mRvHm9dPfTn6e6yp1056cN7pYnc/m7fpb8tPrn0/YaWaa6BfnbyFEuMLXlbmukLRRx1UQ
Y3LZLltdPegaaXpnfpmEmHa6ugN6k9TIGS2fPGE8O1Fnz56cCKn/U3BxdpKdPftRPVHFU54/PV0t
dbn7tNP145a0jda+xjRjJ6geAetHSHGkm5G2qq9svtJljGmPvyUV2bT/c9Mu69YsWOtSd7ro6g+b
MZAS8od+tXlnmoCxjmzvTk9P9UtoaZiUMF6qlptVtW6hhtQkn67adQsjDwDSDmU0T74xON/oVsdo
r4ZRQ7W0YcDkVh17gfrQMTqyo52qacjNyqRVzLRacjvUAGP1NfLf5jNtDTOwbBsrIGycvzj76dnk
uf6uP2pme7+HFXGVMhpRlbPBb89Ho1LQwU9QlI6UyPZ+fT7iavhr1BmOtIIH17jKaLTns60FRmLP
R0jMo2FSH19HUuz//tuIimL/599HIs+NQveNe6DPoIroXKKTi24Qrh6aFL1aVHV73ZqUkcwEIe+a
9aa/Xum1ZvFm25l+Ecr2+dIaxMYuDaMgN//586GVBuJxmC0NFIoDXY+2cCNvdpspNi10bNVPFedl
DU8Nr6rKPM3ELJ818I4zlufuSeT1GKhlVWQN0AgpqxJWMinyiponXqisZoBT6/+15qltZ1wjAnUr
2mpWmLfNtM1mGTxVrZiBPJWcakHMEy1kVgvzNC1r1swsdZM1ZQuYJZtmFqfOGjYDjjWry1YCDp22
DpFPyza31FNWixYkL6qybYAml2U1K+GpLZopfFV1KVuQLK/LsiksdVGWsoa3cpZr7vA0LVQLfBQr
mhnIq2SR1SAFE7JplKXmVFUzi97ms6lyWqU50BRZVVidiypvrdYyTlvldM6rnNrvddvUVt5qNi0b
eCrzSjQgTynKWQ0nVhda+dJSZxUtFWCKmcoqWKkPVBUzkJIKas9O1GpWw1OuKqp1CtRaG1N9TsPG
V8S2t9FZpZ0YU/3DGxsd82Ks089YjOFRCfOUmUcGj7l5lPqpgM/mlQCaXD8yS57pR2WeuHngerl5
oCxzT0z/NBCan3kEEHhhf5onZn4wy1uOqXnF3RJhXlDzqfTIhfukHLVBYYWjYaUVEpQLhGzstpnD
ErMPYEV72wx7hycJREZaxsyjwc2TbcIykAZoDD/lXufmZ+42T7llJ8eFF5talTvBFOzSaJrbjXrB
JHC29Jn02NwpSzPkBkxJxyjPnBIoFbvYhoSFs5WgCqtawDYoOcCYhWZbqvA7KPRK4OfNBQSThh8D
HKaCuBlCmpe5OVKjPGZk1ZnGnRnIAe9FDwBOMAPPtMIo5naMxsAoYhUJFmyVSdxfDli5E0E4HAmA
mbcqC1SOvUc4LDBqButligVmITMgdSrn3noHpOIZ+owEE4LTz4TdIdiCMLAcDd7LmmCBumMs5Y2V
ebukGe6M5d6nKCICP8G8z7htx+g0oMsgKVgcxR16D0OP5d75AFE6jzMOLynKDACijEwEYUtndVQ6
UVV04Ckos3Zc4tlYMwYQa6AgFWiE2WiRmjkop/SGVIJ+rcM6Rs4tGc+9nUJAYoV9619yq8/cWwaG
ShchrXLMK+pND8xGedZyd29c4YZkzEf6PRoLtUGIonD2aJ0UJUYtmpU+0ADv3McGMazXsF3QkMCg
5mOhEF64wkd8G8asgWG0K5154RvUK4Y8Zo2Lez5BbYaf8K8xdllMasSXMrFeGUV4h8ow4iFqCinQ
Go06M597chewgshlEYvMYkeTmCesE+I77nXj/EVF6NyqE+TmyTaEiL1QoF/bJ+bNi/oHxtCeOXpj
7iGFO2pwQIDnPhwl0UJgtC2RD42F92nB4vtQBz5QoOzOcHx+sFvAQG4zjos5qXdSjKfc+37gIVIe
Mj5my8CyKzBBCxmyOsQXGwHRXrzzOUQVIXKsgEAojoLmMbDbX8CWPHElnseQWG0AY+dCkYhWEVDD
iNQWslSfVr8MA/MuFNCzIIhO+rFPR6TWnlQ4A3ik4LfBOGkSzksZRydHJ7y9s9yftlVM0D/DkjHK
QKEkROPs4cOzVIhKQ0lqo0A4Q5plCWm2l5RnLpLREOhLn/m4TPnS3m44Q0/2KaOPIHBxnsfGwrnL
9FExG+khysKeLcdIwjCulz6wR3AQ9oODaHYli6IVR/8uMDlZKTPpiiHI3EUS8Io4RlOM9xTTUlH6
8Gb2JzDFSV9n5InppHgokklN7jHCUHsw0NsdDMZ3StHMHAwohvlE53JsMQQXiWSxhMDyiUbdCncg
eeLpcCIIEmxGYFJ2tpcledBhKd8gJLo3tUSczESG6rc1UrkPi0aCxbsTGMuKEPYNQZm79gg17Xan
QhwG8HibXMQpDsAKjqZlnkoVtXWU9/o8zU/57s3BF314lRosw06DhcrXLFNxzcnTMh5RffjE2B6M
F4IWl8N44jNSukYg+GiBVuOSu0AINaxHB4GmwqTfZO5PGQ3jc6fLmWVoo3uo2eCAC58zaQgxeRIf
0DYoFFeF1zIIsEPKQ0XPWag8S6wzbabJdiiYy2bortQ2DEUSvXKMfhgYSt9SY40ChCJLvFlHW9fn
YrRE8QALWJX4Tvit8oBIIze0LacHLcqQQAqswTDo5KWHlfFsYAA2YHLzwaELX4HCB6zeUQUFWkbU
hSXbt8dOd6F5KjjicucVZR6aRY9YpAkpsjXT/jsQhtkV9BA1V8ACMlUWzWdir1BpIC5jBjhdCfWE
jEvVIlhQiQMF57UILuKywh6eNw90jxBTZGwxwscC8IkSeUM2KWmUKbFCVaGl3seRY9mCHMskgpbS
r5KxiZZsiKG1YmCYFp5FFKKoDGaQY9hnJc6+UJkZSoiJnnveeZimwfmVw7yE4WWjSB4a49CaYn9e
lkmrlzZKRiLfJrn9+QjIsyRO7NkoY7gVMGzpzd3GQY9Fkz4fT8vnCSxyyt1OrwjZ3JdxRZzoZOw3
UUlq/biISzrlGOZhPuBHotT/TBuCku70FMG6UI0SQ4+PDQZDq8h3Soyi6VM0uzLtd6K5GtLzUHbl
SCwxoVJWRjROoYGMJmQ5JnjfdCS51sQzJ3OPJ8S51Fhz7p+gVvMFuC286D5wrGwLf662Q81Dv8fj
qRKN6iFEMAyj/YQmyx9GTrGrLvog1HUNVGENEFpm5J2HjqJwiT4LcFEPRAvvDyL2MWscGMdYjhkh
L3B2n+ME24PluEEqStxX8G2VAJaYBhlLLwhYyFgOWfmYUeAihRiany3MsSazcwiwHt+SsnxXUAcn
ES5MtRkeRJBIRIO00k8emBzQZiQmhZkTQ+saJsz3EVIoTo0PpkNw6mZ8MZmb/UEoQq8sUAHxSfEo
FEY1LmrDHCHw59FR0y8C5EH3wSoFjlzLHRiWlNvUziUiAIEJLyoW7ERA9toPF5jzOMPIcBcjaW8U
akWyk1bsZqMOv1AxkordWiRmbX3HatwGX4BTcWcBeamQcQIKNbSiYYMhujF7pKFbc2IlIKGctiCl
A7HzCpaPd7K93OkmZBEoi3FMxgeV4cny+ELBMSydvGzwQGJKFNXsMvvfkinHkKtdSr4zKrYuEW7n
oqRQxBz7odDqlzPvEfGsnIpsgDRMKaz5Bp5CxMp0VlXGLaoI72iZ1oaJn/Oe9dlsIeMhRQRPQ1Cg
pYqHEImG3ABvCCcsEVCZRqbk+GBFSlVyqUILFldfyWrn8Sq5EqEFHSAQKXx0O7NvdexXfrU5wILt
npmQwYfUHtTYAge5qnDdY/Hyslfcu3VF3PW5C1qgzYudKjA6bprvjN6pHVsqGS50Kd2DIcJ1NOYF
i8EQQ6TTyag3jGJ5qP3cAMHB2KRLe5f2+XBDKGnSIGFxm8dYzE/jRDKmjO/kFd255oq0Y3fGfZEd
XcywQQwVnwzWMaEIgoUyKlezYjfQ2AwaZdqs3Lco7y2KppSxtQGYDVbp1RLbDXHGzaPhGc6ZrQSi
Jwbez6VVRVRC24WCJl374PrkYq6Mu6h4o2CiMl3M4zJBJSGa9zVORUrL4miYY1hQKs66plbZ4djD
970TT0eYJpEnpAopZFosmCMMd1gSy+fgE7ToLY5WCgwAfuwsouKG717NSF+kWWfJs+h2oces7Oks
QwLuPFT2CHiSM6yb+nlankUFiTUHNUApw/TZloRlVFFQ9hfJ4G9i/Jya+6FGtrO1hDAExZjKH3Ie
+1Cf2PCzN35K4SlEVwvpvTveHyWKsuz9X0+oocOP/8AhmgPnMiJi6UDUNEPJLTV4VpHFA55B07IL
8zKebWGbIsJcyw5ac767S7+Yl4mPRTdXyhtqEVWbu9x46HRZFJwxTyShPlBFXaH13ISK7mcnI0KB
RsEjdmy3rU6orI9HQjGOq2zoTBb6mx6WtEn7YFVv7jEocp7GzmShSv5cwam0yPbAymT64VQ5uBon
k3gLFFc8QVPhilr0a71wCNGibGdRjAQdLg7xk3V+bhJmYn4RHRA/3ChbsfJ4wBTlTB+rP7cGFwwq
ioe9ib2L8ICMhdp1eTmwDoc/zF6wRyefLnJ/38f3LsqsEcWDScuSJmVBGGiV+IdOzBInevWBJwy7
mI3pBU9WYfGS40CHOeUNeBALf4vAwt+8lPEYe5hO4aDNNWR2WKDwokjm8UCeFmrgaPOkSek1YAqn
o3YAUybXOwgSChe5M37bxRC7BxU3KtjWuOUyCWn+pOJGiPco1K5fxY2N6C3PB6d2rAy34wOswmze
3iaU5e6EjuFVF8tC92KNhyV1IxoMXg/RMOgPV+vAPZO9kjPcnoa/zpXJ9NKOlrJe8Sli84toVfjD
k6zYjd/x+mBq0V8Q4nAJbttZ1ku4seGVPQth+CfQNLwLwve8dgiK+qsPj1bgaaW7Ubu7KTKPg2U3
DiVgmGX30kdQ2HBCcxoSVzKCxivl//T2bq265Fhi4Hv9igN+c3/g0D0C44f2zGA3gwfj18Yk6aqy
KTyuNp3ZD0PT/31OaN2XluL79qnshkpqn71D0pK07jcxeWSt1BDmZUndSeD7HiY3dajAx/xlCvST
XHWeG+DOOJi1VZ1TNAQclUdZXgfoea2pwI7+HLO6JektZZNwp5Taet2zXSolVLhb1nHkTn4B9L9I
zrYxirI7vDpeFN2C+GKb/54LJ6a5YVxFVZa7KPhIMUMe0mQ3h84whNX69y9PvdpQm6uWFNI42c9w
qvXg4IUZ1IyT32Ak0Ndx9qZjLmyFnxZY4EWncZkSxX/XAb7j+T3i+9x9gn////3vA6oEql4CkbAz
z+lWD/+uxMh092F+x1RMgHgdoMPM/eCUKsuOQ2Y8tU0cZkAzzvydkVy4FELKqVDgM6Vg/JywY1S7
xROWe8KGE2aa8NAaA5xp5zgCp40lli+QbqAV3Jr9IsMtUi5N49ZzeUqYKh3Gt2oFYCtqlXyj8KFW
yXoVYf/gwMou6YL3Yl1Ck5rm9alFsl/k1Ml9xlOUpl9KOKBVB7oTuS3NGe+wlaxW/WpD0TFQFiQW
ZJtswOqFTcabmJr1diYHdWt0tQYem0RrjEC4szj8GuXya5zzB1oACH5dY0Z+iz0s8CWcIq3q6Se/
zOQzzygpRYMkRDFHc4r0+q5Y2xlrwhnTMuM0NSRN+yrrLAnOc06UPWiEF2OyktpV0om1PNuNeUkD
VRxQnM91ssoE/Dtn482AaRJNUxVIScdz2GU9z77kdQ4C5eafTUETTzP3U0z+sDvmFoCSID9EzTEN
pKHDOHTOOE330xQDQlWhnOwPdcxKFTOWDlNFL4Dx64nK00TzppHZVw4OgXsZ9GwT/rgr7tbJDP5l
75i5IFKcjftIjjfdswDRpWWW+/oOEcvJ3dMXZqoq3y/h7lRsaqWH7UTC/I/Kx1RU9U+bI5Lc+m6q
lDA7DObop5/jfJgDNGa8dLkvHaM7osOZuSJqHh3VUPModlHK44WbCco6AbDQusU+GJ+34/XghX6S
XxwlLqZxcamDImNHQxIiSnKdV9KVFw8sCbLAk6jqiA5dA//AGWXwkMHzCguJ93o5frbn1Kefg3yL
9Zy7/EBuJMhmoUkgAJhJL1vnOTYSDTQjmAeYfIax/YV2eYZULwBkXtIBBLgVxkoSX9aqAFYFSYJj
LtNwqcmf84tWmcRXpp6CS056UEuO7ZJNG0pSHXsa38u8NchTKZlWTjeiKZRhsIpXc24FtDQPwlh2
zUFC8EmyG+OAtTodby3As838xc9/miwYiZhhwlmVMkKjD3aF5cABp72zLpj8giQ1iwmGZ8nZEjX7
EBC6ZLtAdEMlTN76zjxk1IT1+vncaPQQqC2SJ4yrFVktcTCkZVu449boG9ME93ixZxcUelVrdnE4
q9nKVBJLU6vHZfLGpJJTk4pndaaFL1Z0+8FuCvjJlGK0iouXGXjqN6xQK8orkxeRnYBXt1QgtUPd
GBOla+JNB2q9PlYxQSBL9YK8/mm7e8NX3NjiRJO9Sw6wIBEmo9kkKFXElEy27mgWJvBZgDF+38cI
7H0FEzqa+AxysZ7W0+B7MXSm8tiruUJ0nNtaUPFCTCYzleljaglwaNrdUcQ2GtrtlJsx9ouxO21+
AoNbVCVG5t/mZBKVunEX+VSZaSAPAPiA6iAk0sErg1DKKuPVnmS1CZSnBeLUwXnxKg1KwxXtK4MV
gSw0o2GdhqoWLpIayOhfTSFLSTa4ZZLtO0ctOHVZ6GFkSZfsL6xXzyhCb6hZqjRg9JVE6IF33C7l
3c3GgykOeJVRlhWGJulj0E0eO0OqcLAsxZIZlAoMGlX44Zywcp1jVtlTJinRaeqkipmknYlLw2Bk
d9HIDFiC1lWeh3gNtpYKu/cqz6XyzO6tstcoS/mJdc0f4iJ0LCJPQQS+LZDwVCYpyR6VfYB8HfOW
r25W4Sw+KTgffq8o9qAaKuugvtvnafWGBN0uiFVWk74tbTiK2bGL5maWuXfCuXhRs70oCHUWEa2F
N3U7y70n686ldH4jZGmXzCbRJJzt4iQNmqV7iIwXOSUv9WEyFskzdeNc58uG3+DYY+GOoEBV8T51
5fEnjU7CLxSOP5iTVIZPMq9TllKHXp/no5iICOXGwod859UEGwr351BJEbgAqYhjTfcUnWZosZkl
5kqdDS5pu2J0aalI60r7YQ3KJA6CCGyHycgvfEIwFxaw6olV0Ebqg3TiFiDomXU9iJx8E+Fmg3Tw
mU3goHYD4QIiZBs0UeGcL4ksKDSuWoZWoUSu/5f5euSOSKSRCMu6liRKN0k/hP+ZEmuBRkIkmTBt
xuHOtaBKO/nsBLYgajA0OJGohZ/OVbV9Mnhnp83OSzoukJONr/JxJU1K1YhpALDZLgl+smCmqoNT
J9VBiaGs2U3tSvZmkyHI9YBzaF27pKA97GfDfOUdODzhYXJJxSsCscFC3tzbCEtWhlkLWcKdg+tu
YPJ0+EmpiOxmk2mpB7RVPW0tvOyY8FOTLc0U70DjZbpexp6Ga8bCMExHc2Vd4FK9YZDg3OzdFwAW
fTRA6jPhulbpEsFI3pLOJivUPmVKpKFmRsuAlV2bW16DWiKcuoCNOLNk7wmnUQBamqxA+fQcrYHc
GYjVH9kyv1nolkxjh8SLzElwFbWCiacVm88kNtTFpCeGHeREwJLtdXJAAhs11ARxzQTmTzlw3a60
OFpO6qMYAaCylVMA5P5OE76tHLa848zf1xwTEm5SMH+TwFS91yb9U4qbbA18Eygk+MMMqBsW0CSl
5M68TtMu5kPP8BsIduZXpnNvKjvicglghZExGQdCuQzLhIWLbJoXrlTpXCHsezd2RacX4UNRkgiK
hYpY54KycAanWw72mbjklOg9zZQH4R+HbBI9O9k0RKnSx6pyV788CyZxS4msKxQs8KuEwau5q6QK
YZvKj7/E8rsWoTTBFlUF+9wdrAXAZg8BZCZMonF3MSgZbXjJRu7HhxCcBgDRXzCNCDvgHEaBzBLV
BIJLBa/8JJBImyGghr1vAamb2y4q3Fmt3Vy1OZZFj28icOCgECso0QF7mbwKIkMR278kVXgsyUH2
gNheH+xqkKuSDCm5s2LiwKiUM1DTm00WDtYERrCJ16JJzz1rYpzG1XwYmQItNLriaE3JGgBpWiSp
49XpHjFk7JdXM9SqECpb8Y7wye2lQJaWy+gl+TTzNBHyXZM3JLZQ5xQTXs+cncJYn2yXLTFObGe1
w+YDdsPWpKZAanirKg+qh5SFZgPpnOBUMs+BW7idGlbQsscu2drrUlTCcrXnyZ8Cc1YcWxNoMduf
G5DSbACbedv8UrYnvQTAE1Yo4tBm4Qu0bCLazQpc4+yzZn8VT44YrIr8ihLD7MCZeHkU5HG8n+Ol
KkSJx5TXlGwk2ZviGFVbnPa4UjVpfZCs2Nh0bcwU2IZY62Wz8gsDOpAmlCSdEHD0eHHnMQP1gTgx
bJ0Q2PbF6PuJ1UP2SwC3qUP77Gy7DiGtM3BmT9rBvhtTMyDdD84uKa2SmB16oTOFdujEiyQDZpWw
ycBn0xtSAd8XHx6kwnbDjMknAi5aDXJJmM0Bh5NUY1oPcmqc+AGSOoPs825cHYk4dXsEBNk0AS4u
kbuZU8cjxnrjebSDTdy0WoC3dJmbuT+foDdkwYfAK5GT04iDS1pzGo+M+KAOb5Fl8WyiVw8OGC5j
Khe3vvMa6oCrlUa3MK6gXzfSLwsrRIXB5n6d4jkprFl0tsMPRn8poTtMNGa8LOAXB4sAMRAdMDCQ
RFlNpDx8X6QLwoMKdchZkRs7tczQp27twZJ1AVFVkSRJpc1t3QYWHQi+nOzFTReIjoH3X5MYF6l4
RwRg6JhflqQljgacKz1dSwphKFVaNAjnYSc/xCap3dGkwWIDPs10s5xO4XsjhVFns43GDtfdHjCU
lNT04t4ttga4WENduhcUiccklYJvTzPrIhMrJvhmIJnghA0NtyGp+kCmBOTbgNUfageoASTdq0V1
n3bbSsbJWG3KcBUV+TTN55JS1gsh1g200iq01ktZfGVe2EEXR7Zi6y8bwJJCFWHtqdsGw0NtUKWt
JlMd3dgPCcbftGLv7FMqxO3unKXD9ElQFkizTjcTAqOM/5SGPe+y+Hd8mrTfQFLRa8bZLK3IhCDA
ow4926nFIGK/NOC1ESRuxojEQu3cuI8UiOKkNuHddtKNMpu6eHRDCq5kE2yuNlNwymANe2E2jx2o
UlGtTMGbkgXkAmw0ie+lDe+xtOEImzot+gn1qT+VZ9C6FQ11ZqvMFxN6QWw6Z5JrMtKW21JLrLoD
/CwUkHqzpsSiqcE6hZO9jWpLDyQDXWW52+rwavgo87mmal8G3k9G4nAeyqR1/y5WS8Ko6xR6g5tr
qfYLIDBcaKHGOMb+7XpYVk41NNJgvxlPPuhX0Dn2FIX4pcwOkaeqDB6ik3QjUC5FWV1yfWwJNmWq
uhIq6YSvxF+z5mFSTPTULc7G0I1QD5GQqZmWVxeQL7jsb9dj4RMvFtDDASo2hjxJMJtMCqx1NbYg
d+MaqtQZ0rSBTV5KHeMaKJLgwD4HIL310s89U9rFtYT84drFQYHwCetBfl746MDDUBq/c8E16roM
AGRnJc6eQP1ValmCtu1nAJgUnWnAivSo6EbnNThe2e8HSY8FlKem+iqytKjeX10FaB3gwxjS8IRl
S7ZYtHRGTGnglVybxsoJfunMmPQ7wSy6vaSFFMTNfWCziR0kZd5n21SfPeGLOliVTSettIAq63Vp
9JVtjL3xCRak/Ckpa/IZRNUY5fn+DPPymzUBq4735ay90eoQ1aTS7qfZ/o+JAWzkvLz56zzPmtgn
CRUympk0aYXA1DBvhYuljHceAukKLFVrbfolw7MpxCw7tcpOVA02Ux1PYlfp5GpKQNV0gdVQJNcB
nO53JgN18FA1C2LhqscCVFA8m9K+Jm+xZOsdUYkeUtMu/fOH7kBDu2jUm4QrCwo8iUGvmoC0uwgX
CuzuVA1d0sn9TehaElgLHVJnp0GGO85W62IHtArRy3Yzb/cKqoUlomg0YnYZzA33U2+SmnZUu0dQ
dw+xWfEWy6uptJcEDcygWnVe9vSMMsWvBappIZF+GedRMy2GXJ96rqCcjKdTE7SEcUfaS6Z3X8hk
B9Wd7iq9chbiTdzvGnjWVKJnMj7sub+sS1Zl+tjNFN4MB5NFLDJHzeLrnZvgcq8mh68b/t6XMAG5
BW5+FfISvThmaJsKoyVfsRRNOGXX7z2skI+Lf8y65001ig8QjzxucV4Y0uhy3Fn3F78QMSboiZ1M
L3FHomMWOCi6Aie9zBKCewuH0BU/L2RgZwfikCdsRD21SWNgwZK6CypSk245xIEGOscI+PyCzggU
KhavFLGxGXo/gQIyWw+JlEB5tqFqvir5ppdxjitD7wz7HwjXF33hYK1vdtSidwySrm5Lg9IZ0gVc
aR52nmg+r6iifjg0Q6Pcnw5VeCf/hOOhZwN7Z4tyNgxR/9atm4zTflh9hFuep6HpqCqOLRXsLDex
c2GyWU3UnRNbt6levl2fztWh6oEOAjQnLsLPTHLJphzOoxngzK34wI6ghZAEqbeFdsJQG35PLcOS
zT4TC7QtXDKZX2VpEqCiNJlex4AGp1zIfECFSRJ18cIgm8J05SmivRbglgA2uz06/J60l4zMiWZH
f+a0WCaMOhftWJsjmP62VdQjUVhOm8Vi26iVrPNgLJVleqitK9qv9GrcfKulcCv7A82mhG5B3XsN
vddyLoWcvOiMKBCG6FR81IQtIYkUMgrVcVymz7DU1DjHIma3KRfMcBkMJ/80dfzBoqbqNmNEHk0k
ImX30It1M/CJ6Tic7NpEpZzsD869kBtm4kIh1Woe+ymngi4aEmRu9yoFXj0cVrNJCMs+6dBk86fE
Pg11ItMuo/6r3Pov6wcNpWF1exXdm8w+bMF/HPBLlbHYxAokVjCR5WQtoyuDl/aHYZaE0UOyiEjy
qdPJ4ubPZr1q3o3q9pkubIqM6JL5dBppwEP3nctFtWhL+i25pOMpxT0clHNnE4Dam0/3EOIQxPj5
C3HJVCalAloM+7tARmG5G2YBzIMqlEM1XX8UKYS8FHK45vgER7a69NL2tUv82zjTstR5kb9scphO
D/cUQ2Nc+ldU47minsYknZ+r0PHFkUHu7gQJS5TJVFQvLySUDrJnKA/hASc2EP2S8ujm1+T3laKP
ILq6uBPXY8LkaBtuzms5VZKG1qf2HQq69sanwy+HnuoNtsSdNwT35OmXqiatcjQ3ChSVOKJyLPFo
OvmFqz2aIq/fEF8aeBDzXxwm8cdS7It+ooRVljyD3tzhdqGpKJuFW6kQIpwKIeCdOKlwASGaZvRh
bpc5xSkeKeGEUIxNQqlioTo6WWYUFQ8Bw+SJ0SBxYDoTlYVbP01cLql0UurFNsOnjR++0y8qVdtR
8YIMucntjtU1magElLcDcuW+vEJ3iWroHJYoUENVAaTRVu0PmXupNsXJxkoLs0/YR1FciyquuIq6
3FvMSZIVMuvQyu8AnF8UqKknJ6iKTYyt5UVMS3IHyG3ud1BcWCLZjKLCsv/iZzH4ZYem2PdlavUy
8phEbHso/z6929nIr5EQmzpgTT7oD+KKSKruMVb+4IEt2+qLlXqTiysZ4Fdhw+Zyrw5L+cn3e0MF
98T9aEcaxiZv3CLT+fQu/6ReuVqBF/tTMv0tSlUKJFW+h86NVvlZZeKA9gmlC/SkmdeYjWWmlaCT
d4AG2sFqRbGFAkwTukJB3DHJBUcld3B2DkmV9ORhe+bzgqAoJ6DPiTaHaf6rYlFgDWm4xW6+VDVo
2kI7O5pILNDkhIJPC+sZ5dlnbM7+OtASQxEyAHUxY6valtUQ9e3AZsg7gUSqYl4Y1UuYg2R81v2y
LXokSm2U2SSeuHqKnFBNW14DC68zGKgiBDm4vKJtemn2QzvITJunerWB8iSy5Ayk3Xaajr6lZB4w
AqRhBbteWsqXgWlmU1e7f4nG0NwV7SijgtCU/UwZbLQTkKD01wtYfRMrA/nrjQqN+ilwHnpitbif
Ejg7jWzPwT44nbvMdLmEfQNZ1mCsKFPKHUgHogsM6Z4m0JFYOHSlBdC+OmAmZqYkQDR4BAjyFSTn
XO1pSFc8SbY5gk21Q7tCZqEuOLuxbzqYqcA8i2JIqKiVIelYRBLoMiVfOnTloJqHwjHIuQH15rKH
PldDKJzCKBs4ITFfOjsD/GAWTA1ususDlI6TcjBQGjRS1xMr7h3JeBBHQ94AmfUZSQJ3RVuQo1yo
JI+1lp8znwtROpAGdkC9+Te6q7Fj4l3BSgFUPP9OifbTcMy8iUImKZUekJWE7CJbciivxF0h1h0U
m/l96ifvctJvM98dZBHqC84f2+gjhcLh4qPxtmVfZc2W8crDjtpuIWVOHT3oSsh0/Qbu9eyz09JZ
YXBHSbZyc5rl/XM8XarOgCsGT6VYHcQqykB0HRYm+FRRZ597kJp0OLKC8BfuMChEILV7tdpcXwIe
D5TsqQvhr4KU3FAQTMrDWMZF+WBMTVumTDG5EoonnQhyx5a/cAVtt4VuM4ilYEGyayeXAcfTRMv5
1TV/mPu7OrshOAieT+ahWacuVbaahRcLRmXCqA4WpMZfaD05WWhHfILKdn8f1s8qTUqKVDuATMgF
r6M1vI6rYmLyTNHPGBJMwPWzDQvSo7YYmh72zro4qQv8gElmhXhbVb6keSMQdZ/riZ7T1N5l4wMz
XHjj56JzVmtuSKnpZerGZvgq8yL3kE5NNC5Mxe1s+2dxK5LNUCRbgOrVSqOt9lfiKCTVyIL8micG
m+lK7xV3hOu/aZuxXFIuyy6dTuB3usyE4fFU54FiyLArcydPspk6MXaJT5M9FgSv8LswKr+hWrv6
0pEujAZSe2x+yKryAcIzHgDqyJMnw4tIfZqwiY4c4MaEEoAKOncc7ME/Jb/PAlYNSz1NTN6WdUKi
GEeisAkNejoGgXkSmBlPNHfUCDu4DmYTPHqbVgAtzqrJa5NQU10mxUpIyVRFKkWkF0cvsLfJzeZ6
QUhP4qtDmGSaPaRmG7uOCuz9Qaf+xKVQy71DNFAPdXHG+xWeMpAhXP2EtA7qDYPgcEBjWgkYobsO
gvpgVEnYHQMQ4yD0nBgDZewn4mk6VKPM0xe1S8v8pJ9WV+7TxKmcE9oMSZ335Deos5tlJ9jgNCu1
HEgga4hVdkIapd1Rh632BK2EB7J6TV6yf0GaSpCXDvQA1fpAjnNUEhHzoG7dgaoRKU1sQplYPjaG
dqoWF+gox0uM0BhiedyRctwVzIeCufHrzuRkRrv3wKTY2X+0T9yspyIIcvR1StdKHXNVsHKHGnYf
pNINhHlMNPsE9kvV7xFmN8kGFyXyxplBEevGUgnuN+HbbtPYgpKOiRx1qLxWEg6JuvilzgxntgMG
m6ziJUwqhB8XxGmq+tCEJ103fTEW8S6GDhtW69/Fl5J4R9BxFHKhEiKaZJ7UoqI6ktWcqfpZbmb2
50N780Bdm9WYdCilLCvKTYdtwSPN1uAF6XQpx3TOoohwaj56gxCKmTRJDJl45Xx0EERMxeI4pWl2
zIqnYCCb5Nja/YIymGNeZuerOeg1y5RwOVXqpdoOqA52+GDGoV9I6uqOu8pbYUUzkzGTEjfmhlwC
DJmZ5KDG9fyF3L0o6fCAelaHg2aYqJgr+OBosvlq2KIHYg2qoElaqLMFlohGEzKkDsCbjtnkWWE/
BeiSuRD1SDvqkngj1Jg+0UaKuoesNtKswWLUBsoBaMuTAtm2QWpNyTZoN1R0DvShHsObHqaDTeeK
p50wzVYdRVEOSUm1b6JKF46KaPMQe5hNHfDEHzbblyw41ilL0TV6be2yZ18fhJK0GZXnaGw6GBKk
wBO3O7OyQagzvUk9WEMfEnfcq3LF7F+8XuCGHmS0bG+WnOfSoKwvKfrDPDYnCR3TGTtvKcs73ZVc
tUIQE6+Fu9yJCKljdy2j39HVsYv/IDaZpXFeR/44rYKOTCWR1T2EBNulwqtj0SGHcdZC5t48pVOc
iuphskG8+X4bfFo5+dAZM6kydlJyQh4v22Igk0qCAfEErmd+1nwaRx3vLtqSeipH5fh1+6LwSYpJ
5Z1UMLRIA7hDhlD+TrVYhXLA0FdM/UwQ/bC3IdkQr2bisygNEtUkHGhpT1UvS8x3avrphS0kaHtd
uehNeQi/JCs9whIiW8KcvUE95nFfFfsOzH+drA0dipJmxa68oUagZwKdAh8aeqi+vqGvGnoyrkPo
JZ8LHnUEDaiBzX8AnUz7B+RRmq3UJ151BXy1wN/x1YxlFenkgAyagkl8uyKAZw7bRcI3YWW1E7by
sCfw7IYuPoQYjrhww8rpZ2wHil7UAslVjkknuAekCESuaQHCnWRxwhVJ1askjJGH3z7aCy0c2hCo
78S9E7WivMzr2PAGs3DfnAl9oDKhEfqIep1bVdYJ4ATqhYlNF8qFv23WCpY/ZDFOOxE+xDhFLS92
BuEDrQkbyV9o81b69Q3xMG0rUhoMcSFhXZACc0P/GYI72DXEqmUuDCSWG1QpH5V0NqT9/BI/Ehm4
nTjeLATm2AQAK90CIfJWGdhKcmfef55sZ8oizKlNRYOdmdUQ88kU+sB9VCwbrTPa0pR9D2yySTnd
vRtqZpxm+/0D87zENQu5eWoXqWTy1dNZTx6MwHASAGeQUGcuuNeEvgLWKJFVJC6HIcmgdyLBOfJc
Tj+mlMhCC3PYQkVj7YIFAAiwzE6mU6DJe70zk0WIXnYJICdOEUTP3mDYK1nrVN96AALDZi7l0kzK
iknolNSggn0JRzrUQbfKBsgVgD06uUsRyzA0JU3JO7vXTuIFfPBY21JIkePxGc+fucippFwT6ImN
8DboZbjJSYp+BrM2ypvE32U2oKpsZ0w37kXSVcQjgmaLHyFV5nqR9ZeYuTbU/7DRclERr/lRp2zv
hNkbacb6sPa5qi4wmNGF+uGNOtOUUUCfjPbIZzAFAMgqq2MtkqdHXWOkfawFHUuIXicLgc5cH7lr
uh9RmIKp0f6xxb9AXyDtE5VJ8CJMSdoF/IrKwQyqE84m1pcRbElmNC0OpWkjwV9I9aaKUNRMm2yO
gzCY9ITPFlwUS8YnsalAaVxcfAQekCzAnybObUEuOp1hiPqKfUyoow4ZA4kZN7qEBtB11TnxlJSa
mN2ceJ6NXcusHEhOYG7M6hX0VwZTohPsg9LVXxwhbsb9eWDCfabUWTr1k9SBwoWanYQwE+yJ/lfs
6M3AtmIq4TPLpVI4ijC5wQGJcwj9JZFYVH2aMIrjpRvym4RmwPUDVQZ8TTQBkgHcrOfMpiBA4KOh
IGoKOzID3jnKj8matRPCgEydMN+Fr8QHKmfK2TYm2AQe3fd4cZ0sPxp2SnoIPIoBRDc1DvDiDTHB
oIr1PtCsQOkclcP4ifYXoCqW5psXk6xyVSg6MyEmnmCta8qcJ5IJsIsYRc+ki7aTldxr9qNPyjJE
wDr09Kd4OoQI+ss4yxg0ULqpa8i8wwMtAAnBJdJSdfubRKropOBMcbEu3skC3LbikyFTw7hOjten
mWudyQuT8TXNBObhpeqWT5Vuz9nhGRbFGuSqedWpfKmDH2HBCHcqzB9VaxSzkVwlyQV93QcqAgf5
QuEJqX6iezdjbTdmTxW2SQo1y9QJrgI7JBvoojJghRk23Ci9t3PeQJKilJMjPckk31+0j0Q9M5oE
KWQf9IbWkVF+0ibwnSa7jZMLDzE5nHYAWeGUs4XZipjDQc0Mu6KLxBk5GWoKsOSkVPIlZ1SDOzd4
QeNx8JuZuJ9M7fSmjTZx9JzstYMXndAXGSv1SOV0VCIHNEFSB1avM10wo+tGDt9PRzVEYAWHSLdg
CTGbgxei+s0rRsMUafCDT8fkzCFrYCdRBhmZZEPloHYFL+oWueia+oLZvTgNMciqOqs6aJGLAc0R
zBBbzeKwSS/wDhxoBYAt3vE4E+bkHkpphHyOO3YLmi6+0swJPh2EjtlZkdQacMK0F9eCSy0WdTU5
lATgzldlwbHEMRXwJJeCVgsg4GReiNC2nVZqus2B6yM303fP6Uk9UBND/aBRbhawYWlAU1kdRceA
/sMgiU/7S+LwMC0DrE2bSFko8PgZpAvAJVJrlc4N1qYLcja3mPx4DFDdJgVeaB5hnslBtH8IBpVi
MjTRZURhHyaGJLXRqYklUFiM0AVe0rWRsusquaFAXcLABRR/Nv2W2tzFdK6Nk87/AjxVBs+FMdaE
TbGGqoNsZjPyBsTFtRBYKD5dKJwMAfYX4BB3eZkJ3Re8xHGg3ptuDovnCu+waXsindzPFR81S8a/
2N3rz41LcLKcVYGeFZjIQQhehwZu9p47m061mCYfQAhoi4znIJUzQTNV8utUQkaQxBgh4IyoUlyi
vG2eVMSZgFAjt8nTlmDsHRpnZz8O6LZVDrCUgM7u5b+f9LTPTgKOQIViNlNsTqmbVJgoacXNll3n
xHmqMxGHmpZAKXWab12RiTQIykS1mGk+d3omAnHy9Wl5NWWBJDK/VHJSVb1luTA4qW64nYIsSald
jZRW0la6PBQCUCV86AHJ/IIUpISNRpLK6MXitrL670/1DpGq3k4CE0bABrZ7SgxeIc0v00t+HeiT
AAS3/RSC8zgRQEnVHQiYh8cmE0pEGDuYcjPpIuZ6Nr2AuoAM0N4X1qZ5O07/FOUM7feBSfwova+p
cx8ND5EybZMq6nVNpIrt18qpYXKpWTgl94rL5tkjzq2BPEZiAze/7BP6fqnmlPaxKXgRqWI7EvQK
0nbOhp69gjiSXt1UkIKKRlvULXiSTbI1NzVUNiO7YJtK7LeN4BKkYiV6EipPvOi32ZPcWzfQEkR2
A3QHIn0qHC+q2sxs83eI1auuqXwnWJYvhaaDDQXVOjTxxWi53dRz40Yw39dyHlpwlW7aJrk9gDCe
mtJxwR64Hglp4pK32bRi122hp+0/o0JKDRlc5sItCrdkNqbHK/kWtdIBtJCITvDyGQjBop/J4z6F
aneTB1VQNcjQy6TmHaQQopdN34vZXNOPVSV2mFAEhCNHFBdK/AIDXkrQhoncxoW31LToxGZgnFoC
+ykXyCPYUkbSmYI0Z/JQDPEI6X6VttnVqV66GrCjZm4mKwKsKrCfgxIMxejYl8ANcrU3adrY58DY
YEaXeNWvr1X9YAQEIuEWM2k10IUjzzR2VBmGrkvIRqHh2vJ0ImVVl+UPyfwH2ozcRcEXjbG53il8
eZ8SINRFHuFMIZfiW/FIaRt1goMw+OTsk3sCAZasgmDpxT4VuANdKanA4z5GkC6E14jiH/pJqzKU
jAkRlSyb8cp0QydtjjUJ1IlPDMnJtopy/JECO9vaTKI/3baqLsNlP0MixwjxtWH4GgRPIFpZqLqW
cEmcReDYasBehnxySvA2oXXPqTtN70faaJzab5pVt8ETWxLOXU2ujRtrLzJhkzAqXe/DrWbt2yNw
XireekjhAFbJgE4jhi6VjGJAMme8u6r3cukuiPK6R1Wd1aAlL5kvjbeBWn2iN8jh5VxkweyMS/xK
BUlXZSwWynLKB76wnDC0T2X54ITqF2oZSEFTzOfCNSnYN3m5pLa2OJG+oq2yXneJZTyfeMPq00w7
oTJWjoGT16aKTdisIpQJI+ugDdi2APlA8OsCvmo1Im++tMLgnmyzpYKolOuimk12fthWAl0VGCUo
8R4YwBovivFkiLB17lyOKQqZE5mV6Vzsg5ZFDvb2wZwnQ3o0ulzq14tev9yUq8ZroaCpVNSxXteL
y/IVcKz9dHTbnjJjxzdNGGB5PgSyP6AIqYteVonHHeTnFQPGbLpCzm5Gg48jXmjoGh8yRTuLgi4d
Ej/xsMkTWmC0zdKWKooXF51kasZRUb43o7BWEmbgpzwLQZpVbnTWZ8cCsyC4HE+nNBHdQLBen0Kc
Fbp36jeSKX5BGk+mDCv2RxxouFASGEHTFLysKGZlMVT6Q6FCDGZ4p4UVUNWcLrK0Az38+Ix3ASs0
YzZGkiR7wsDqoLrwECsO0cfdOWnDtPDkd2Ww1yrbDu76C6TMUL4JZ71DWbtei6oPuyK0qcdQnhdG
ZpDyMbLM5TFSujKvBMn5VNnQJwYvpto8hV81m80UtMacRxa8lJ0rAIAL41QPsUqZVmdvLZzAmdkI
oalyw/gA9IQzd0MIkjG2UISnvXIESsdWbmtryNqwGvnA9U8USgJNoUxWuIIhr1krfE0qYTlLPhKD
c6nfa8d+o35NoJtNKI9J16ByrwdT5t3MMEg/FBiXWq2q1aqqWAUo0H1OpICAcAMsA8R0aVxE2Ywv
/DB6w3PJxGwmKfWuAENrV8NGf8oLbIqHDaI6sppA6x8C14lErLL5K+1QQJp+23EYiAQcypHvUhOr
4MhkvZ7Be9nQszlRhiFka5xscNKFQSLcTe7jksIigWYo9GlLeagC5uDIGjfOPl1f/ELtV5C6AKbJ
mSEBjzhFhbol4OC1UNTrgFotAY5wGOuwOpMhl0ALgENmAVwJD61w5bCBTt8JvK93UC/3WeqPKsPM
AWxWV5RxmMF1qQ1wQI8GKJTCk+p0gYMjR0kj+ay3m5pUJW2CYTkPt1bmrNXjNfQJkXiEEn7oBKA1
tUOhunTdU5xywjQmW8yHJhySCJy9J9AJHTJJaF7dKBuL6j+p0Kpq3qbfKjRPEsGTLTF0KJYyRSho
xpw0gBexb43wnBlLJbZV3WlxUOknng088zK5hHnClfSpaaDS0NrUNRwVmsJzTnfBbgBioKpjGnJ3
wK+wVAA4txILBoqKt4A9DHy5O3gQDkYzSbwhMIrCIXmoY4iIm1is4OAr0vbLhYcBQTOSBbrzQa66
Os/oTNRZJu0XzX5RLGCERACceHa3GrTW0ChRXjp7xa11MkvJzW+QC3AS+SsyVRfmrsmhaDskWkXF
mJtGKqLoTriUcpPbq1nPrSIF1+HnHmZu3gFU/RsGmJSKhfMkw9DGCmZjJGP+VaUHLe70EDIC5Do0
NMQt7uc5uILuJCTU1c9IB4ejA8wgOdRj8YUrFwpbkUni1YOLtdOBOeFKtFViooykMiebIt3BBu2l
Dki1S3xaRv/I0nwHpyyctU/ZMNTTp3K9QoMMxavZSdlHajdeuXJBZqTWvdxk/eKspiaCCvi91Wlg
0tqVeKkI4OAK+vaaN3cNIpiJMU25YqrT7nHaYV0dZtpB4pJUq0toP3U2obiMbiz3Vbv6oqnpqYTn
PDiJBZUtgpH22leYYVI8UTsvtdcblyCBnVe5TFjxwXmbsoPpLDpd0/RPZrl/mm8o3arEmweHH2iY
hUrO8P/PxnYTyNtE5gEfKGV5m7nJLwSKzCUFHdJMEbLyo6m9bVPogTazxEm5zvWW7GxFwGUN1g2K
M1OGAbRxQQbPMiiV745DHiFgpCuoeQpVVxBLm9BMhIdJjBpVlSFQ9CvyvS2gdLaKcg5siWam6F2P
70xzQ6UoyXjWKswUQ0/R7BQH90fOTheuyrLAibQSfiDOzJMFdnKcAY/qJIlhiktPkR0s5MU0xu+g
9LnWsBvAoec47JGmg3Ueymu3Wqs0KxxJn4vMow3DiaNdteq4DGsYWSOIn6IqP2Q3405A8/PCdlOy
BXAfGCdhi4bKAxOTFC/ilojgdIDXgg00fnCTKKjbvC4htstw3IKOkmuZQ+wLvfZwdNFlXONHQCp3
qdHcOB8OCRXc2PAlcyckwxnSIgvQcXjTYPJjOoYCvdTDMWoAiKBVWcPvi/o+KeMsuaFjXaqo/aAL
aXwyoGOzOBpw8+1u1GMFn8pdH4dqK5CoznoMbvTAxFh2EGQVBMF0pwvVgUHNWgpx25GXaQZVUx2m
a2i/Gck//dvf/dXv/uqXX3/+9U+///b7v/vzL79++4fz2//803/7+af//fOf//T7n375+Q8//eHn
X3/+2//67d99+0dI+22NrqUBP6mUfz9/zPB7zsk/Dvlgdr2apZMZf+LvB37y/QLnL2vnRPgiLQHn
IJyJJ216qW7ai1POswyWFYtasUtSF4QDDw4HRitSMv11rguqrlSwKi+YaNTQC1bp2MVeBbcyD2wA
AyWSp6IcEWqD+DX9f1WjqLCWTidLXXPlmiGqAbnbV/FIqX/GhIj0OBRxgaIxFAuualv8LR5SUqUG
qalJk/kwqZfeoF9kU6dGhaB8RYc7Mz2w6uNebve84u1Lx76szjO5ezA4RlNRiNskt/fdDZrhFkUr
Yczpx1Dh2hng5iV7Jtx0NHQX3F46Fwu1G6p+KOHoLqN5h8Wdr+EKZ1M3SRmf83fg9dIc4WzLDejY
vdu+WkHyCfSIZHcAnu6GpY1zZLEYU3UeNbO65L42+y4BLuQk2Hlmg8gOsw51SzyakTLFSJk9ORM1
CHfmKbLBw6pGyseMese6Hh/okOY9xK+DGdTh5B3RZULbcTnMSEIhchqErlg9eAbH2PVvuuNTmX4Y
p1uOADwJIdUAvD0a4znisNxYQLazzCmGXdacaOOzYeTMww3UXKiFS/GI7naYA8LMl9reMOiRdK/S
YB36YbSV0RZPNuUQqEg0uG/d9HTlo9rp+cRO4VWyTPKjRJswR+3JbBmo2wI8Sg0emU6WfKw25Jf7
sY79pdgDkHk7K0YZk66sGoUL1uZ5sMyVRUiIkmUezjaKEnxcc8BxuhQNrrMbBnpavtFfVqMzK3TP
z5S6cAuiolaIdJIqp+gXWKRHVuhSRfTzvCLZWdZWq9bh4HPF+w/ZgexHWCff3RkoBGVsuBWkOtZ1
Q/Zbmjkp1lJWbraQB51jEVV71WfKs0qK6FnaRrqOLQVUVmjjg06QFGmv5UaXFhBZcZyvKNV1OdaQ
VxbFH0U3COihfWVmZg2lyg7bFnOaXOC1wQm9RIlwzw7rdofL1I4eQj1H39mKd5GtwUsth4Tr7dSp
0mJlOqS4ZaUFhaj7iL/ranhfM5wgWZVpObVgEa1Ag1dmex8L49FgnREd6mUCEhSK/2Aph8pD8ZMr
5CdCTaeiiGDia9lDcrzkCpBpx6GapfgzYOSfcXGnXvAZDscz4uXeyaOsMN7pY9FK8vElEvtmMJc6
pyzt4IywK2fI8eTgr0gL0HJ6iPGwc7oUVv01DwzWmBdU2O+DStr8yc9LEuIUHOuOxHjEgGl5dPEa
VvFUqPhbPWS13pfvRG0gbbX3hVk69CHA+jAfLdJPfcf43j2+q48WC08d2wKeMl3Ug19Gl9NDLjvE
K9E1uW897SkeQ8Lh88FetZABOztCjSLMjAf2N8vp06ifDKXdOb34QFT7aOHrC+CKKMpfG2hHaUjL
w1BqN7LRv96MfnPAwaU6H+QXR4dY+IS2brm3qH7uvSIBxS3kSWzafh/Z1PWB7iMNc8Ny7mBLD9xp
z6OehqTtfvWB7nhzRyMlUmDth6fyrDE7WWXfvcEzOL/jUWCKWSZWbRZRUQK1WestOdAwinJ4kkCz
khM6DVqpWa4HA7GyTzdQjJpxELbFxZXVE4kWk9BXgOa21+tE0DqDXakkl9IsvA2qPfpdmE6gnmaW
founSw0s4Qa6XSQH4kz00szAVyX9Lkfr2n5a9HrtzAyNhsUJcq1e5NLMnCkHps4wATHRwDQfaZuI
QunOOZEXF9t+GYps8bhFC24BPTS7wb6Z3iJ4ezK439u3YL2HluEyc2x9av6ZQ07YtLkGJPhFE7pZ
x3azB/Rol8OTB9t5NTJ/6B159jIARZzhWpHJE5uB9cmEth4NZ92ONRrjmesPuXnImlIcxii15dnv
9nU3Fu6GpPziVjwkxfO9J65vZO65hrpUHE5xg7KzoUPv4Wl4WNXwWiFaTCBVu9yfrehqKnrbxjes
JEEOlGw/o46U8b0unknt2nahKuz2tvgHK1vtQ739vfp1kpLHl4vaXRFR1Wq8MtRCW0mxNeCQtIZF
Pn4W8Dl0zNeYBRdIiNExsOrl32EMaSuMpsZ0rjZ/vWyPgGyd8zRlxibrM8/kCFAujAdFCnJWuHlF
kSqvw5ZA3kgEyYXOtiEXCZ2dPg0lK/xbI2AbT3oUdn4KQ0qcKus4N3k2OPgZRD7zc6B+Gao9u2V7
HtXFgn2MP47knoE3LSWlnel4bF1j03HY3kKmQtp7dgys89wOjENPx04KPof+d96CfGzSC6irgAkC
SDJCW6X65a4XqUFWaBuptk//WPIydIbREl8m0cAZGlGIufstqSQRA57RO9rG1bqMDv2tkWSQkc+h
/uU8OSfmOtZQQ/JGmGFSnIRzeYoBj4VNEML1riPeWbE6e6jGrSlSygi5XARBZ2nIQE8II0rvSiqn
rCv8VezJp51xr63DaR0pTL46oqy1faQnu4QrlWRztfU8r924bFLs8qJD9MjexhuUSNwGN5sSa3Zw
e+mR2e62qhFdi2PJWWoma9KG3LMauuZZrnmZOWA/mN7JSVl5lq5gBugH+aP/65f/EeWP7v7DThUY
6U7kX8W2serDix56RH2D/p5KknH3cnosn1YeMhob6XEhQxFnYBtq4iG/z2pO+S30yJQBnVqQH/qr
hP1W7Up3iX8jZ/RVo09yUsZXO6Bp07Qi2yGGE45L0JKO/1Kxw1MDeJJMW+DfYC/Q+TRZIWM7rQET
07MejDZJ6fWJZqfFKszQjvX772wcFm7UchMODdv/Qk9QRDzo72LAvrnTILip+y2dZVfnwCVakxbs
JBc1++Tc0+E2mCVJGNtn0TOIdqahVyT/sQWL1yoWFKFlfXvUrgtzhdSpntTAutGvaKasAYUZ9RGc
zPzNKJb7vLCDWxNBqetGw6NNg5YF5as93NDTNLKvE5tb4rR+zoIMgXi/ovt6KV5RI1rxd5KE7YSX
CoRTqVV7fOEpWkEuta2XmgQNV3rh5cpYP5bPKqHZIgbUhTKrQXa5AsxjaX8x+a338GN3e8m1zpcW
3c0KawTeBCd4KjZp7pYZ5O5eNWyQgW8Okd8NrBHIikSFv5aV5aTOR5NldGFt3TCUTtb+kNuXu6zu
kHN3G3y8S0HRN6T6I3fZiDgfLzAYK1I8CS65e2hWGBQHOTXs+pCe63sm3RSPgQtxPJwYdoACeZ2e
/MONBDJNjH9c0SM/3F61PD+zeHac6WzMVbTsFNp/RhxQYr7E438EcapSmvY83RwxoYv9XOgv79mY
LE3bM16AD7CnvMee7kRvNvK9PiCNRQlauBt+orR9ejJxODAGq2gckxSsGE4TvZ8N+pyJ7BBBuQJ+
A1zYIQIxSxDwTRUZKd3yL0KLFSdIilAyRvDpe5S4BIAW3H8TLaUUL+FbxH2a3oxWHqpTG8yul3NV
to/iZ0PchDLDJTAqcHuo3pAjmxboVX5OB78wJVZbXcgvvhtxIW2wTO2qqJkhT1YmaKslthEN73SW
pKzOYWa1VqBcWm476OdHp7Izs0WTrJZVFAzcYzANav5zPGrLtXyNyp2pe6PM9TnrTO/phJAjIhTN
RDPogqEFWv3fyBqlGZfTYUJThjIbSerQmlYOsLaJrN2i1XMLQHWUk/yPCbRZogiNXVUUXfQjWPNR
MExOt5FyaH+hwMgVJUTzp6d8GiWya7O77Lpg/wMCBTZuNbexMSZGhEML6NdytiAjqlP51z2X+NeO
QWZnDVaDc/GC6QcYSorhbQuQKjIrfN6t30Jw9Y8b1kBBXL5i8YYrB4+izRphBqsY1kTrkTz2vEgq
QEN00erERh3MK6mLybuodLTBkCdm+TJH11mGvsOcPuGK0JnPcMPkMNq40ZSDrK7nr61OfoBFYFud
du8HuHmL8Mfi3GDe9SZOkcUsqeqiDAfLxS/nHSllOHiTOzB48/BYVCKjTmewwbzBFZzy+3MVpQnD
Z26WwPOalDPU+Gn3t4CtpoYyAzU4VflmgV1GR8CjRJ3QvocdGmg9Wz5VqJDKsg1ziHl7fuZWMGmK
9V53hvFFJOdI6BYKT6TOVwpn9ZGd+55SQEJvBJjh0KSIxqA+TZyaZZKP++TB3le/w7fAvZ4Pu/Ps
GN6KxOx5jYl5MVraAoGuMdqRspqL8POtdA1UPkHkL1wy9lb8BKeztv3MiOYmTWlLisxEWcLslPmA
Dh85++JvusRv0Oh5FMNZ2gaPPAp67pfOB66uKN4zditvyoqMi3dLfMlbJmgiH5o3n5TZdlLYyhro
eUtw7lgdA6OC7A9YJJ5eJHvX22Dba6ya094Se1I4RAWvoZqBf7zcHc43prQOdqpFLUtUxpUxbZNa
yvJ0i/RVB+dyoDesbMA6z9Wt6wGnusNljjDa+Wa502+jrcNKbFprT+gC1XDzsjqVVK5bM+pZOsLQ
qdAk9pLRIFsAVjlv8GpBi7yaGfoSp1kNruvFu1UNyV6RVZI2CniWPViOpezOXbhqow6eemPK6uAL
5GUNgWnf67m6y4NwrCOVU8NVojOX4c15s8fqFDwVAjwKytgyDPBaq4WngeiKkO00a6vzPNeAmQE2
iCaVHRWekSkWmFOzL7yjEguZwZkeM0HPp4LQ3xWGcFsEuYmvwnRC15ZCSjS+HdI4y11tiD7iXq4e
EYhr6H5N15MnJhQzVsKIq2LFcc35hZVFFrrikaQnHCS2ixanRqfniZUFb3yjqzAyLo4Wasb5KbIq
oZpVlDlOlLxiHTqGbPqKCAgsu3+tfiAY9t6Pa5VJYbunE/Dl4XJMuDvehg22h9emBIzmn/ZIk6fv
8rCNtlBOBCRvcOfb2RGiOe8nwZIWwQIHmlWqlZMrwkz9u3wUj9I+PnO2kSeMNJjytL9Dvu8hK7Bk
Tgmu0cnPDD/7acD2UnpjrUkWS15ga4eag4yWrfG9LOysEDefsagU0iy+1/ZwoJ78Y0Bs9L/6Pxtn
4SMmGn3vjA2VtwEZ2YGmwScZ0TbBIb6vdzKDDCLpaOgCx08yY3jPwRP966i3cU7SHEW0bCVNHl2d
SiM5oi+1UcZk3YO0vbTklwbX0/3NOo+ehLKUo7C40Q9I0Fy+StkdpQ7UKfz8WN7IRvKaCBNaxd7T
aRI4vM7BFrx00VOiaPkuuvfk9Cx+YfELCFfWPdflWBYsRGOGEDSgwcVkWXAku6MNsHaRXErHbk7L
FagsSC7s8ZT1lJ0FyxQ/Ine2lW869aU6bF7NpO0V4RU2p7QrqnkkGSvwuvo4MmPJhpDrRXhK5JgL
k4ziOyi7g6reGVotJmThPHst0K3UHo1FosGNg6oa3M7mYJVOnprh5ibhwW5H+UKXUxRNKt5M/kQe
inPOxP+tQ9CzzgV7AqTuH8lfehz+DPzSzC4t49p4A4tzp63sFd+i34vW7gRYsfyi7aOBVijZSowl
M7Jt5KxVm96J2BxwVLGqI0HbwzxNJ079fW2SwJldQv/5j4RsjbVDc8aqujSlyLpDjvaBwK1RTnnZ
XWaQZtIWS/BxB4GbWWdKBFMoFHMU0fZSWUm3GFGf2Kw9ocYiydssbzzIzW9yexBtCWsQB905Y3Zu
A53CZ13KxllRrSuvunDu/r6iW7Fy3bmXNgYiPItrd+ezGKzWucrzFoNjb2UjACMHXHSebSvnN4Tj
HD8lClgFVkOLbmvj1SubJNsc48Pe1bSjOL8dm2Fs8+0Wt7fWEyOkxZDdmiKUXzuMl1bJHiR9kUpA
hezaeHr2J09xpI1lXhTUCpJhA4I2TOK3uKCiTYCrEfI9WX+LJ5ITk3aJq8LOQt3/rVs3cpQ8qAyN
VQqfRbgxn3Pk9lIHhHd5bsQ9HanRF5SLd8ReIDNV3wQAspFXTiKtKf8Lvql9tPfsPTutVXL/FyXt
oc7vi05fAbYLhOoGV87krt0pmm3DfKoVINrTHvnqz800LWLrYT2GFRUWBYNCr0VTahH0EX92H3r2
S7EPixePsXhmZCUwMeqTdzmy4zcYhr86A09x8RRpq7yCIL12xJSoMk7LhOWK6l5XjeUYiXjpOJIs
E1zSC59R/x2dklCqj1TzlneXeMHA90obfFsyrFlBiHlRMuxKZhQb6F5XjD0Fj6kLXsCMoNiF1guR
KZqluDpMRCUbnnsgV62lmRKph4DN7sRdYngL4+VEgCCCNqKvGAOsfrlgIrtSRFUy8VFd05PMt3Rl
EvPPNaFJoQqld1v28Wjen4FM9h9rq8WXJZSwJNcnbESV8zuldUkqXOt0bHKCD02FdPgk+FGJCSNX
9bmmJn+tbGepxl+wOFb0d9x41QqwAN+SLL13tOsukNJjX4W8XHQQZCkbkrcccCMqmiWq+NrankMo
pm0CeW+Vhsj+Xo05j/3aUnpGsvwmMv2AOKowdElPCRX3yVc3NNMixLKcXF2mxI/XdKi0J/g40rdj
6Mq40IVe2LyofRbwjsPWbyW/hD5WlOghmvlJdkso95RNsv0gTfpJnanhse90BOFoq+smH1LGK3bO
E+kviUIL9tAbE2dwhCuffvhmE3soazS3anb3uFwoL6wIb28kRVSlUNbs3c/Fv61M0gFpHWixuRFx
0pZVSEYg4kM2RV2+ThFIW/nv8uQ/E/kbFtt8ONcGK8pWdd/0gvGUOTb8JkgiDvxHQWbRhxWE3g8b
mBFPMq/9xYJfcqgiRcJXtgXIkN/bbzVg2o++gPK+Q1PZReQ9w/D1sgH7PnZyI++UgHObEmMTHJ6l
zqoiHm57T15cb5dtsLJHzPBBr98RfaTCLB6D9gn2RyfrATBuka0sVwnJW5q0V9AOchZGSl1TL7RK
9JG6sRVjijxUm62a9dinublYUtsnGV2rAK7vObVfV7zZeavXr1OfyyGul1Ci4ItmaJGUbe95c3FS
99nOX+pzS9TVI/2w0NWdf7SnMEUdvx5FcBT2iVwvHoc1i7l2iL+VsyVszbg10E6znK3zaF/j4u3D
g7+fhX3flyJHJS8/JouFJMonlT5bRvv0VxeANDgxHgV4DoPa1jPr7eVOiBPpaZ/cVdFdMj+UuwK7
lhLN+9lcz7v3FP2B5rakqLyTA6ulTWXg70UuUWD7APnyg/QN+fWSweEDyD8uc9P22lWdTZyeEgpe
dQXvpC91mFpZDaznDOGdqQSi9DF13yZvjqh6/N7f2MnSHJDU9ajipvRETl2uj9LDh2bGQZ6wkf3n
XmZuXNTv2Gf+gKj6D7HPjcR8jknU2BJ7kJy2b+7nwlM/8fnAqYtzYWlmVjdyM4iRbhL9t85Co9Ef
H4rKT0XqY5cf1zX3Ua6Wx+y4j23cp0juj8vVnVBdFnyQqzrI/SSVYz+Urhz/gkq09Vw9i1krjP4F
xOxS5vXPKWYz9wR+ErMLzf6wmN0UIf4WYjaki/OpwesPClyLjyR1TQUQSne6h7dCF9vULeI2B2WE
unS2OVXwS6J2lx/3KGqb2H+m2nSsuYumwPrJPq8fGZzj0xaIv4nQdfw6L42T67ZN/LvahVXPFA/M
b2S9vhfA6gYfOzkrvhYGOTwx6Qzpqm5GNyHOv53M3Q+J879z0Pb9nfjNH0neKJXiE8k7flToah9v
JHT7NkgQEMe5l7TyhMdnls0XJesU83vz9nzkVflDcfoJYEtuWLYZKGXJqX0rWPP+VJeej/mtjA16
YDzI2EDAWiXmt5axK05AhvvneO98m1m6HYX5fu5OYg9FIGf7s3Hb1w5Ww7M43aAp5px5K32XSMiH
Rm6T/mGmGKHoJm9RddUTla3it65Z9f9ilu4PCN1N5t7qzo7ScRY91Ovz24BtHOA6l5R3C5lptGyi
00Eyf9tbDQ9d1J7zJVN8LE82WH0fE8g+k+K3lKtP/NX2NgiTCDcGW3s2ZsMkYaSG/lGAtmm5muPk
nkfL1dKedWt84B1eXKS7fI/DJr79oHi18dlPgrOO9orPrBQ35Mc5eM8y13tgPrJrQ5n7nEbNJP9F
6ls01S8H600FW32jV+67HX94hd0ErbppDBT7Pupjx/X8aCOaBoy+HE9ujCvg3kjlthK/wp29TvjO
D/2sRTvuVNesXSshgj6NwsCepXlMuHlpYRO/3eDzK38LD7bYnR/K9RzUMfYtWe5sVHhG/LRyPcog
WK3qsUmkbLt6GP/WzqawsGjpt7LUZ8pPX3m4yJF6fqS9xbsZCHmlYf+LCHnVRuHBfblhYNWQkRP1
Lcy2t35Xud280ZHPOPHyrcPvfJC65Y2T/slP1h/TqvNTsmRERVQl9lzz8ZSA9RA0rhsPjs5Cf/Ra
vwmKP1jUZVuHtSbCn0/CXpdcKTPs08KDZX89LMj6zKL+omAPLZnNU2zn+whGNrj/HAORl5ts4JI1
bK8nRTnYa1fO9VkYnVodDJ/deQMCzh8L+Z0PfSy8VdKYwizn9CV5/kE2vqsb/43F+E6Gb5XsFEn0
5wjAo1hvayZoe6x7KG+suwXeQOVyAqJG3bWr8WQ1HRbR/CR8s7WvwbSoTP1LT6fUfeqZ56eiENav
J4O1H5X2UbeyH5H2LXgYtsdFnTVofGmj0g8CfIT4sa+4psD4KsHjpz9CmR+DkpcnGcMy9Q9el8rb
finrSZX1aZGyURqLexvm44T6h0zrJdCij36R1jVIWKqfOMv58B9bxke09VQTVz8IP0ePT6VPUlCD
HiR2e1mTa5z9vXWm5ChdumxykM5dqTQJiRw+KfXg5AmlfXrtw96a8N1bNBozd+Izv88rScsj5y72
6FXd4lqTNF+A65+1/FrR6lPiRlzaX92DVdvayrTPLsprs/J3Lit+lu3Dx4iXfoGhybkqDyUq5Iow
KDsnC8n59x3c9j23NqK3hy2znTd0RG/gpj0nCylz04ELOOVilr170LA8PvX9pmlPUNCysLOsMfKf
MzDwsRaxrfOqq2PHv2EbnHuNWqmEnZTWpqQ5bLXTlq5rCxrH8vupLK8ur2iwpynu5pajRkyuAdaz
5Ixe29OO0Lxph9Fse/UF8K9oGYvS1B9iNnFniubatb0Nxq8tuz/qlhI8DBy+5uOUjEUojXeO/11D
JNOHO2wiEOQwfnhzXv8I+G5ALkvJDrus8ss23XrOz09t1X63bXiMaZb3zSy/VBOybdpj9PpmPSLZ
VR6l6Irk7K3LJ2T5JjbQ3iRn1seHaupT/703asX1vlQhyjlcMlmOzaOTserb32+xBOpGNtpU3H5d
jJe22M+Wg+qn68fLX7xmQ2NtGD7WSsSyga5su+zlr+W9L31ev9ruN/+QUrCvK9u8cPE1fSCqHPDv
n8ge/SvJtnF22Etz18qQ7h/Z9nirEnzWgN31gfZVm7Jg0PG7fvjEe/+gSb4LKW0zn5eK3fIYVftA
3i9yMJb3S+cjK2yWttl9K/SDhh+7PN4Stc3eLbVzIpAP9jP5HnS3nbXYW23PN4eVGyyb3sXGXH7i
cj4ouTSIR+OZ30Vc2+C06L0D88DsOwJtK21aTcZnP8YPLPiG9LqC2z886RvocRexwPSUPuw+E/Wr
zdajjgNv32++ok7d8mbjiiHVps7gJHH2zz7HJSL3p9TXrPu7p7QmcnTb0y0HUThXQ9n1M8KrkhXk
TabyoQS9/EuFb9uiLR7DoNnt5zZ0jqsVtiF+uL3yscwsjsQX9wvdxeKG6z7MmvzjrdsUsPqo9Kem
k0r2udmBYyu9fUl3c+1Zwe+SVGMh6MR1Mi+Fvi3Y+4oPff96jQuHpfRZ+ltQWx0JvBq8ppUfsDbw
1yyQ6mK2UASZyyxP/dEIrqKyqNdnurY9CmV4rLytXOYMXBfmdS3JAni0Y48PMDY/P0xXvTt7bN+M
23GtKDc8Lsg5jDHjLOuNwndtjLqwROHJxRU89/GM1UE53qYaInzDVOlobfdA5obJHP7M4xTLj7qd
H+512s/iyVsrzXZYlUevftCqfG4DNtZy4E0/xf7wDps98cM3PDvDh1Rb1AV1K4XKmz7Z+q33S2sY
+/2lI4Q7zmL45EFms66Y8WvCr3tFz/OLfyaJ1OV88GXkz0XPTu402xLqq48BfyaIrBQyV7h9I/SI
NWH3zOWbhL04827/9Lh3a9m3Tt11DFHmjPIELRXE2dl3UfW00N02QzpF8Cyenxa5ILxL0tLYB6Gv
Zx7qHsptoXWVn40gw/Szf7XQkbwcBOm/+aHxqXsG0XMm5StcUycD5230SHr4oYiECJa1q96xFtv1
6PnGpF+YDioArHFvn8izVnyL8gcXIMKnbWT58vYdotT4LfdNghe9+7brtO3WirMhDSxMEMNiS35k
J1nhkmKXu0MWYIr3w9SQX/Bioefko6gMTyEPoZ5Lx6GTv4qPNX+wL/92sk0ndte2xD73xDLUIXhF
Juq92mL0szWeK3JFB6C0ieAvIHaXgykhDYa8yot+WURrw/wXMs5sjpVPwAieydMIr9ONd9g1WHHa
k8EjQixpR4+8Z6HBMyKBLfLK2Rb3ktJ+3aX1I3WwXLblb2U8M7zl3V1C8rJeXyqb93E9RbX1nhcs
D6QBuV7L5rnsFs/k0S6MdEbfLN3qU464pUJ9o5ptvHuL1Z+rqSk9tbfn++imnoavD7VjIBYzuNE5
rywnGLcJX0GP0+K1NPVsR/EduEoKn5bIG1MjegjVQpSH2tpHgsDem87gPdQWgnfgdsVJfMy5qyNX
WnRVV9HCbii5I74sZ1e0G0021RRF1eVJmCK/Lqs+YPZXYoM2yyI1u5vdvYwlYDVBoWSeFEKYqssh
3XQT52dU1N+bspEuxcBPfbGHcyx/5igopzK/dG7nEDoZusThqBIduzWYrrI81BW2S81b1VxnsFf6
b4w3xvcm2db9N9/6NfN+3FDX/acbC9F/p8KK5b/ZIDv8C8F23LP+07/93V/97q9++fXnX//0+2+/
/7s///Lrt384v/3PP/23n3/63z//+U+//+m//93f/frHv//pDz//+vPf/tdv/+7bP4K6b2Yalbjo
d6yae5kq1W3iN/Zm0MeZPz7443SP/C4cOv3Tb53rVMoFH8xPvw8a90/5/inD7+xaCrlomcxjE02j
D5ZURX458MarE0YVN/4IlpRxg5ec65ywx3B7kura7aDbMA1HpcRxyAYbuL/O+HXefp3ngo3opsC3
vNz88ZLlCl+RR54h5sN6IfOg6v0ThAjprAp/keBQ7ZyF5kyypQnbxT9Wue8AVe4ppMPmYWfJB/9Y
5DZzNEsWVmavYw6ZoyuOhtMkFWviCvK9od6tZuSbm2/2oDQepdEUVbQb3cz0Ysuc7oxkc4PhS4ce
XXHm++NWaGbG/ntp9pgSwPVA3tocZvzYdArK8yWzqu1P2fiDE/c5cQK8E0x7A65kHm0nnrSbry9O
vJsVKUIo1iA1rdH+ojV4gcbLzXHmDpIs7KGReb++JsS12lSjb/k0f+I1kX/Sn7+vNxYOVL6AZ7ND
sQflnklA6A4EYgSDILQg4IFsQLgJ/ks3gNPRah1+ImBORcHBJ1mu77eivHkBw2ECrz2Q3pNm1fqD
czkj5uS3qnaqqIuq/jzFfKQf6/w193xOk3c2M5HboTBBcgnKCrRPYatld7LgnMG/9XCLfP7Vb7Ep
Dq/Wt7CY+yKJm+WTci6gt5vwWlpPTA0bsHbwqVUF7vXe40azgjvVZ0xkhCkedW4Mxe8vx+SRpENg
k0MQPo4CAGT4if9eVNbKqb4r8JPsE35CiPAnUYlebrBcbV3ucEKBPaYVSBYltALpfsy8jjCaLLDo
0yiM8RCfWK/uu/xhAkk6VMwk3j+8QeGM6UB+5ghC36OFomRzbcNy8VPiZ6di8lXv2dzfzYvxhvhQ
3aRu/RJd8qFu2V5MUc7fZdylVnC38HAFQrFcASeKGnsu3DdZ52zRhY3HC2v6muiOMguNk6kvuCZH
aMs1dX83fuT8ZXQ7itrDC9Ks61Jz8V0VR9fN3WWys0rme/rK5RQiNP77xSOLZxbyO0KWrCpI+brO
D+krRxenVH0tfMl+MARmz5dPqvKt+Eurakx4nfJnuj+3qrt2xD2SZBkwXBhZQGmGfwvmsDBKbG0K
qOWHCO/5bs2Juut1dytqgzIxo7stmtUYUkxNG0hJdOdSArKzMmh/mZrJrOLTcrQNNXb2Op4qyr2w
wOLkY+cjE9ggy8kziBSsnQ1Ji/ATIZs/uWgQgfauKbKw/ja/veXVSAYzpC8KzELOwb0rZtCsGvzA
cP0Fqssv+ouuVZ2n+1XaY9WEAGpHogNii/MUv/cDf1dAZE/Jn2DA9z8Mg5/5L6FvIdKyv+npHzwc
htjLTkpeupv2lxy4epKj7JveH7QUd7OOP3at32bSUSJ8oeNtrKIFl5QspWlsovFlUX6F9i3jOQU7
U/hZjqk+kXhSiq/WqHe3Xg5Gz3mlbONw0Dmg6yrMLQutdIWdRa0Qm2jT5yrzDAWybKSGen0qKpdn
YSuXOG2dSb1Fse7c3iv3UAaJRavTMwi6J2j+ozl8VihvL6EGOlrnIWWxViIMWJSYK2Qyu1lKhEcb
H4AWgOVQGIK5zqx1K6FpVXHNRNZoRfJYOP8OAikHmmPWjg11V00mO72FX0+nXFqLvht+neI98d9b
pCjkyH9cQk9DNu0uz1WXdda+8cR7VL9DolpK5qbm0By7HLFwyxu0eER3pZ2FQhIeydAImQK8ZlwV
tp0+kJVaV4I/F0YX+bYYB807hsgIXfjfdUXown4ohy8FyHYK8LZ4o2hw14hjfGyVvxludNUMeyiQ
DjtZd+PKotKukJVQBeD1Mp9DXs6hK0hUp+G0IO65c3ve0mHQXSoPKCBwcQgcYm9G7hzQ6PmItFVs
Mm1ueW6f32jv5nDJiFM6ssZvp9GnR7luXaxWfQr8YXm1Kh8ckgblF6ZXGJYSsbdiPbH0SxDvvHdB
Z/3bwmd1LYgIv0yLHsLapYMT6OFavYxqHC52GqJZUNW53VWweX7eWd7yF9XbIRGCnoqpHY/IuMhi
CnoIcke2wdb7FDoB9XDnrlAWyxM2Zmumji02WlT7kkahRL3hvyXGPt5tfTmHBzFkhV7wLqMld8/d
vAPjadLI3VEUNyAKXBxhCwgb51i0eDJWgdk5tFfI/tfZL600RmueIkGMJTQBWoax0iEML/b8lgwu
IYPrU4+ZB7SwG3SLw8HYFv9lIYby2vFlzLuJiSHQFldWve4SFeIzpAutVKx04dDA8tmiPcEBohYT
KMNJRCZFJOj9ZjH651V32C2XlkQDC7WqlE/LetUr3TAmr94LfeJOTYuBTdF6js6KH6JEvMxIbphD
k5aK/nYsU7Iau5DaeDm35jNxVfFT5IXjj53uvvFSPwcWUuyoyIH3Y++Ga1olyuYOYzNgXS5ypGOM
1ipjNKQ9Bks+JsCV9tobmRSSUnZ/VxSYYz97s6w726mbM0C2UiQzDw0DM8zI8uoPX7dS9n9egzvy
65Bk7J/jwzA05b1AFSnn/uBaYqtZPilsGPfQ91MW72GkcamUCiMktp7FAP3q61MiYoi6DVbHfqIn
o3nvH/LOu2oFmqxnKbrkT4zqHt3ygj9RpEVZ5J4LhSi0GtXt4eukYlc8cw++dTqVmv56kD4uhUX9
kpOZcuhYeoTVkdlCT45IbfJUREhBqtKho/uiwJGql1XmZOiSt3Zu9lbOwgld/sGXyQjW+wIl5VAS
KQsncsKrOJ1haTuVNcc5SyHxx7FhudY1Xn1ob1GKYph7oeSPwCPjmg7zMSnt6WgFRXutVOVXMO7c
xqnGD5LLNt1nHxFTNGMznHX2GuBeXq0fMJUyxreEDeatulQW9Cp0tM+uhEWNqaGv9Snrp29dBVsf
xPcFrw/8EznyFPQ3pBC5ECyTsfSQv04PbyWMCKVVyvQfpgpiBpldxzYlZnxADuXHZUgkJL5MD5t8
DnEQuaiG0pmuKLyf4uCHx4ZdLpzNBMzaTFrTZxa5Ewdsi+XeO3+DFnVqvfZOUDzF5aLUkNA6JyUt
OXD7J8Lm+EKIhNBV8dD8gVYXWEXvrSaDyCwkujPUHy2i1U2eYzPEh/cpQP6YAPDjdtFvSYA2gvic
MVeD/OGACn34EJJFypbs6jszxPphPqS9uo1BhFZZsiUDLlbzmEpTF4/jp1l5dAJSAxUE9/PLxZpc
aC7Qkd9lbUFAdwldGoP+A6/51l3nT4rpwcdt3noGi77AQAUsa4Anv1yV19bZt0TdH915foxBntU3
6eH2wdunSMCKTHH44xMSz47E3+Uw71VQEtTOo/iOsHPoDlG+5YCWVQYAx0Yln/+B8JbQfuJQb1vS
NolMO7K0wgttPPYGmLp1EKY1m/pt+Cpvg5FR4AZZbESXzUaXs02yDeiuukBW9OdPXPfZ5fTmB4Jy
caUcxijM4IoZNSayl3UIOUdO9vLk4Xgim2LJ5lLpp5QHviGhLnGvQ6y603oNw8jrY3UGkMTwGZ64
Le+LcGqoiivnINXOyrOh62jKJtk5P5QALGF881GOylMeDOtAUkWsdq8+RtkElSliTTNIJs3AYtG5
C/7Udx+KFRjO/yX2HwTXPBLTctXGZxOXqm5TawSTx1IXAQn0LgGSivSKc5PVrcakfzIWkA+7mw+L
yZ7FNmYuHb5ZPrkUjapLGQtut0C1yszvhcUsRrNRMDY5N3lTPrbDeYWfWe8v9rutXxYfq3R5XLp4
QIyIhpw8zC+zyWIWnG6CrSuMbg6yqncleY+ZZ9WH6z5h/CY698z7uyWXIpk+DyqTqSO62Ehi+iqe
bIYrBairH0lrmioZtsomss7gULI1h5FqHR/PNj2I26/sYo7ZpAboBVNUzhCNWEvd3iWcq6jiQIpQ
56ByLtVvtUbCG66BriQzm1HFJfWqLJr0WEKqPmhLxYcbNqRHh5UPbYGLCTW79/uk0ckn1etFNSlQ
DPTSyOkKnqvcafOBieYCVE05FLoO2vMU89Vn0a1OlWGbnzDALrkULTRfw17V236n6qtkcLTpuhlO
eKjKTV91Cbf7WP2Ykm3pt3aDSe+rEE/bY+G0rAf69ERtFPLz4T00FniAzHh0LoaMnITqg7XxQvlR
gIbCTu9kKkqM+l5ARt4WOdXyVdDCthTW/aw1kjmDbVCB3rHJ8aAVgS1D+gvbUkhiXZU1sxJQj80m
SB2Ubgxhq4mT7yILmjTHHPAsH9o9SM+bYI1LMru9Krmb+fl8CqUTwq1fv8mkWfVaOZZUX+OR/LH5
JaEEbvVcGtW0pzCumTRw4jb5sbuslfddYuj+LterYEgQ/1ywu4cKmcU61dNJ7XoutxSvCEi6cGGc
r7hdFDaqUVUAadcqirxnKZzhkOvftKzSnbSwLpV+kh1cKjsPnAWCmJUHpaXHG7c4tHLvqTJCRRN1
npbMqtqVrVGy7JqEHN59v7Yw67YJ3AzgWnSQQafou7uiJNfSbRnnjFckdp/bHwwVcmtwJeumuBLV
d6orgJ5Gs1761JmeeGZTNVorr333+rqBWSBbX0HXvrD/3y+//v0//P5X3QPw//35//vj3y+/+IX7
Af7jt+N1/y/17xrEt6um17fzO8jf6vj+SzXsl9//8c9/nK0Ev/3Ta45L34/0203O39J3GvuWzlP/
pIf+/Id1YLmu7yvdi7SuflDD/tcv/8MOy+P1bYzvw+p3ufEdVPVD3PRwjoRT+ld//PMf/vTfv/2b
f/3t//wv/+mn//zX/8/f/B8//d9/8+//+qe/+U9//R/+r5/+47d//W9+9/8DRFfANYILAgA=
KIBAPANICPATCH

  cat > "${KIBA_KERNEL_DIR}/build-kernel.sh" << 'KIBAKERNELBUILD'
#!/bin/bash
# Runs as its own process so that `set -e` really is in force (it would be
# silently ignored if this were a function called from an `if`).
set -euo pipefail

KB="${KIBA_KERNEL_DIR}"
REPO="${KIBA_KERNEL_REPO}"
PATCH_NAME="${KIBA_PANIC_PATCH_NAME}"
PKG="${KB}/pkg"

pacman -S --noconfirm --needed base-devel git sudo libarchive zstd

id -u kibabuild >/dev/null 2>&1 || useradd -m kibabuild
echo 'kibabuild ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/kibabuild
chmod 440 /etc/sudoers.d/kibabuild

# Packaging repo at the tag matching the linux package in [core], so the
# kernel we build is the one Arch ships today (plus our patch).
_ver="$(pacman -Si core/linux | awk '/^Version/ {print $3}')"
echo "=== Arch linux package version: ${_ver} ==="
_url="https://gitlab.archlinux.org/archlinux/packaging/packages/linux.git"
rm -rf "${PKG}"
_ok=0
for _try in 1 2 3; do
  if git clone --depth 1 --branch "${_ver}" "${_url}" "${PKG}"; then _ok=1; break; fi
  rm -rf "${PKG}"; sleep 5
done
if [ "${_ok}" != 1 ]; then
  echo "!! no packaging tag ${_ver}; falling back to the packaging repo HEAD" >&2
  git clone --depth 1 "${_url}" "${PKG}"
fi
cd "${PKG}"

cp "${KB}/${PATCH_NAME}" "./${PATCH_NAME}"

# 1. our patch goes first in source[]; every checksum array gets a SKIP for it
sed -i "0,/^source=(/s//source=(\n  ${PATCH_NAME}\n  /" PKGBUILD
for _sum in b2sums sha512sums sha384sums sha256sums sha224sums sha1sums md5sums; do
  if grep -q "^${_sum}=(" PKGBUILD; then
    sed -i "0,/^${_sum}=(/s//${_sum}=('SKIP'\n        /" PKGBUILD
  fi
done
grep -q "${PATCH_NAME}" PKGBUILD

# 2. skip the HTML docs: huge texlive/sphinx makedepends and a long build
sed -i -E '/^[[:space:]]*_?make[[:space:]]+htmldocs[[:space:]]*$/d' PKGBUILD
sed -i -E 's/([[:space:]])htmldocs([[:space:]]+all)/\1\2/; s/[[:space:]]+all[[:space:]]+htmldocs/ all/' PKGBUILD
sed -i -E '/^[[:space:]]*"\$pkgbase-docs"[[:space:]]*$/d' PKGBUILD
sed -i -E '/^[[:space:]]+(graphviz|imagemagick|python-sphinx|python-sphinx_rtd_theme|python-yaml|texlive-latexextra|xmlto|dvisvgm)[[:space:]]*(#.*)?$/d' PKGBUILD
bash -n PKGBUILD

# 3. kernel config: DRM panic handler on, KibaOS navy for the fallback screens
_cfg=""
for _c in config.x86_64 config; do [ -f "${_c}" ] && { _cfg="${_c}"; break; }; done
[ -n "${_cfg}" ]
sed -i -E '/^(# )?CONFIG_DRM_PANIC(_FOREGROUND_COLOR|_BACKGROUND_COLOR|_SCREEN|_DEBUG)?([= ]|$)/d' "${_cfg}"
cat >> "${_cfg}" << 'KIBACFG'
CONFIG_DRM_PANIC=y
CONFIG_DRM_PANIC_FOREGROUND_COLOR=0xffffff
CONFIG_DRM_PANIC_BACKGROUND_COLOR=0x042276
CONFIG_DRM_PANIC_SCREEN="user"
# CONFIG_DRM_PANIC_DEBUG is not set
KIBACFG

chown -R kibabuild:kibabuild "${KB}" "${REPO}"

# Kernel + git tag signatures: try to get the maintainers' keys, otherwise
# skip the PGP check (the PKGBUILD's checksums still pin the sources).
_skip=""
for _k in $(grep -oE '^[[:space:]]+[0-9A-F]{40}' PKGBUILD | tr -d ' \t'); do
  su kibabuild -c "gpg --batch --keyserver keyserver.ubuntu.com --recv-keys ${_k}" || true
  su kibabuild -c "gpg --batch --list-keys ${_k}" >/dev/null 2>&1 || _skip="--skippgpcheck"
done

echo "=== building the KibaOS kernel (this is the slow part) ==="
su kibabuild -c "cd '${PKG}' && MAKEFLAGS='-j$(nproc)' PKGDEST='${REPO}' makepkg -s --noconfirm ${_skip}"

rm -f "${REPO}"/linux-docs-* "${REPO}"/*-debug-*
_kpkg="$(ls "${REPO}"/linux-[0-9]*.pkg.tar.* | grep -v '\.sig$' | head -n1)"
_hpkg="$(ls "${REPO}"/linux-headers-*.pkg.tar.* | grep -v '\.sig$' | head -n1)"
[ -f "${_kpkg}" ] && [ -f "${_hpkg}" ]

# prove the patch really is in the kernel we just built
if bsdtar -tf "${_kpkg}" | grep -q 'kernel/drivers/gpu/drm/drm\.ko\.zst$'; then
  bsdtar -xOf "${_kpkg}" --include='usr/lib/modules/*/kernel/drivers/gpu/drm/drm.ko.zst' \
    | zstd -dc | grep -aq 'kiba_screen'
  echo "=== verified: drm.ko in the new kernel carries the KibaOS panic screen ==="
else
  echo "!! drm.ko not found in package (DRM built in?) -- could not verify the patch" >&2
fi

repo-add "${REPO}/kiba-local.db.tar.gz" "${_kpkg}" "${_hpkg}"
echo "=== KibaOS kernel repo ready: ${REPO} ==="
KIBAKERNELBUILD

  if KIBA_KERNEL_DIR="${KIBA_KERNEL_DIR}" KIBA_KERNEL_REPO="${KIBA_KERNEL_REPO}" \
     KIBA_PANIC_PATCH_NAME="${KIBA_PANIC_PATCH_NAME}" \
     bash "${KIBA_KERNEL_DIR}/build-kernel.sh"; then
    KIBA_CUSTOM_KERNEL=1
    # local repo ahead of [core] so mkarchiso picks our linux / linux-headers
    sed -i '/^\[core\]/i [kiba-local]\nSigLevel = Optional TrustAll\nServer = file://'"${KIBA_KERNEL_REPO}"'\n' \
      "${PROFILE}/pacman.conf"
    # tells customize_airootfs.sh to protect the kernel from its pacman -Syu
    mkdir -p "${AIROOTFS}/etc"
    touch "${AIROOTFS}/etc/kiba-custom-kernel"
  else
    echo "!! KibaOS kernel build failed -- continuing with the stock Arch kernel" >&2
  fi
fi
echo "=== custom KibaOS kernel: ${KIBA_CUSTOM_KERNEL} ==="

cat > "${PROFILE}/profiledef.sh" << 'PROFILEDEF'
#!/usr/bin/env bash
iso_name="kibaos"
iso_label="KIBAOS"
iso_publisher="Kiba Labs, LLC <https://github.com/WolfTech-Innovations>"
iso_application="KibaOS — A friendly OS"
iso_version="$(date +%Y.%m)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1048576' '-Xdict-size' '1048576' '-no-duplicates' '-noappend')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/home/liveuser"]="1000:1000:750"
)
PROFILEDEF
chmod +x "${PROFILE}/profiledef.sh"

if [ "${KIBA_ARCH}" = "aarch64" ]; then
  sed -i "s/bootmodes=('bios.syslinux' 'uefi.grub')/bootmodes=('uefi-aarch64.systemd-boot.esp' 'uefi-aarch64.systemd-boot.eltorito')/" "${PROFILE}/profiledef.sh"
  sed -i 's/arch="x86_64"/arch="aarch64"/' "${PROFILE}/profiledef.sh"
  sed -i "s/'-Xbcj' 'x86'/'-Xbcj' 'arm64'/" "${PROFILE}/profiledef.sh"
fi

mkdir -p "${AIROOTFS}/etc"
cat > "${AIROOTFS}/etc/os-release" << 'OSRELEASE'
NAME="KibaOS"
PRETTY_NAME="KibaOS"
ID=kibaos
BUILD_ID=rolling
VENDOR_NAME="Kiba Labs"
ANSI_COLOR="1;36"
HOME_URL="https://github.com/WolfTech-Innovations/Kiba"
DOCUMENTATION_URL="https://github.com/WolfTech-Innovations/Kiba/blob/main/WIKI.md"
SUPPORT_URL="https://github.com/WolfTech-Innovations/Kiba/issues"
BUG_REPORT_URL="https://github.com/WolfTech-Innovations/Kiba/issues"
LOGO=kibaos
OSRELEASE

cat > "${PROFILE}/packages.x86_64" << 'PACKAGES'
archlinux-keyring
dosfstools
mtools
base
linux
linux-headers
linux-firmware
linux-firmware-intel
mkinitcpio
mkinitcpio-archiso
earlyoom
fakeroot
efibootmgr
bluez
nftables
libnetfilter_queue
sudo
bash
irqbalance
zram-generator
nano
gnome-console
curl
wget
git
mesa
power-profiles-daemon
xdg-user-dirs
noto-fonts
noto-fonts-emoji
noto-fonts-cjk
ttf-nunito
bluez-utils
go
switchboard-plug-desktop
switchboard-plug-display
switchboard-plug-network
switchboard-plug-bluetooth
switchboard-plug-power
switchboard-plug-datetime
switchboard-plug-keyboard
switchboard-plug-mouse-touchpad
switchboard-plug-sound
switchboard-plug-about
switchboard-plug-applications
switchboard-plug-locale
switchboard-plug-notifications
switchboard
switchboard-plug-printers
switchboard-plug-security-privacy
switchboard-plug-sharing
switchboard-plug-user-accounts
sof-firmware
thermald
xorg-xwayland
icu
gcc
debugedit
base-devel
python
pyalpm
parted
gptfdisk
syslinux
pv
lib32-mesa
lib32-vulkan-icd-loader
pkg-config
gdm
budgie-desktop
pcmanfm-qt
qt6-wayland
budgie-session
budgie-extras
webkit2gtk-4.1
python-gobject
labwc
swaybg
grim
slurp
wl-clipboard
tesseract
tesseract-data-eng
libnotify
swayidle
gtklock
wlopm
wlr-randr
nemo
gvfs
gvfs-mtp
gvfs-smb
gnome-text-editor
loupe
evince
papirus-icon-theme
adwaita-icon-theme
accountsservice
sassc
meson
ninja
vulkan-headers
vulkan-icd-loader
wayland
wayland-protocols
wlroots0.20
cairo
pango
pixman
libdrm
libevdev
libxml2
freetype2
libpng
harfbuzz
fribidi
glib2
sysprof
rust
libinput
libjpeg-turbo
libxkbcommon
nlohmann-json
yyjson
boost
glm
network-manager-applet
kvantum
pipewire
pipewire-pulse
pipewire-alsa
wireplumber
networkmanager

chromium
ntfs-3g
exfatprogs
polkit
udisks2
upower
scrot
fastfetch
flatpak
xdg-desktop-portal
xdg-desktop-portal-gtk
xdg-desktop-portal-wlr
imagemagick
eglinfo
gnupg
xdotool
v4l2loopback-dkms
xdg-utils
gawk
totem
kooha
malcontent
gtk4-layer-shell
file-roller
gnome-photos
haruna
gstreamer
gst-plugins-base
gst-plugins-good
gst-plugins-bad
plymouth
squashfs-tools

freerdp
docker
docker-compose
dialog
iproute2
openbsd-netcat
zenity
pciutils


lvm2

tuned
PACKAGES
if [ "${KIBA_ARCH}" = "aarch64" ]; then
  sed -i '/^linux-firmware-intel$/d' "${PROFILE}/packages.x86_64"
  sed -i '/^# linux-firmware split the Intel GuC\/HuC blobs/,/^# fails and KWin can never get a working renderer/d' \
    "${PROFILE}/packages.x86_64"
  sed -i '/^thermald$/d' "${PROFILE}/packages.x86_64"
  sed -i '/^syslinux$/d' "${PROFILE}/packages.x86_64"
  sed -i '/^lib32-mesa$/d; /^lib32-vulkan-icd-loader$/d' "${PROFILE}/packages.x86_64"
  sed -i '/^mkinitcpio-archiso$/d' "${PROFILE}/packages.x86_64"
  sed -i 's/^linux$/linux-aarch64/; s/^linux-headers$/linux-aarch64-headers/' \
    "${PROFILE}/packages.x86_64"
  mv "${PROFILE}/packages.x86_64" "${PROFILE}/packages.aarch64"
fi

mkdir -p "${AIROOTFS}/etc/mkinitcpio.conf.d"
cat > "${AIROOTFS}/etc/mkinitcpio.conf.d/archiso.conf" << 'INITRAMFS'
HOOKS=(base udev kms plymouth keyboard keymap modconf memdisk archiso block filesystems)
COMPRESSION="gzip"
INITRAMFS

if [ "${KIBA_ARCH}" = "aarch64" ]; then
  sed -i 's/ memdisk / /' "${AIROOTFS}/etc/mkinitcpio.conf.d/archiso.conf"
fi

cat > "${AIROOTFS}/etc/mkinitcpio.conf.d/installed.conf" << 'INSTALLED_HOOKS'
HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap block filesystems fsck)
COMPRESSION="gzip"
INSTALLED_HOOKS

mkdir -p "${AIROOTFS}/etc/mkinitcpio.d"
cat > "${AIROOTFS}/etc/mkinitcpio.d/linux.preset" << 'PRESET'
PRESETS=('archiso')
ALL_kver='/boot/vmlinuz-linux'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'
archiso_image='/boot/initramfs-linux.img'
PRESET
if [ "${KIBA_ARCH}" = "aarch64" ]; then
  rm -f "${AIROOTFS}/etc/mkinitcpio.d/linux-aarch64.preset"
fi

rm -rf "${PROFILE}/syslinux"

if [ "${KIBA_ARCH}" = "x86_64" ]; then
  rm -rf "${PROFILE}/efiboot"
  mkdir -p "${PROFILE}/grub"

  cat > "${PROFILE}/grub/grub.cfg" << 'GRUBCFG'
set default=0
set timeout=0
insmod all_video
insmod gfxterm
terminal_output gfxterm

search --no-floppy --set=root --label %ARCHISO_LABEL%

menuentry "KibaOS" --class kibaos {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.use-simpledrm=1
    initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
}

menuentry "KibaOS (safe mode)" --class kibaos {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G nomodeset systemd.unit=multi-user.target systemd.log_level=info
    initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
}

if [ "${grub_platform}" == "efi" ]; then
    menuentry 'UEFI Firmware Settings' --id 'uefi-firmware' {
        fwsetup
    }
fi
GRUBCFG

  # BIOS side of the hybrid ISO: mkarchiso's bios.syslinux mode copies every
  # *.cfg in here to boot/syslinux/ (substituting the %...% placeholders) and
  # drops isolinux.bin, ldlinux.c32, menu.c32, ... next to them.
  mkdir -p "${PROFILE}/syslinux"
  cat > "${PROFILE}/syslinux/syslinux.cfg" << 'SYSLINUXCFG'
DEFAULT kibaos
PROMPT 0
UI menu.c32
MENU TITLE KibaOS
MENU HIDDEN
TIMEOUT 10

LABEL kibaos
    MENU LABEL KibaOS
    LINUX /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux
    INITRD /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
    APPEND archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.use-simpledrm=1

LABEL kibaos-safe
    MENU LABEL KibaOS (safe mode)
    LINUX /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux
    INITRD /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
    APPEND archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G nomodeset systemd.unit=multi-user.target systemd.log_level=info
SYSLINUXCFG
else
  mkdir -p "${PROFILE}/efiboot/loader/entries"
  cat > "${PROFILE}/efiboot/loader/loader.conf" << 'LOADERCONF'
timeout 0
default kibaos.conf
LOADERCONF
  cat > "${PROFILE}/efiboot/loader/entries/kibaos.conf" << 'ENTRYCONF'
title   KibaOS
linux   /%INSTALL_DIR%/boot/%ARCH%/Image
initrd  /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
options archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.use-simpledrm=1
ENTRYCONF
  cat > "${PROFILE}/efiboot/loader/entries/kibaos-safe.conf" << 'ENTRYCONF'
title   KibaOS (safe mode)
linux   /%INSTALL_DIR%/boot/%ARCH%/Image
initrd  /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
options archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G nomodeset systemd.unit=multi-user.target systemd.log_level=info
ENTRYCONF
fi

PACMAN_CONF="${PROFILE}/pacman.conf"
if [ -f "${PACMAN_CONF}" ]; then
  grep -q 'NoExtract' "${PACMAN_CONF}" || \
    sed -i '/^\[options\]/a NoExtract  = usr/share/man/* usr/share/info/* usr/share/doc/*\nNoExtract  = usr/share/locale/* !usr/share/locale/en_US/* !usr/share/locale/en_GB/* !usr/share/locale/locale.alias' \
    "${PACMAN_CONF}"
fi

LIVE_HASH=$(openssl passwd -6 "live")
grep -q '^liveuser:' "${AIROOTFS}/etc/passwd"  2>/dev/null || \
  echo 'liveuser:x:1000:1000:KibaOS Live User:/home/liveuser:/bin/bash' >> "${AIROOTFS}/etc/passwd"
grep -q '^liveuser:' "${AIROOTFS}/etc/group"   2>/dev/null || \
  echo 'liveuser:x:1000:liveuser' >> "${AIROOTFS}/etc/group"
grep -q '^liveuser:' "${AIROOTFS}/etc/shadow"  2>/dev/null || \
  echo "liveuser:${LIVE_HASH}:19000:0:99999:7:::" >> "${AIROOTFS}/etc/shadow"
mkdir -p "${AIROOTFS}/home/liveuser"
mkdir -p "${AIROOTFS}/etc/sudoers.d"
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > "${AIROOTFS}/etc/sudoers.d/liveuser"
chmod 0440 "${AIROOTFS}/etc/sudoers.d/liveuser"

WANTS="${AIROOTFS}/etc/systemd/system"
mkdir -p "${WANTS}/default.target.wants" "${WANTS}/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/graphical.target       "${WANTS}/default.target"
ln -sf /usr/lib/systemd/system/gdm.service             "${WANTS}/display-manager.service"
ln -sf /usr/lib/systemd/system/pacman-init.service    "${WANTS}/multi-user.target.wants/pacman-init.service"
ln -sf /usr/lib/systemd/system/bluetooth.service      "${WANTS}/multi-user.target.wants/bluetooth.service"

mkdir -p "${AIROOTFS}/root"
cat > "${AIROOTFS}/root/customize_airootfs.sh" << 'CUSTOMIZE'
#!/usr/bin/env bash
set -e

export GVFS_DISABLE_FUSE=1

rm -f /etc/machine-id
touch /etc/machine-id
systemd-machine-id-setup

rm /usr/lib/sysusers.d/basic.conf
rm /usr/lib/sysusers.d/arch.conf
systemd-sysusers || true
systemd-tmpfiles --create 2>/dev/null || true

id polkitd &>/dev/null || useradd -r -U -M -d /run/polkit -s /usr/bin/nologin polkitd

useradd -r -s /usr/bin/nologin -U alpm 2>/dev/null || true
mkdir -p /var/cache/pacman/pkg
chmod 755 /var/cache/pacman /var/cache/pacman/pkg
chown -R alpm:alpm /var/cache/pacman
if [ "$(uname -m)" = "x86_64" ]; then
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
fi

if [ "$(uname -m)" = "x86_64" ]; then
  cat > /etc/pacman.d/mirrorlist << 'MIRRORLIST'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
Server = https://america.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
MIRRORLIST
fi

sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf

if [ -f /etc/kiba-custom-kernel ]; then
  # keep the KibaOS-built kernel: the pacman -Syu calls below must not swap
  # it for core/linux (removed again at the end so installed systems update
  # their kernel normally)
  sed -i '/^\[options\]/a IgnorePkg = linux linux-headers' /etc/pacman.conf
fi

rm -rf /etc/pacman.d/gnupg
pacman-key --init
pacman-key --populate archlinux
if [ "$(uname -m)" = "aarch64" ]; then
  pacman-key --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6 \
    --keyserver keyserver.ubuntu.com
  pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6
fi
pacman -Syy --noconfirm

pacman -Scc --noconfirm

systemctl disable earlyoom 2>/dev/null || true
mkdir -p /etc/systemd/oomd.conf.d
cat > /etc/systemd/oomd.conf.d/kibaos.conf << 'OOMDCONF'
[OOM]
SwapUsedLimit=90%
DefaultMemoryPressureDurationSec=20s
OOMDCONF
systemctl enable systemd-oomd

cat > /etc/sysctl.d/99-kibaos.conf << 'SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
fs.inotify.max_user_watches=524288
net.core.netdev_max_backlog=16384
SYSCTL

pacman-key --init
pacman-key --populate archlinux
pacman -Syy --noconfirm

sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo 'kibaos' > /etc/hostname
cat > /etc/hosts << 'HOSTS'
127.0.0.1   localhost
::1         localhost
127.0.1.1   kibaos.localdomain kibaos
HOSTS

for g in users wheel audio video input network storage power; do
  groupadd -r "$g" 2>/dev/null || true
  usermod -aG "$g" liveuser 2>/dev/null || true
done
echo "liveuser:live" | chpasswd
grep -qx '/bin/bash' /etc/shells || echo '/bin/bash' >> /etc/shells
cp -aT /etc/skel/ /home/liveuser/ 2>/dev/null || true
chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser

sed -i 's/#Storage=auto/Storage=volatile/'                    /etc/systemd/journald.conf
sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=ignore/'   /etc/systemd/logind.conf
sed -i 's/#HandleSuspendKey=suspend/HandleSuspendKey=ignore/' /etc/systemd/logind.conf
sed -i 's/#IdleAction=ignore/IdleAction=ignore/'               /etc/systemd/logind.conf
grep -q 'IdleActionSec'  /etc/systemd/logind.conf || echo 'IdleActionSec=0'  >> /etc/systemd/logind.conf
grep -q 'HandleHibernateKey' /etc/systemd/logind.conf || echo 'HandleHibernateKey=ignore' >> /etc/systemd/logind.conf
grep -q 'HandleLidSwitchDocked' /etc/systemd/logind.conf || echo 'HandleLidSwitchDocked=ignore' >> /etc/systemd/logind.conf
grep -q 'HandleLidSwitchExternalPower' /etc/systemd/logind.conf || echo 'HandleLidSwitchExternalPower=ignore' >> /etc/systemd/logind.conf
grep -q 'HandlePowerKey' /etc/systemd/logind.conf && \
  sed -i 's/^HandlePowerKey=.*/HandlePowerKey=poweroff/' /etc/systemd/logind.conf

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

WALLPAPER_URL="https://github.com/KibaLabsLLC/KibaOS/blob/c11612bb0a634b1997f7a1f94a5ba79b45d561ea/assets/wallpapers/FAF8064B-B17D-4331-9EF8-06E325EEAE4F.png?raw=true"
BOOT_SPLASH_URL="https://github.com/WolfTech-Innovations/Kiba/blob/main/assets/splash/splash.png?raw=true"
WALLPAPER_DEST="/usr/share/kibaos/wallpaper.jpg"
LOGO_SRC="/usr/share/kibaos/logo-raw.png"
LOGO_256="/usr/share/kibaos/logo-256.png"
LOGO_96="/usr/share/kibaos/logo-96.png"
LOGO_48="/usr/share/kibaos/logo-48.png"
LOGO_32="/usr/share/kibaos/logo-32.png"
INSTALLER_LOGO="/usr/share/kibaos/installer-logo.png"
BOOT_SPLASH_RAW="/usr/share/kibaos/boot-splash-raw.png"
BOOT_SPLASH="/usr/share/kibaos/boot-splash.png"

mkdir -p /usr/share/kibaos /usr/share/pixmaps

curl -fL --retry 5 --retry-delay 3 -o "${BOOT_SPLASH_RAW}" "${BOOT_SPLASH_URL}" || true

if [ -f "${BOOT_SPLASH_RAW}" ] && file "${BOOT_SPLASH_RAW}" | grep -qi 'image'; then
  magick "${BOOT_SPLASH_RAW}" -filter Lanczos -resize '480x480>' "${BOOT_SPLASH}"

  cp "${BOOT_SPLASH_RAW}" "${LOGO_SRC}"
  rm -f "${BOOT_SPLASH_RAW}"
fi

curl -fL --retry 5 --retry-delay 3 -o "${WALLPAPER_DEST}" "${WALLPAPER_URL}" || \
  magick -size 1920x1080 gradient:"#003f5c-#0099cc" "${WALLPAPER_DEST}"

if [ -f "${LOGO_SRC}" ] && file "${LOGO_SRC}" | grep -qi 'image'; then
  magick "${LOGO_SRC}" -filter Lanczos -resize 256x256 "${LOGO_256}"
  magick "${LOGO_SRC}" -filter Lanczos -resize 96x96  "${LOGO_96}"
  magick "${LOGO_SRC}" -filter Lanczos -resize 48x48  "${LOGO_48}"
  magick "${LOGO_SRC}" -filter Lanczos -resize 32x32  "${LOGO_32}"
  rm -f "${LOGO_SRC}"
else
  for sz in 256 96 48 32; do
    magick -size ${sz}x${sz} xc:none \
      -fill '#0099cc' -draw "circle $((sz/2)),$((sz/2)) $((sz/2)),1" \
      -fill white -pointsize $((sz/2)) -gravity Center -annotate 0 'K' \
      "/usr/share/kibaos/logo-${sz}.png"
  done
fi

cp "${LOGO_256}" /usr/share/pixmaps/kibaos.png
ln -sf /usr/share/pixmaps/kibaos.png /usr/share/pixmaps/kibaos-logo.png
mkdir -p /usr/share/icons/hicolor/256x256/apps \
         /usr/share/icons/hicolor/48x48/apps   \
         /usr/share/icons/hicolor/32x32/apps
cp "${LOGO_256}" /usr/share/icons/hicolor/256x256/apps/kibaos.png
cp "${LOGO_48}"  /usr/share/icons/hicolor/48x48/apps/kibaos.png
cp "${LOGO_32}"  /usr/share/icons/hicolor/32x32/apps/kibaos.png
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true

BADGE_WHITE_SRC="/usr/share/kibaos/badge-white.png"
magick "${LOGO_256}" -alpha extract -threshold 50% /tmp/kiba-badge-alpha.png
magick -size 256x256 xc:white /tmp/kiba-badge-white.png
magick /tmp/kiba-badge-white.png /tmp/kiba-badge-alpha.png \
  -alpha off -compose CopyOpacity -composite "${BADGE_WHITE_SRC}"
rm -f /tmp/kiba-badge-alpha.png /tmp/kiba-badge-white.png

mkdir -p /usr/share/icons/hicolor/scalable/actions \
         /usr/share/icons/hicolor/symbolic/actions \
         /usr/share/icons/hicolor/24x24/actions    \
         /usr/share/icons/hicolor/22x22/actions     \
         /usr/share/icons/hicolor/16x16/actions
for sz in 16 22 24 32 48; do
  magick "${BADGE_WHITE_SRC}" -filter Lanczos -resize ${sz}x${sz} \
    "/usr/share/icons/hicolor/${sz}x${sz}/actions/pane-show-symbolic.png"
done
cp "${BADGE_WHITE_SRC}" /usr/share/icons/hicolor/scalable/actions/pane-show-symbolic.png
cp "${BADGE_WHITE_SRC}" /usr/share/icons/hicolor/symbolic/actions/pane-show-symbolic.png
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true

if [ -f "${BOOT_SPLASH}" ]; then
  cp "${BOOT_SPLASH}" "${INSTALLER_LOGO}"
else
  cp "${LOGO_256}" "${INSTALLER_LOGO}"   # fallback: reuse the generic logo
fi

mkdir -p /usr/share/WA/src
cat > /usr/share/WA/src/winapps-setup.vala << 'WINAPPSSETUPVALA'
public class KibaWinAppsSetup : Adw.Application {
    private Adw.ApplicationWindow window;
    private Gtk.ProgressBar progress_bar;
    private Gtk.Label       heading_label;
    private Gtk.Label       status_label;
    private Gtk.Box         button_row;
    private Gtk.Button      retry_btn;
    private Gtk.Button      open_btn;
    private Gtk.Button      close_btn;
    private string          last_fatal_message = "";
    private string[]        launch_args;

    // Same tiny inline translator as KibaOOBE (see main.vala) -- kept as
    // a separate copy rather than a shared header, since this is a
    // single-file build target and Vala has no lightweight way to share
    // one private method across two unrelated executable() targets
    // without a proper library split, which is more plumbing than a
    // three-line helper is worth here.
    private string ui_lang = "en";
    private string t (string en, string tr, string pl) {
        return ui_lang == "tr" ? tr : ui_lang == "pl" ? pl : en;
    }

    public KibaWinAppsSetup (string[] args) {
        Object (application_id: "io.kibaos.winapps-setup", flags: ApplicationFlags.FLAGS_NONE);
        // Everything after argv[0] -- just the optional "--manual-launch"
        // flag kibaos-winapps-workspace already passes today -- gets
        // forwarded straight through to the backend unchanged, same as
        // it always did back when kibaos-winapps-workspace exec'd the
        // backend directly.
        launch_args = args;
    }

    protected override void activate () {
        var locale = GLib.Environment.get_variable ("LANG") ?? "";
        if (locale.has_prefix ("tr")) ui_lang = "tr";
        else if (locale.has_prefix ("pl")) ui_lang = "pl";

        window = new Adw.ApplicationWindow (this) {
            default_width  = 480,
            default_height = 420,
            resizable      = false,
            title = t ("Windows Workspace Setup",
                       "Windows Çalışma Alanı Kurulumu",
                       "Konfiguracja Windows Workspace")
        };

        var toolbar = new Adw.ToolbarView ();
        toolbar.add_top_bar (new Adw.HeaderBar ());

        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 18) {
            halign = Gtk.Align.CENTER, valign = Gtk.Align.CENTER,
            margin_top = 12, margin_bottom = 30, margin_start = 36, margin_end = 36
        };

        var icon = new Gtk.Image.from_icon_name ("kibaos-winapps") {
            pixel_size = 64, halign = Gtk.Align.CENTER
        };
        content.append (icon);

        heading_label = new Gtk.Label (
            t ("Setting up Windows Workspace",
               "Windows Çalışma Alanı Kuruluyor",
               "Konfigurowanie Windows Workspace")) {
            halign = Gtk.Align.CENTER, justify = Gtk.Justification.CENTER
        };
        heading_label.add_css_class ("title-1");
        content.append (heading_label);

        progress_bar = new Gtk.ProgressBar () { show_text = false, hexpand = true };
        content.append (progress_bar);

        status_label = new Gtk.Label (t ("Starting…", "Başlatılıyor…", "Uruchamianie…")) {
            halign = Gtk.Align.CENTER, justify = Gtk.Justification.CENTER,
            wrap = true, max_width_chars = 48
        };
        status_label.add_css_class ("dim-label");
        content.append (status_label);

        // All three buttons exist from the start, just hidden -- toggling
        // visibility rather than reparenting widgets keeps run_backend()
        // (which is also the retry path) simple to reset between runs.
        button_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10) {
            halign = Gtk.Align.CENTER, visible = false
        };
        retry_btn = new Gtk.Button.with_label (t ("Retry", "Tekrar Dene", "Spróbuj ponownie"));
        retry_btn.add_css_class ("suggested-action");
        retry_btn.clicked.connect (() => run_backend ());
        open_btn = new Gtk.Button.with_label (
            t ("Open Windows Workspace", "Windows Çalışma Alanını Aç", "Otwórz Windows Workspace"));
        open_btn.add_css_class ("suggested-action");
        open_btn.clicked.connect (() => {
            try { GLib.Process.spawn_command_line_async ("/usr/local/bin/kibaos-winapps-workspace"); }
            catch (GLib.SpawnError e) { warning ("Failed to launch Windows Workspace: %s", e.message); }
            window.close ();
        });
        close_btn = new Gtk.Button.with_label (t ("Close", "Kapat", "Zamknij"));
        close_btn.add_css_class ("flat");
        close_btn.clicked.connect (() => window.close ());
        button_row.append (retry_btn);
        button_row.append (open_btn);
        button_row.append (close_btn);
        content.append (button_row);

        toolbar.set_content (content);
        window.set_content (toolbar);
        window.present ();

        run_backend ();
    }

    // ══════════════════════════════════════════════════════════════════
    // Backend plumbing -- same PROGRESS/FATAL reader as KibaOOBE's
    // launch_backend()/read_backend_output() (see main.vala), just
    // pointed at kibaos-winapps-setup instead of kibaos-oobe-backend/
    // kibaos-oem-finish.sh, and spawned WITHOUT a sudo/pkexec prefix --
    // unlike those two, this backend has to run as the actual invoking
    // user (it writes under $HOME/.config/winapps) and elevates only the
    // specific docker/systemd calls it needs, itself, inline, via its
    // own pkexec calls. Wrapping the whole thing in sudo here would hand
    // it root's $HOME instead and break that.
    // ══════════════════════════════════════════════════════════════════
    private void run_backend () {
        button_row.visible = false;
        retry_btn.visible  = false;
        open_btn.visible   = false;
        close_btn.visible  = false;
        heading_label.label = t ("Setting up Windows Workspace",
                                  "Windows Çalışma Alanı Kuruluyor",
                                  "Konfigurowanie Windows Workspace");
        progress_bar.fraction = 0.0;
        // Undo whatever show_failure_state() below left behind from a
        // previous failed attempt -- without this, a retry that succeeds
        // would still show the status line in error styling.
        status_label.remove_css_class ("error");
        status_label.add_css_class ("dim-label");
        status_label.label = t ("Starting…", "Başlatılıyor…", "Uruchamianie…");

        string[] argv = (launch_args.length > 1)
            ? new string[] { "/usr/local/bin/kibaos-winapps-setup", launch_args[1] }
            : new string[] { "/usr/local/bin/kibaos-winapps-setup" };

        try {
            var launcher = new GLib.SubprocessLauncher (
                GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_MERGE);
            var proc = launcher.spawnv (argv);
            last_fatal_message = "";
            read_backend_output.begin (
                new GLib.DataInputStream (proc.get_stdout_pipe ()), proc);
        } catch (GLib.Error e) {
            status_label.label = t ("Failed to start: %s", "Başlatılamadı: %s",
                                     "Nie udało się uruchomić: %s").printf (e.message);
            show_failure_state ();
        }
    }

    private async void read_backend_output (GLib.DataInputStream stream, GLib.Subprocess proc) {
        try {
            while (true) {
                string? line = yield stream.read_line_async ();
                if (line == null) break;
                if (line.has_prefix ("PROGRESS ")) {
                    var parts = line.substring (9).split (" ", 2);
                    int    pct = int.parse (parts[0]);
                    string msg = parts.length > 1 ? parts[1] : "";
                    progress_bar.fraction = pct / 100.0;
                    status_label.label    = msg;
                } else if (line.has_prefix ("FATAL: ")) {
                    // Same reasoning as KibaOOBE: STDERR_MERGE means this
                    // is the one place the real failure reason (not a
                    // generic message) is ever actually available.
                    last_fatal_message = line.substring (7);
                }
            }
            yield proc.wait_async ();
            if (proc.get_exit_status () == 0) {
                heading_label.label   = t ("All set!", "Her şey hazır!", "Wszystko gotowe!");
                progress_bar.fraction = 1.0;
                open_btn.visible      = true;
                close_btn.visible     = true;
                button_row.visible    = true;
            } else {
                heading_label.label = t ("Setup didn't finish", "Kurulum tamamlanamadı",
                                          "Konfiguracja się nie powiodła");
                status_label.label = last_fatal_message != "" ? last_fatal_message : t (
                    "Something went wrong. Check the system log (journalctl -t kibaos-winapps-setup) for details.",
                    "Bir şeyler ters gitti. Ayrıntılar için sistem günlüğünü kontrol edin (journalctl -t kibaos-winapps-setup).",
                    "Coś poszło nie tak. Sprawdź dziennik systemowy (journalctl -t kibaos-winapps-setup), aby uzyskać szczegóły.");
                show_failure_state ();
            }
        } catch (GLib.Error e) {
            heading_label.label = t ("Setup didn't finish", "Kurulum tamamlanamadı",
                                      "Konfiguracja się nie powiodła");
            status_label.label = t ("Lost connection to the setup process: %s",
                                     "Kurulum sürecine bağlantı kesildi: %s",
                                     "Utracono połączenie z procesem konfiguracji: %s").printf (e.message);
            show_failure_state ();
        }
    }

    private void show_failure_state () {
        status_label.remove_css_class ("dim-label");
        status_label.add_css_class ("error");
        retry_btn.visible  = true;
        close_btn.visible  = true;
        button_row.visible = true;
    }

    public static int main (string[] args) {
        return new KibaWinAppsSetup (args).run (args);
    }
}
WINAPPSSETUPVALA
pacman -Syu --noconfirm git
git clone https://github.com/KibaLabsLLC/Roko
cd Roko
bash build.sh
cd ..
git clone https://github.com/tortr-rs/goget.git
cd goget
make 
make install
set -euo pipefail
git clone --depth 1 https://github.com/KibaLabsLLC/Okami.git
cd Okami
pacman -Syu --noconfirm --needed \
  cmake extra-cmake-modules qt6-base qt6-declarative qt6-svg kirigami flatpak kcoreaddons ki18n
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . -j"$(nproc)"
git clone https://github.com/KibaLabsLLC/KibaD
cd KibaD/
mkdir -p "/usr/lib/systemd/system"

cat > "/usr/lib/systemd/system/kibad.service" <<'EOF'
[Unit]
Description=KibaD Hardware Telemetry Daemon
After=graphical-session.target
Wants=network-online.target

[Service]
User=1000
Environment="WAYLAND_DISPLAY=wayland-0"
Environment="XDG_RUNTIME_DIR=/run/user/1000"
Environment="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
Type=simple
ExecStart=/usr/lib/kibad/kibad
Restart=on-failure
RestartSec=10

[Install]
WantedBy=graphical-session.target
EOF

cargo build --release

install -Dm755 target/release/kibad \
    "/usr/lib/kibad/kibad"

cat > /usr/share/WA/src/meson.build << 'WAMESON'
project('winapps-setup', 'vala', 'c', version: '1.0')

cc = meson.get_compiler('c')
m_dep       = cc.find_library('m', required: true)
threads_dep = dependency('threads')   # needed for GLib.Thread

gtk4_dep    = dependency('gtk4')
adwaita_dep = dependency('libadwaita-1')
gee_dep     = dependency('gee-0.8')

executable(
  'io.kibaos.winapps-setup',
  'winapps-setup.vala',
  dependencies: [gtk4_dep, adwaita_dep, m_dep, threads_dep],
  install: true
)
WAMESON
mkdir -p /usr/share/icons/hicolor/scalable/actions
cp /usr/share/kibaos/logo-256.png /usr/share/icons/hicolor/scalable/actions/kibaos-watermark-symbolic.png 2>/dev/null || true
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true

echo "=== Building libkibadisk (disk/install backend library) ==="
mkdir -p /usr/share/kibaos-oobe/src/disk
cd /usr/share/kibaos-oobe/src/disk
pacman -Rns --noconfirm gcc base-devel debugedit make patch autoconf automake 2>/dev/null || true

cat > /usr/local/bin/kibaos-oem-finish.sh << 'OEMFINISH'
#!/usr/bin/env bash
set -euo pipefail

LOCALE="$1"; KEYMAP="$2"; HOSTNAME_VAL="$3"; USERNAME_VAL="$4"; PASSWORD_VAL="$5"
LOG=/var/log/kibaos-oobe.log
exec > >(tee -a "${LOG}") 2>&1

progress() { echo "PROGRESS $1 $2"; }
fail() { progress 100 "Setup failed: $1"; echo "FATAL: $1" >&2; exit 1; }

[ -n "${USERNAME_VAL}" ] || fail "no username given"

progress 15 "Setting locale and keyboard..."
sed -i "s/#${LOCALE}/${LOCALE}/" /etc/locale.gen 2>/dev/null || true
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
locale-gen || fail "locale-gen failed"

progress 45 "Setting computer name..."
echo "${HOSTNAME_VAL}" > /etc/hostname
sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTNAME_VAL}.localdomain ${HOSTNAME_VAL}/" /etc/hosts 2>/dev/null || true

progress 65 "Creating your account..."
useradd -m -G wheel,audio,video,input,network,storage,power,docker -s /bin/bash "${USERNAME_VAL}" \
  || fail "useradd failed"
echo "${USERNAME_VAL}:${PASSWORD_VAL}" | chpasswd || fail "chpasswd failed"

mkdir -p /etc/kibaos
umask 077
printf '%s' "${PASSWORD_VAL}" > /etc/kibaos/winapps-userpass
chmod 600 /etc/kibaos/winapps-userpass
umask 022

progress 85 "Cleaning up OEM account..."
userdel -r oem 2>/dev/null || true
rm -f /var/lib/AccountsService/users/oem 2>/dev/null || true
if [ -f /etc/gdm/custom.conf.pre-oem ]; then
  mv /etc/gdm/custom.conf.pre-oem /etc/gdm/custom.conf
else
  rm -f /etc/gdm/custom.conf 2>/dev/null || true
fi

progress 95 "Finishing up..."
mkdir -p /etc/kibaos
touch /etc/kibaos/winapps-pending
rm -f /etc/kibaos/oem-pending

progress 100 "Done"
exit 0
OEMFINISH
chmod +x /usr/local/bin/kibaos-oem-finish.sh

cat > /usr/local/bin/kibaos-oem-prepare << 'OEMPREPARE'
#!/usr/bin/env bash
set -e
mkdir -p /etc/kibaos
touch /etc/kibaos/oem-pending

id oem &>/dev/null || useradd -m -G wheel,audio,video,input,network,storage,power,docker -s /bin/bash oem
passwd -d oem 2>/dev/null || true

mkdir -p /etc/gdm
[ -f /etc/gdm/custom.conf ] && cp -f /etc/gdm/custom.conf /etc/gdm/custom.conf.pre-oem 2>/dev/null || true
cat > /etc/gdm/custom.conf << 'GDMOEMCONF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=oem
WaylandEnable=true
GDMOEMCONF

mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/oem << 'OEMACCOUNTS'
[User]
Session=budgie-desktop
XSession=budgie-desktop
SystemAccount=false
OEMACCOUNTS

echo "OEM mode prepared. This device will boot to a temporary 'oem' account"
echo "and prompt the customer to finish setup on next boot. Do not run this"
echo "on a normal end-user installation."
OEMPREPARE
chmod +x /usr/local/bin/kibaos-oem-prepare

if [ -x /usr/bin/io.kibaos.oobe ]; then
  echo "=== KibaOS OOBE installer is the active install path ==="
else
  echo "=== WARNING: KibaOS OOBE installer binary not found post-build ===" >&2
  exit 1
fi

userdel -r builduser 2>/dev/null || true
rm -f /etc/sudoers.d/builduser
KIBA_PLYMOUTH_DIR="/usr/share/plymouth/themes/kibaos"
mkdir -p "${KIBA_PLYMOUTH_DIR}"

if [ -f "${BOOT_SPLASH}" ]; then
  cp "${BOOT_SPLASH}" "${KIBA_PLYMOUTH_DIR}/splash.png"
else
  cp /usr/share/kibaos/logo-256.png "${KIBA_PLYMOUTH_DIR}/splash.png" 2>/dev/null || true
fi

cat > "${KIBA_PLYMOUTH_DIR}/kibaos.plymouth" << 'PLYMOUTHDESC'
[Plymouth Theme]
Name=KibaOS
Description=KibaOS boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/kibaos
ScriptFile=/usr/share/plymouth/themes/kibaos/kibaos.script
PLYMOUTHDESC

cat > "${KIBA_PLYMOUTH_DIR}/kibaos.script" << 'PLYMOUTHSCRIPT'
// KibaOS boot splash — Plymouth script theme.
// Centered brand image on a dark background, with a small three-dot
// progress pulse underneath and a minimal password prompt for
// full-disk-encryption unlocks.

Window.SetBackgroundTopColor(0.043, 0.055, 0.078);
Window.SetBackgroundBottomColor(0.043, 0.055, 0.078);

logo.image = Image("splash.png");
logo.image = logo.image.Scale(logo.image.GetWidth() - 6, logo.image.GetHeight() - 6);
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(Window.GetWidth() / 2 - logo.image.GetWidth() / 2);
logo.sprite.SetY(Window.GetHeight() / 2 - logo.image.GetHeight() / 2);
logo.sprite.SetOpacity(1);

dot_count = 3;
dot_spacing = 26;
dots = [];
for (i = 0; i < dot_count; i++) {
  dots[i].image = Image.Text("•", 1, 1, 1, 1, "Sans 28");
  dots[i].sprite = Sprite(dots[i].image);
  dots[i].sprite.SetX(Window.GetWidth() / 2 - (dot_count * dot_spacing) / 2 + i * dot_spacing);
  dots[i].sprite.SetY(logo.sprite.GetY() + logo.image.GetHeight() + 36);
  dots[i].sprite.SetOpacity(0.25);
}

progress_tick = 0;
fun refresh_callback() {
  progress_tick++;
  active = Math.Int(progress_tick / 8) % dot_count;
  for (i = 0; i < dot_count; i++) {
    if (i == active)
      dots[i].sprite.SetOpacity(1);
    else
      dots[i].sprite.SetOpacity(0.25);
  }
}
Plymouth.SetRefreshFunction(refresh_callback);

fun display_password_callback(prompt, bullets) {
  if (prompt == "")
    prompt = "Enter your password to unlock the disk:";
  prompt_text.image = Image.Text(prompt, 1, 1, 1, 1);
  prompt_text.sprite = Sprite(prompt_text.image);
  prompt_text.sprite.SetX(Window.GetWidth() / 2 - prompt_text.image.GetWidth() / 2);
  prompt_text.sprite.SetY(dots[0].sprite.GetY() + 50);
}
Plymouth.SetDisplayPasswordFunction(display_password_callback);
PLYMOUTHSCRIPT

mkdir -p /etc/plymouth
cat > /etc/plymouth/plymouthd.conf << 'PLYMOUTHD'
[Daemon]
Theme=kibaos
ShowDelay=0
DeviceTimeout=8
PLYMOUTHD

plymouth-set-default-theme -R kibaos 2>/dev/null || true
echo "=== Boot splash: custom kibaos Plymouth theme installed ==="

cp "${KIBA_PLYMOUTH_DIR}/splash.png" /usr/share/plymouth/arch-logo.png
for _theme_dir in bgrt spinner; do
  if [ -d "/usr/share/plymouth/themes/${_theme_dir}" ]; then
    cp "${KIBA_PLYMOUTH_DIR}/splash.png" \
       "/usr/share/plymouth/themes/${_theme_dir}/watermark.png"
  fi
done

NUMIX_ICONS_BUILD="/tmp/numix-icon-theme-circle"
rm -rf "${NUMIX_ICONS_BUILD}"
git clone --depth 1 https://github.com/numixproject/numix-icon-theme-circle.git "${NUMIX_ICONS_BUILD}"
cp -r "${NUMIX_ICONS_BUILD}/Numix-Circle" "${NUMIX_ICONS_BUILD}/Numix-Circle-Light" /usr/share/icons/
gtk-update-icon-cache -f /usr/share/icons/Numix-Circle 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/Numix-Circle-Light 2>/dev/null || true
rm -rf "${NUMIX_ICONS_BUILD}"
echo "=== Icon theme: Numix Circle installed ==="

WINAPPS_SRC="/opt/kibaos/winapps-src"
rm -rf "${WINAPPS_SRC}"
mkdir -p "$(dirname "${WINAPPS_SRC}")"
git clone --depth 1 https://github.com/winapps-org/winapps.git "${WINAPPS_SRC}"
chmod +x "${WINAPPS_SRC}/setup.sh" "${WINAPPS_SRC}/bin/"* 2>/dev/null || true
echo "=== WinApps: vendored $(git -C "${WINAPPS_SRC}" rev-parse --short HEAD) ==="

mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/kibaos-winapps.conf << 'IPTABLESMODS'
ip_tables
iptable_nat
IPTABLESMODS
echo "=== WinApps: ip_tables/iptable_nat set to load at boot ==="

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

flatpak install --system --noninteractive flathub re.sonny.Junction
echo "=== Junction: installed via flatpak (re.sonny.Junction) ==="

ADWAITA_ICONS="/usr/share/icons/Adwaita"
LAUNCHER_MASTER="/tmp/kibaos-launcher-icon.png"
if [ -f "${LOGO_256}" ]; then
  cp "${LOGO_256}" "${LAUNCHER_MASTER}"
else
  magick -size 512x512 xc:none \
    -fill black -draw "circle 256,256 256,16" \
    -stroke white -strokewidth 20 -fill none -draw "circle 256,256 256,60" \
    "${LAUNCHER_MASTER}"
fi

if [ -d "${ADWAITA_ICONS}" ]; then
  find "${ADWAITA_ICONS}" -path '*/places/start-here-symbolic.svg' -print0 2>/dev/null \
    | while IFS= read -r -d '' _svg; do
        _dir=$(dirname "${_svg}")
        _size=$(basename "$(dirname "${_dir}")")   # e.g. "48x48", or "scalable"
        _px="${_size%%x*}"
        case "${_px}" in
          ''|*[!0-9]*) _px=256 ;;   # "scalable" or anything unparsable -> high-res master
        esac
        magick "${LAUNCHER_MASTER}" -filter Lanczos -resize "${_px}x${_px}" \
          "${_dir}/start-here-symbolic.png"
        rm -f "${_svg}"
      done
  gtk-update-icon-cache -f "${ADWAITA_ICONS}" 2>/dev/null || true
fi
rm -f "${LAUNCHER_MASTER}"
echo "=== Taskbar launcher icon: KibaOS boot-logo badge installed ==="

mkdir -p /usr/share/themes/KibaOS/gtk-3.0
mkdir -p /usr/share/themes/KibaOS/gtk-4.0

mkdir -p /etc/gtk-3.0
cat > /etc/gtk-3.0/settings.ini << 'GTK3RC'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Numix-Circle
gtk-font-name=Nunito 11
gtk-cursor-theme-size=24
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=rgb
GTK3RC

mkdir -p /etc/gtk-4.0
cat > /etc/gtk-4.0/settings.ini << 'GTK4RC'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Numix-Circle
GTK4RC

mkdir -p /usr/share/Kvantum/KibaOS/config
mkdir -p /usr/share/Kvantum/KibaOS/Translations
chmod -R 755 /usr/share/Kvantum/KibaOS

echo "[General]
Theme=KibaOS" > /etc/xdg/kvantum.kvconfig

cat > /etc/gtk-3.0/gtk.css << 'GTK3PANEL'
/* ════════════════════════════════════════════════════════════════════════
 * KibaOS Organic Motion Language
 * Nothing alive moves with symmetric, linear timing — things settle into
 * rest faster than they drift away from it. These three curves (named for
 * documentation; GTK CSS has no custom-property/var() support, so the
 * literal cubic-bezier values are repeated at each use site below) encode
 * that asymmetry instead of using GTK's default flat "ease":
 *
 *   settle  cubic-bezier(0.22, 1, 0.36, 1)     — easeOutQuint. Entering a
 *           state (hover, focus, opening). Quick, confident, no bounce.
 *   fade    cubic-bezier(0.5, 0, 0.75, 0)       — easeInQuart. Leaving a
 *           state. Slightly slower than settle — things drift off, they
 *           don't snap off.
 *   spring  cubic-bezier(0.34, 1.56, 0.64, 1)   — easeOutBack. Reserved
 *           for ONE thing only: the physical switch knob, where a small
 *           positional overshoot reads as a twig springing back rather
 *           than a robotic snap. Used nowhere else — overusing overshoot
 *           reads as cartoonish rather than organic.
 *   grow    cubic-bezier(0.16, 1, 0.3, 1)       — easeOutExpo. Reserved
 *           for STRUCTURAL reveals (Raven and the Budgie Menu appearing/
 *           dismissing), never for small in-place state changes. A leaf
 *           unfurling and a light switching on are different kinds of
 *           motion even though both are "something turning on" — settle
 *           is the latter (a value flips, fast and certain), grow is the
 *           former (a whole shape is arriving, slightly unhurried at the
 *           start before resolving quickly). Kept distinct from settle
 *           so the two don't blur into a single generic "ease-ish" feel.
 *
 * Organic radius scale — every corner-radius below is a mild asymmetric
 * quad (top-left top-right bottom-right bottom-left) instead of one flat
 * number on all four corners. The spread is deliberately small (2-6px on
 * surfaces in the 16-28px range) so it reads as machined-but-grown at a
 * glance — closer to a river stone or a leaf edge than a die-cut card —
 * without tipping into the blobby/cartoonish territory a bigger spread
 * would. Applied only to the handful of surfaces that carry the brand
 * (panel, Raven, Budgie Menu, OSD, tooltips, context menus), not to every
 * button and row — restraint matters more than coverage here.
 *
 * Caveat: this only governs GTK widget-state transitions — it's NOT doing
 * compositor-level window drag physics. KWin does ship its own Wobbly
 * Windows effect, but it isn't enabled by default in this image (see the
 * KWIN CONFIG section for the whole story on that), so window dragging is
 * flat/rigid movement for now — nothing to verify here, it's just off
 * until/unless that effect gets turned on. Raven/the Budgie Menu's
 * open/close slide is still Budgie's own compiled animation code, not GTK
 * CSS — the opacity transitions below are best-effort and may be
 * superseded by that native motion. Verify visually.
 * ════════════════════════════════════════════════════════════════════════ */

/* === KibaOS: Floating rounded-rectangle panel === */
.budgie-panel {
    margin: 0 120px 8px 120px;
    /* Square corners -- no rounding at all. */
    border-radius: 0;
    /* Frosted glass, dark: semi-transparent navy with a faint top-down
     * light gradient and a bright hairline border for the "glass edge".
     * GTK3 CSS has NO backdrop-filter, so the actual blur-behind can't be
     * done from here -- it needs compositor support (KWin's Blur effect).
     * Under labwc this renders as translucent tinted glass, not blurred. */
    background-image: linear-gradient(to bottom,
        rgba(255, 255, 255, 0.14), rgba(255, 255, 255, 0.04));
    background-color: rgba(20, 28, 44, 0.55);
    color: #e8eef5;
    border: 1px solid rgba(255, 255, 255, 0.20);
    box-shadow:
        inset 0 1px 0 rgba(255, 255, 255, 0.22),
        0 8px 32px rgba(0, 0, 0, 0.35),
        0 2px 8px  rgba(0, 0, 0, 0.20);
    padding: 0 10px;
}
.budgie-panel .budgie-applet-button,
.budgie-panel button.flat {
    border-radius: 0;
    background: transparent;
    color: #e8eef5;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0); /* fade out */
}
.budgie-panel .budgie-applet-button:hover,
.budgie-panel button.flat:hover {
    background-color: rgba(255, 255, 255, 0.12);
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1); /* settle in */
}
.budgie-panel .budgie-applet-button:active,
.budgie-panel button.flat:active {
    background-color: rgba(0, 153, 204, 0.35);
    transition: background-color 90ms cubic-bezier(0.22, 1, 0.36, 1);
}
.budgie-panel .launcher:checked,
.budgie-panel .launcher.running {
    border-bottom: 2px solid #0099cc;
    border-radius: 0;
    transition: border-color 200ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* === KibaOS: Raven (notification + quick-settings sidebar) as a floating glass card === */
frame.raven-frame,
.raven-background {
    margin: 8px 8px 8px 0;
    border-radius: 20px 26px 24px 28px;
    background-image: radial-gradient(ellipse at 80% -20%,
        rgba(127, 174, 134, 0.05), transparent 60%);
    background-color: rgba(16, 24, 40, 0.72);
    border: 1px solid rgba(255, 255, 255, 0.14);
    box-shadow:
        0 12px 48px rgba(0, 0, 0, 0.50),
        inset 0 1px 0 rgba(255, 255, 255, 0.10);
    opacity: 1;
    transition: opacity 280ms cubic-bezier(0.16, 1, 0.3, 1); /* grow — structural reveal, best-effort, see note above */
}
frame.raven-frame > border { border-style: none; box-shadow: none; }
.raven-header,
.raven-section-header {
    color: #e8eef5;
    font-weight: 600;
    padding: 14px 18px 6px 18px;
}
/* notification + applet rows rendered as individual cards */
.raven-background row,
.raven-background list row {
    margin: 5px 12px;
    padding: 10px 12px;
    border-radius: 14px;
    background-color: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.06);
    transition: background-color 240ms cubic-bezier(0.5, 0, 0.75, 0);
}
.raven-background row:hover {
    background-color: rgba(255, 255, 255, 0.10);
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1);
}
/* quick-toggle pills: wifi / bluetooth / focus / airplane mode, etc. */
.raven-background button.toggle,
.raven-background .quick-toggle {
    border-radius: 16px;
    background-color: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.08);
    padding: 10px;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    220ms cubic-bezier(0.5, 0, 0.75, 0);
}
.raven-background button.toggle:checked,
.raven-background .quick-toggle:checked {
    background-color: rgba(0, 153, 204, 0.35);
    border-color: rgba(0, 153, 204, 0.6);
    transition: background-color 160ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    160ms cubic-bezier(0.22, 1, 0.36, 1);
}
/* volume / brightness sliders as rounded pill tracks */
.raven-background scale trough {
    border-radius: 999px;
    background-color: rgba(255, 255, 255, 0.10);
    min-height: 6px;
}
.raven-background scale highlight {
    border-radius: 999px;
    background-color: #0099cc;
    transition: background-color 200ms cubic-bezier(0.22, 1, 0.36, 1);
}
.raven-background scale slider {
    background-color: #ffffff;
    border-radius: 999px;
    min-width: 14px;
    min-height: 14px;
}

/* === KibaOS: Budgie Menu (app launcher popover) as a floating glass card === */
popover.budgie-menu,
.budgie-menu-window {
    border-radius: 22px 28px 20px 26px;
    background-image: radial-gradient(ellipse at 20% -30%,
        rgba(127, 174, 134, 0.05), transparent 60%);
    background-color: rgba(16, 24, 40, 0.80);
    border: 1px solid rgba(255, 255, 255, 0.14);
    box-shadow: 0 12px 48px rgba(0, 0, 0, 0.50);
    transition: opacity 260ms cubic-bezier(0.16, 1, 0.3, 1); /* grow — structural reveal, best-effort, see note above */
}
.budgie-menu-window entry,
popover.budgie-menu entry {
    border-radius: 999px;
    background-color: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.10);
    padding: 8px 16px;
    color: #e8eef5;
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    200ms cubic-bezier(0.5, 0, 0.75, 0);
}
.budgie-menu-window entry:focus,
popover.budgie-menu entry:focus {
    background-color: rgba(255, 255, 255, 0.12);
    border-color: rgba(0, 153, 204, 0.6);
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    140ms cubic-bezier(0.22, 1, 0.36, 1);
}
button.budgie-menu-launcher {
    border-radius: 14px;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0);
}
button.budgie-menu-launcher:hover {
    background-color: rgba(0, 153, 204, 0.20);
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* === KibaOS: GTK places sidebar (Nemo + GTK open/save dialogs) glass card === */
placessidebar {
    background-color: transparent;
    border-radius: 18px;
}
placessidebar row {
    border-radius: 12px;
    margin: 2px 6px;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0);
}
placessidebar row:selected {
    background-color: rgba(0, 153, 204, 0.25);
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* === KibaOS: switches everywhere (budgie-control-center, GTK apps) ========
 * The one and only spot using the "spring" overshoot curve — the knob
 * physically travels, so a little organic overshoot is visible motion,
 * not just a colour flicker. */
switch slider {
    transition: margin 260ms cubic-bezier(0.34, 1.56, 0.64, 1);
}
switch:checked {
    background-color: rgba(0, 153, 204, 0.85);
    transition: background-color 220ms cubic-bezier(0.22, 1, 0.36, 1);
}
switch {
    transition: background-color 240ms cubic-bezier(0.5, 0, 0.75, 0);
}

/* ════════════════════════════════════════════════════════════════════════
 * KibaOS extra polish pass — the small stuff that adds up
 * ════════════════════════════════════════════════════════════════════════ */

/* Crisp, on-brand focus rings instead of GTK's default dotted/heavy outline —
 * keyboard navigation should always be obvious, never ugly. */
*:focus-visible {
    outline: 2px solid rgba(0, 153, 204, 0.75);
    outline-offset: 1px;
    transition: outline-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Tooltips as small glass cards, matching Raven/the menu popover language
 * instead of GTK's flat dark rectangle. */
tooltip {
    background-color: rgba(20, 26, 40, 0.92);
    color: #e8eef5;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px 12px 9px 11px;
    padding: 6px 10px;
    box-shadow: 0 6px 18px rgba(0, 0, 0, 0.45);
}
tooltip decoration { background: transparent; box-shadow: none; }

/* Thin, rounded, low-profile scrollbars — always present but never loud. */
scrollbar {
    background-color: transparent;
}
scrollbar slider {
    background-color: rgba(255, 255, 255, 0.18);
    border-radius: 999px;
    min-width: 6px;
    min-height: 6px;
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
scrollbar slider:hover {
    background-color: rgba(255, 255, 255, 0.32);
    transition: background-color 130ms cubic-bezier(0.22, 1, 0.36, 1);
}
scrollbar slider:active {
    background-color: rgba(0, 153, 204, 0.65);
}

/* Selected text uses the accent colour, not GTK's default blue. */
selection, *:selected {
    background-color: rgba(0, 153, 204, 0.55);
    color: #ffffff;
}

/* Checkboxes/radios: rounded box, accent fill when checked, same settle/fade
 * pair as everything else — these were the one obviously-untouched stock
 * GTK widget left standing next to switches/sliders that already got it. */
checkbutton check,
radiobutton radio {
    border-radius: 5px;
    border: 1px solid rgba(255, 255, 255, 0.28);
    background-color: rgba(255, 255, 255, 0.06);
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    200ms cubic-bezier(0.5, 0, 0.75, 0);
}
radiobutton radio { border-radius: 999px; }
checkbutton check:checked,
radiobutton radio:checked {
    background-color: #0099cc;
    border-color: #0099cc;
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    150ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Progress bars: rounded pill track matching the volume/brightness sliders
 * in Raven, instead of GTK's square-edged default. */
progressbar trough {
    border-radius: 999px;
    background-color: rgba(255, 255, 255, 0.10);
    min-height: 6px;
}
progressbar progress {
    border-radius: 999px;
    background-color: #0099cc;
    transition: background-color 200ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Right-click / app context menus as the same floating glass card as
 * Raven and the Budgie Menu, instead of a flat GTK menu rectangle. */
menu,
popover.menu > contents {
    background-color: rgba(20, 26, 40, 0.92);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 10px 14px 11px 13px;
    box-shadow: 0 10px 32px rgba(0, 0, 0, 0.45);
    padding: 4px;
}
menuitem,
modelbutton {
    border-radius: 8px;
    padding: 6px 10px;
    transition: background-color 180ms cubic-bezier(0.5, 0, 0.75, 0);
}
menuitem:hover,
modelbutton:hover {
    background-color: rgba(255, 255, 255, 0.10);
    transition: background-color 120ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* The volume/brightness/etc. on-screen bezel (.osd) as a small floating
 * glass pill, matching everything else instead of GTK's plain dark box. */
.osd {
    background-color: rgba(16, 24, 40, 0.85);
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 18px 24px 20px 22px;
    box-shadow: 0 12px 36px rgba(0, 0, 0, 0.50);
}

/* Unfocused windows recede slightly — a small depth cue that makes the
 * focused window unambiguous at a glance, especially with several floating
 * glass panels/popovers on screen at once. */
window:backdrop {
    opacity: 0.96;
    transition: opacity 300ms cubic-bezier(0.5, 0, 0.75, 0);
}
window:not(:backdrop) {
    transition: opacity 180ms cubic-bezier(0.22, 1, 0.36, 1);
}

/* Linked button groups (segmented controls) read as one pill-shaped
 * control instead of GTK's default row of square-joined buttons. */
.linked > button {
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
.linked > button:first-child { border-radius: 10px 0 0 10px; }
.linked > button:last-child  { border-radius: 0 10px 10px 0; }
GTK3PANEL

mkdir -p /etc/gtk-4.0
cat > /etc/gtk-4.0/gtk.css << 'GTK4CSS'
/* KibaOS unified GTK4 override */
@define-color accent_color #0099cc;
@define-color accent_bg_color #0099cc;
@define-color accent_fg_color #ffffff;
@define-color window_bg_color #1e2430;
@define-color window_fg_color #e8eef5;
@define-color view_bg_color #252c3a;
@define-color view_fg_color #dde5ef;
@define-color card_bg_color #2a3242;
@define-color popover_bg_color #2a3242;
@define-color sidebar_bg_color #1a2030;
@define-color headerbar_bg_color #1a2030;
@define-color headerbar_fg_color #dde5ef;

window, .window-frame          { border-radius: 16px 20px 18px 22px; }
headerbar                      { border-radius: 18px 22px 0 0; }
.card, frame, .frame           { border-radius: 13px 16px 14px 17px; }
button                         { border-radius: 10px; }
entry                          { border-radius: 10px; }
popover > contents             { border-radius: 14px 18px 13px 17px; }
.sidebar-row                   { border-radius: 8px; }
listview                       { border-radius: 12px; }
notebook > header              { border-radius: 12px 12px 0 0; }
button { box-shadow: none; -gtk-icon-shadow: none; }
.suggested-action { background: @accent_bg_color; color: @accent_fg_color; border: none; }
.suggested-action:hover { background: shade(@accent_bg_color, 0.88); }
headerbar { padding: 8px 12px; min-height: 44px; }
row        { padding: 4px 8px; }
/* Same faint moss-green (#7fae86) bloom as the GTK3 panel — the one
 * deliberate nature accent, kept identical across GTK3/GTK4 so a mixed
 * Budgie+libadwaita desktop still reads as one coherent surface. */
window {
    background-image: radial-gradient(ellipse at 30% -30%,
        rgba(127, 174, 134, 0.04), transparent 65%);
}

/* KibaOS organic motion — same settle/fade/grow set as GTK3 (see
 * gtk-3.0/gtk.css for the full naming/rationale); GTK4 apps get the same
 * asymmetric feel. */
button, row, .sidebar-row, switch slider {
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0),
                border-color    220ms cubic-bezier(0.5, 0, 0.75, 0);
}
button:hover, row:hover, .sidebar-row:hover {
    transition: background-color 140ms cubic-bezier(0.22, 1, 0.36, 1),
                border-color    140ms cubic-bezier(0.22, 1, 0.36, 1);
}
switch slider { transition: margin 260ms cubic-bezier(0.34, 1.56, 0.64, 1); }
popover > contents {
    transition: opacity 260ms cubic-bezier(0.16, 1, 0.3, 1); /* grow — structural reveal */
}

/* Same extra polish pass as gtk-3.0/gtk.css (see that file for the full
 * rationale on each rule) — GTK4/libadwaita apps get the same treatment
 * as Budgie's own chrome instead of looking like a different OS. */
*:focus-visible {
    outline: 2px solid rgba(0, 153, 204, 0.75);
    outline-offset: 1px;
    transition: outline-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}
tooltip {
    background-color: rgba(20, 26, 40, 0.92);
    color: #e8eef5;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 8px 12px 9px 11px;
    padding: 6px 10px;
    box-shadow: 0 6px 18px rgba(0, 0, 0, 0.45);
}
scrollbar slider {
    background-color: rgba(255, 255, 255, 0.18);
    border-radius: 999px;
    min-width: 6px;
    min-height: 6px;
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
scrollbar slider:hover {
    background-color: rgba(255, 255, 255, 0.32);
    transition: background-color 130ms cubic-bezier(0.22, 1, 0.36, 1);
}
selection, *:selected {
    background-color: rgba(0, 153, 204, 0.55);
    color: #ffffff;
}
checkbutton check,
radiobutton radio {
    border-radius: 5px;
    border: 1px solid rgba(255, 255, 255, 0.28);
    background-color: rgba(255, 255, 255, 0.06);
    transition: background-color 200ms cubic-bezier(0.5, 0, 0.75, 0);
}
radiobutton radio { border-radius: 999px; }
checkbutton check:checked,
radiobutton radio:checked {
    background-color: #0099cc;
    border-color: #0099cc;
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1);
}
.osd {
    background-color: rgba(16, 24, 40, 0.85);
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 18px 24px 20px 22px;
    box-shadow: 0 12px 36px rgba(0, 0, 0, 0.50);
}
window:backdrop {
    opacity: 0.96;
    transition: opacity 300ms cubic-bezier(0.5, 0, 0.75, 0);
}

/* libadwaita toasts (AdwToast — the little "Undo" bar that slides up from
 * the bottom) as the same floating glass pill as everything else. */
.toast {
    background-color: rgba(20, 26, 40, 0.92);
    color: #e8eef5;
    border: 1px solid rgba(255, 255, 255, 0.14);
    border-radius: 999px;
    box-shadow: 0 10px 32px rgba(0, 0, 0, 0.45);
    padding: 4px 6px;
}
.toast button {
    border-radius: 999px;
}
GTK4CSS

mkdir -p /usr/share/glib-2.0/schemas
cat > /usr/share/glib-2.0/schemas/zz-kibaos-budgie.gschema.override << 'BUDGIEOVERRIDE'
[com.solus-project.budgie-panel]
enable-built-in-theme=false
BUDGIEOVERRIDE
glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null || true

mkdir -p /etc/dconf/profile /etc/dconf/db/gdm.d
cat > /etc/dconf/profile/gdm << 'GDMPROFILE'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
GDMPROFILE

cp /usr/share/kibaos/wallpaper.jpg /usr/share/kibaos/gdm-background.jpg 2>/dev/null || true
cat > /etc/dconf/db/gdm.d/01-kibaos << 'GDMDCONF'
[org/gnome/desktop/background]
picture-uri='file:///usr/share/kibaos/gdm-background.jpg'
picture-uri-dark='file:///usr/share/kibaos/gdm-background.jpg'
picture-options='zoom'

[org/gnome/desktop/interface]
color-scheme='prefer-dark'

[org/gnome/login-screen]
logo='/usr/share/kibaos/logo-256.png'
disable-user-list=false
GDMDCONF
dconf update

: << 'DEAD_SDDM_THEME_BLOCK'
SDDM_THEME_DIR="/usr/share/sddm/themes/kibaos"
mkdir -p "${SDDM_THEME_DIR}"
cp /usr/share/kibaos/wallpaper.jpg  "${SDDM_THEME_DIR}/background.png"  2>/dev/null || true
cp /usr/share/kibaos/logo-256.png   "${SDDM_THEME_DIR}/logo.png"        2>/dev/null || true

cat > "${SDDM_THEME_DIR}/metadata.desktop" << 'SDDMMETA'
[SddmGreeterTheme]
Name=KibaOS
Description=KibaOS frosted-glass greeter
Author=WolfTech Innovations
Copyright=2026, WolfTech Innovations
License=GPLv3
Type=sddm-theme
Version=1.0
Website=https://github.com/WolfTech-Innovations/Kiba
MainScript=Main.qml
Font=Nunito
QuickVersion=6
SDDMMETA

cat > "${SDDM_THEME_DIR}/Main.qml" << 'SDDMQML'
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Single shared greeter for both the desktop ISO and KibaOS Mobile --
// this exact file is written byte-for-byte into both images (see the
// mobile copy inside build_kibaos_mobile(), which carries a comment
// pointing back here -- keep the two in sync by hand, they can't
// literally share a bash variable since they run inside two different
// execution contexts: this one at ISO customize time inside a chroot,
// the mobile one directly against the target root while build.sh itself
// runs). Rather than branching into two separate QML files, the layout
// adapts itself at runtime off Screen.width, so a genuinely single
// theme covers a 1920x1080 desktop panel and a ~1080x2400 phone panel
// without drifting out of sync on brand/behavior over time.
Rectangle {
    id: root
    width: Screen.width  > 0 ? Screen.width  : 1920
    height: Screen.height > 0 ? Screen.height : 1080
    color: "#0d1b2a"
    focus: true

    // phoc's own config scales the DSI panel output 2x at the Wayland
    // protocol level (see phoc.ini's [output:DSI-1] scale=2) -- Qt's
    // Wayland QPA backend reads that wl_output scale itself and already
    // renders this file's logical pixels at the right physical density,
    // so nothing extra is needed here for HiDPI; this width/height check
    // is purely about aspect ratio/orientation, not pixel density.
    readonly property bool isPhone: width < 700
    readonly property int touchH: isPhone ? 56 : 44
    readonly property int fieldR: isPhone ? 18 : 14

    property int sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0

    // ── Background wallpaper, darkened so the glass card pops ──────────────
    Image {
        anchors.fill: parent
        source: "background.png"
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
    Rectangle {
        anchors.fill: parent
        color: "#0d1b2a"
        opacity: 0.42
    }

    // ── Clock ────────────────────────────────────────────────────────────
    // Desktop: small pill, top-right, matches the KibaOS panel style.
    // Phone: big lockscreen-style clock, top-center, clear of any status
    // bar / camera-cutout safe area -- Android/iOS lockscreen convention,
    // and it doubles as a landmark while your thumb finds the card below.
    Column {
        id: clockCol
        anchors {
            top: parent.top
            topMargin: isPhone ? 64 : 28
        }
        anchors.horizontalCenter: isPhone ? parent.horizontalCenter : undefined
        anchors.right: isPhone ? undefined : parent.right
        anchors.rightMargin: isPhone ? 0 : 28
        spacing: isPhone ? 4 : 0
        Text {
            id: clockTime
            text: Qt.formatTime(new Date(), "h:mm AP")
            color: "#ffffff"
            font.pixelSize: isPhone ? 56 : 18
            font.weight: Font.Medium
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: Qt.formatDate(new Date(), "ddd, MMM d")
            color: "#aebccd"
            font.pixelSize: isPhone ? 16 : 11
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Timer { interval: 1000; running: true; repeat: true; onTriggered: clockTime.text = Qt.formatTime(new Date(), "h:mm AP") }
    }

    // ── Central frosted-glass login card ────────────────────────────────────
    // Desktop: fixed 360px, dead-centered, unchanged from before.
    // Phone: full-width (minus margins), anchored in the lower half
    // rather than dead-center -- that's within comfortable one-handed
    // thumb reach, and critically it leaves the *upper* half of the
    // screen clear for squeekboard to pop up underneath without ever
    // covering the password field it's currently focused on.
    Rectangle {
        id: card
        anchors {
            horizontalCenter: isPhone ? parent.horizontalCenter : undefined
            centerIn: isPhone ? undefined : parent
            bottom: isPhone ? parent.bottom : undefined
            bottomMargin: isPhone ? 96 : 0
        }
        width: isPhone ? parent.width - 48 : 360
        height: cardCol.implicitHeight + (isPhone ? 40 : 56)
        radius: isPhone ? 32 : 26
        color: "#101828"
        opacity: 0.001
        // emulated glass: just a solid translucent fill, no real blur.
        // KWin's own Blur effect is real and available in the actual
        // session, but the SDDM greeter renders on its own standalone
        // Qt Quick surface before any session (or its compositor) is
        // even running — see KWIN CONFIG notes for the full story on
        // why this greeter can't just borrow it — so this fake-glass
        // approach is doing all the work here now, not just backstopping
        // a spot where real blur wouldn't reach anyway.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Qt.rgba(0.063, 0.094, 0.157, 0.72)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
        }

        ColumnLayout {
            id: cardCol
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: isPhone ? 24 : 28 }
            spacing: isPhone ? 16 : 14

            Image {
                Layout.alignment: Qt.AlignHCenter
                source: "logo.png"
                width: isPhone ? 56 : 64; height: isPhone ? 56 : 64
                fillMode: Image.PreserveAspectFit
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: userModel.count > 0 ? userModel.data(userModel.index(userList.currentIndex, 0), 257) : "User"
                color: "#e8eef5"; font.pixelSize: isPhone ? 19 : 17; font.weight: Font.Medium
            }

            ListView {
                id: userList
                Layout.fillWidth: true
                height: 0; visible: false  // names shown via combo below instead
                model: userModel
                currentIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
            }

            ComboBox {
                id: userBox
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                model: userModel
                textRole: "name"
                currentIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
                font.pixelSize: isPhone ? 16 : 13
                background: Rectangle { radius: fieldR; color: Qt.rgba(1,1,1,0.07); border.width: 1; border.color: Qt.rgba(1,1,1,0.10) }
                contentItem: Text { text: userBox.displayText; color: "#e8eef5"; font: userBox.font; padding: 10; verticalAlignment: Text.AlignVCenter }
            }

            TextField {
                id: passwordField
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                placeholderText: "Password"
                echoMode: TextInput.Password
                color: "#e8eef5"
                font.pixelSize: isPhone ? 16 : 13
                placeholderTextColor: "#8a99ad"
                background: Rectangle { radius: fieldR; color: Qt.rgba(1,1,1,0.07); border.width: 1; border.color: Qt.rgba(1,1,1,0.10) }
                onAccepted: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
                Keys.onReturnPressed: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
            }

            Button {
                id: loginButton
                Layout.fillWidth: true
                Layout.preferredHeight: touchH
                text: "Sign In"
                onClicked: sddm.login(userBox.currentText, passwordField.text, root.sessionIndex)
                background: Rectangle { radius: fieldR; color: "#0099cc" }
                contentItem: Text { text: loginButton.text; color: "#ffffff"; font.pixelSize: isPhone ? 16 : 13; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
            }

            // Session picker: only worth showing where there's actually
            // more than one to pick from. Desktop offers Budgie/etc
            // session choices; the phone image ships exactly one
            // (kibaos-mobile, Exec=phoc) so this is dead weight there --
            // one less thing to accidentally fat-finger on a small card.
            ComboBox {
                Layout.fillWidth: true
                Layout.preferredHeight: isPhone ? 0 : undefined
                visible: !isPhone
                model: sessionModel
                textRole: "name"
                currentIndex: root.sessionIndex
                onActivated: root.sessionIndex = currentIndex
                background: Rectangle { radius: fieldR; color: "transparent" }
                contentItem: Text { text: parent.displayText; color: "#aebccd"; font.pixelSize: 11; padding: 6; horizontalAlignment: Text.AlignHCenter }
            }
        }
    }

    // ── Power row ────────────────────────────────────────────────────────
    // Desktop: small 44px pills, bottom-right, unchanged.
    // Phone: bigger 56px targets (comfortable thumb-tap size), moved to
    // top-right instead -- bottom-right on a phone sits right where the
    // login card's bottom edge and any on-screen-keyboard region already
    // are, so it's both more reachable and less likely to be covered.
    Row {
        anchors {
            top: isPhone ? parent.top : undefined
            bottom: isPhone ? undefined : parent.bottom
            right: parent.right
            margins: isPhone ? 24 : 28
        }
        spacing: isPhone ? 14 : 10
        Repeater {
            model: [
                { label: "⏻", visible: sddm.canPowerOff, action: function(){ sddm.powerOff() } },
                { label: "⟲", visible: sddm.canReboot,   action: function(){ sddm.reboot()   } }
            ]
            delegate: Rectangle {
                visible: modelData.visible
                width: touchH; height: touchH; radius: fieldR
                color: "#1c2433"; opacity: 0.78
                Text { anchors.centerIn: parent; text: modelData.label; color: "#e8eef5"; font.pixelSize: isPhone ? 22 : 18 }
                MouseArea { anchors.fill: parent; onClicked: modelData.action() }
            }
        }
    }

    Connections {
        target: sddm
        function onLoginFailed() { passwordField.text = ""; passwordField.placeholderText = "Incorrect password"; }
    }

    Component.onCompleted: passwordField.forceActiveFocus()
}
SDDMQML
DEAD_SDDM_THEME_BLOCK

mkdir -p /usr/share/wayland-sessions
rm -rf /usr/share/wayland-sessions/budgie-desktop.desktop
cat > /usr/share/wayland-sessions/budgie-desktop.desktop << 'WFSESSION'
[Desktop Entry]
Name=Budgie Desktop on labwc
Comment=This session logs you into the Budgie Desktop
Exec=/usr/bin/labwc --session=/usr/bin/budgie-desktop
Icon=
Type=Application
DesktopNames=Budgie;GNOME
WFSESSION

SKEL="/etc/skel"
mkdir -p "${SKEL}/.config/autostart"
cat > "${SKEL}/.config/autostart/org.buddiesofbudgie.labwc-bridge.desktop" << 'NOLABWCBRIDGE'
[Desktop Entry]
Type=Application
Name=Budgie labwc bridge (disabled — KibaOS runs labwc, not labwc)
Exec=/bin/true
Hidden=true
NOLABWCBRIDGE
rm -rf "${SKEL}/.config/budgie-desktop/labwc" 2>/dev/null || true

mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf << 'GDMCONF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=liveuser
WaylandEnable=true
GDMCONF
mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/liveuser << 'LIVEUSERACCOUNTS'
[User]
Session=budgie-desktop
XSession=budgie-desktop
SystemAccount=false
LIVEUSERACCOUNTS
mkdir -p /var/lib/gdm /var/log/gdm
chown gdm:gdm /var/lib/gdm /var/log/gdm 2>/dev/null || true
chmod 750 /var/lib/gdm
cat > /usr/local/bin/kibaos-screenshot << 'SCREENSHOT'
#!/bin/bash
set -euo pipefail
OUT_DIR="$HOME/Pictures/Screenshots"
mkdir -p "$OUT_DIR"
FILE="$OUT_DIR/Screenshot from $(date '+%Y-%m-%d %H-%M-%S').png"

if [ "${1:-}" = "region" ]; then
  GEOM=$(slurp) || exit 0   # empty selection (Esc) -> exit quietly
  grim -g "$GEOM" "$FILE"
else
  grim "$FILE"
fi

wl-copy < "$FILE"
notify-send -i "$FILE" "Screenshot saved" "Copied to clipboard · $(basename "$FILE")"
SCREENSHOT
chmod +x /usr/local/bin/kibaos-screenshot
cat > /usr/local/bin/kibaos-screenshot-ocr << 'SCREENSHOTOCR'
#!/bin/bash
set -euo pipefail
GEOM=$(slurp) || exit 0
TMP=$(mktemp --suffix=.png -t kibaos-ocr.XXXXXX)
trap 'rm -f "$TMP"' EXIT
grim -g "$GEOM" "$TMP"

TEXT=$(tesseract "$TMP" - 2>/dev/null | sed -e '$ { /^$/d }')
if [ -z "$TEXT" ]; then
  notify-send "Screenshot OCR" "No text found in that selection."
  exit 0
fi

printf '%s' "$TEXT" | wl-copy
PREVIEW=$(printf '%s' "$TEXT" | head -c 120)
notify-send "Text copied to clipboard" "${PREVIEW}$([ ${#TEXT} -gt 120 ] && echo …)"
SCREENSHOTOCR
chmod +x /usr/local/bin/kibaos-screenshot-ocr
cat > /usr/local/bin/kibaos-apply-output-scale << 'OUTPUTSCALE'
#!/bin/bash
for _ in 1 2 3 4 5; do
    wlr-randr >/tmp/.kiba-outputs 2>/dev/null && [ -s /tmp/.kiba-outputs ] && break
    sleep 1
done
[ -s /tmp/.kiba-outputs ] || exit 0

current_name=""
current_w=""
current_h=""
current_mm_w=""
current_mm_h=""

apply_scale() {
    [ -n "$current_name" ] || return
    scale=1
    if [ -n "$current_mm_w" ] && [ "$current_mm_w" -gt 0 ] 2>/dev/null; then
        dpi=$(( current_w * 254 / (current_mm_w * 10) ))
        if [ "$dpi" -ge 168 ]; then
            scale=2
        fi
    elif [ -n "$current_w" ] && [ "$current_w" -ge 3000 ] 2>/dev/null; then
        scale=2
    fi
    wlr-randr --output "$current_name" --scale "$scale" >/dev/null 2>&1
}

while IFS= read -r line; do
    case "$line" in
        [A-Za-z]*)
            apply_scale
            current_name=$(printf '%s' "$line" | awk '{print $1}')
            current_w=""; current_h=""; current_mm_w=""; current_mm_h=""
            ;;
        *"Physical size:"*)
            dims=$(printf '%s' "$line" | grep -oE '[0-9]+x[0-9]+')
            current_mm_w=${dims%x*}
            current_mm_h=${dims#*x}
            ;;
        *"current"*)
            dims=$(printf '%s' "$line" | grep -oE '^[[:space:]]*[0-9]+x[0-9]+' | tr -d ' ')
            current_w=${dims%x*}
            current_h=${dims#*x}
            ;;
    esac
done < /tmp/.kiba-outputs
apply_scale
rm -f /tmp/.kiba-outputs
OUTPUTSCALE
chmod +x /usr/local/bin/kibaos-apply-output-scale
OTA_PUBKEY_URL="https://raw.githubusercontent.com/WolfTech-Innovations/Kiba/main/ota/ota-public.asc"
OTA_BASE="https://sourceforge.net/projects/kibaos/files/ota"
OTA_KEYRING="/etc/kibaos/ota-keyring.gpg"
mkdir -p /etc/kibaos /var/lib/kibaos-ota /var/log/kibaos

curl -fsSL --retry 3 "${OTA_PUBKEY_URL}" -o /tmp/ota-public.asc 2>/dev/null && \
  gpg --no-default-keyring --keyring "${OTA_KEYRING}" \
      --import /tmp/ota-public.asc 2>/dev/null || true
rm -f /tmp/ota-public.asc

echo "0" > /etc/kibaos/patch-level

cat > /usr/local/bin/kibaos-ota << 'OTASCRIPT'
#!/usr/bin/env bash

set -euo pipefail

OTA_BASE="https://sourceforge.net/projects/kibaos/files/ota"
OTA_KEYRING="/etc/kibaos/ota-keyring.gpg"
PATCH_LEVEL_FILE="/etc/kibaos/patch-level"
OTA_WORKDIR="/var/lib/kibaos-ota"
OTA_LOG="/var/log/kibaos/ota.log"
FREEZE_PID_FILE="/tmp/kibaos-fb-freeze.pid"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${OTA_LOG}"; }

fb_freeze() {
  log "Freezing display with framebuffer snapshot..."
  SNAP="/tmp/kibaos-ota-snap.png"
  SNAP_RAW="/tmp/kibaos-ota-snap.raw"
  WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
  XDG_RUNTIME_DIR="/run/user/1000"

  runuser -u liveuser -- env \
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    grim "${SNAP}" 2>/dev/null || true

  if [ -f "${SNAP}" ]; then
    FB_WIDTH=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | cut -d',' -f1 || echo 1920)
    FB_HEIGHT=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | cut -d',' -f2 || echo 1080)
    magick "${SNAP}" -resize "${FB_WIDTH}x${FB_HEIGHT}!" \
      -depth 8 bgr:"${SNAP_RAW}" 2>/dev/null || true
    if [ -f "${SNAP_RAW}" ] && [ -w /dev/fb0 ]; then
      cat "${SNAP_RAW}" > /dev/fb0 2>/dev/null || true
    fi
  fi

  python3 - << 'UINPUT_WIGGLE' &
import struct, time, os, fcntl

EV_REL, REL_X, REL_Y = 0x02, 0x00, 0x01
EV_SYN, SYN_REPORT    = 0x00, 0x00

def emit(fd, typ, code, val):
    fd.write(struct.pack('llHHi', 0, 0, typ, code, val))

try:
    UI_SET_EVBIT  = 0x40045564
    UI_SET_RELBIT = 0x40045566
    UINPUT_DEV_SZ = 1452 + 4 * (64 + 64 + 48 + 48)
    UI_DEV_CREATE = 0x5501
    UI_DEV_DESTROY= 0x5502

    fd = open('/dev/uinput', 'wb', buffering=0)
    fcntl.ioctl(fd, UI_SET_EVBIT,  EV_REL)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_X)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)
    dev = struct.pack('80sHHIII', b'kibaos-cursor', 0, 0, 0, 0, 0)
    dev = dev.ljust(UINPUT_DEV_SZ, b'\x00')
    fd.write(dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    for _ in range(60):
        emit(fd, EV_REL, REL_X,  1)
        emit(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(0.25)
        emit(fd, EV_REL, REL_X, -1)
        emit(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(0.25)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    fd.close()
except Exception:
    pass
UINPUT_WIGGLE
  echo $! > "${FREEZE_PID_FILE}"
  log "Framebuffer freeze active (PID $(cat ${FREEZE_PID_FILE}))."
}

fb_unfreeze() {
  if [ -f "${FREEZE_PID_FILE}" ]; then
    kill "$(cat ${FREEZE_PID_FILE})" 2>/dev/null || true
    rm -f "${FREEZE_PID_FILE}"
  fi
  rm -f /tmp/kibaos-ota-snap.png /tmp/kibaos-ota-snap.raw
  log "Framebuffer freeze released."
}

apply_patch() {
  log "Applying patch ${LATEST}..."
  ROLLBACK_DIR="${OTA_WORKDIR}/rollback-${CURRENT}"
  mkdir -p "${ROLLBACK_DIR}"

  while IFS= read -r line; do
    FILEPATH=$(echo "${line}" | awk '{print $2}' | sed 's|^\./||')
    SRC="${EXTRACT_DIR}/${FILEPATH}"
    DST="/${FILEPATH}"

    [ -f "${SRC}" ] || continue

    if [ -f "${DST}" ]; then
      BACKUP_PATH="${ROLLBACK_DIR}/${FILEPATH}"
      mkdir -p "$(dirname ${BACKUP_PATH})"
      cp -a "${DST}" "${BACKUP_PATH}"
    fi

    mkdir -p "$(dirname ${DST})"
    cp -a "${SRC}" "${DST}.ota-tmp"
    mv "${DST}.ota-tmp" "${DST}"
    log "  Patched: ${DST}"
  done < "${MANIFEST}"

  log "Patch applied."
}

rollback_patch() {
  ROLLBACK_DIR="${OTA_WORKDIR}/rollback-${CURRENT}"
  log "ROLLING BACK to patch level ${CURRENT}..."
  if [ -d "${ROLLBACK_DIR}" ]; then
    find "${ROLLBACK_DIR}" -type f | while read -r BACKUP; do
      FILEPATH="${BACKUP#${ROLLBACK_DIR}/}"
      DST="/${FILEPATH}"
      mkdir -p "$(dirname ${DST})"
      cp -a "${BACKUP}" "${DST}"
    done
    log "Rollback complete."
  else
    log "No rollback data found. Cannot roll back."
  fi
}

restart_compositor() {
  log "Restarting session..."
  systemctl restart gdm 2>/dev/null || \
  pkill -TERM labwc 2>/dev/null || \
  pkill -TERM labwc 2>/dev/null || true
  sleep 1
  log "Session restarted."
}

restart_display_manager() {
  log "Restarting GDM..."
  systemctl restart gdm
  for i in $(seq 1 20); do
    [ -S "/run/user/1000/${WAYLAND_DISPLAY:-wayland-0}" ] && break
    sleep 0.5
  done
  log "GDM restarted."
}

run_post_hooks() {
  log "Running post-patch hooks..."
  grep -q 'usr/share/icons' "${MANIFEST}" && \
    gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true
  grep -q 'usr/share/glib-2.0/schemas' "${MANIFEST}" && \
    glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null || true
  grep -q 'usr/share/mime' "${MANIFEST}" && \
    update-mime-database /usr/share/mime 2>/dev/null || true
  grep -q 'usr/lib/systemd' "${MANIFEST}" && \
    systemctl daemon-reload 2>/dev/null || true
  log "Post-patch hooks complete."
}

if [ "${1:-}" = "rollback" ]; then
  shift || true
  REASON="cli:unspecified"
  while [ $# -gt 0 ]; do
    case "${1:-}" in
      --reason) REASON="${2:-${REASON}}"; shift 2 || break ;;
      *) shift ;;
    esac
  done
  CURRENT=$(cat "${PATCH_LEVEL_FILE}" 2>/dev/null || echo 0)
  log "Manual rollback requested (reason: ${REASON})"
  if [ -d "${OTA_WORKDIR}/rollback-${CURRENT}" ]; then
    fb_freeze
    rollback_patch
    restart_compositor
    restart_display_manager
    fb_unfreeze
    log "Manual rollback finished."
    exit 0
  else
    log "No rollback data available for patch level ${CURRENT}. Nothing to roll back."
    exit 1
  fi
fi

CURRENT=$(cat "${PATCH_LEVEL_FILE}" 2>/dev/null || echo 0)
log "Current patch level: ${CURRENT}"

LATEST=$(curl -fsSL --retry 3 --max-time 10 \
  "${OTA_BASE}/latest-patch-level" 2>/dev/null | tr -d '[:space:]') || {
  log "Could not reach OTA server. Skipping."
  exit 0
}

if ! [[ "${LATEST}" =~ ^[0-9]+$ ]]; then
  log "Invalid patch level received: '${LATEST}'. Skipping."
  exit 0
fi

if [ "${LATEST}" -le "${CURRENT}" ]; then
  log "Already up to date (patch level ${CURRENT})."
  exit 0
fi

log "New patch available: ${CURRENT} → ${LATEST}"

DEV_ARCH="$(uname -m)"
PATCH_TAR="${OTA_WORKDIR}/kibaos-ota-${LATEST}-${DEV_ARCH}.tar.gz"
PATCH_SIG="${PATCH_TAR}.asc"
MANIFEST="${OTA_WORKDIR}/manifest-${LATEST}-${DEV_ARCH}.txt"

mkdir -p "${OTA_WORKDIR}"

log "Downloading patch ${LATEST} (${DEV_ARCH})..."
curl -fsSL --retry 3 --max-time 120 \
  "${OTA_BASE}/kibaos-ota-${LATEST}-${DEV_ARCH}.tar.gz" -o "${PATCH_TAR}" || {
  log "Download failed. Skipping."
  exit 0
}
curl -fsSL --retry 3 --max-time 30 \
  "${OTA_BASE}/kibaos-ota-${LATEST}-${DEV_ARCH}.tar.gz.asc" -o "${PATCH_SIG}" || {
  log "Signature download failed. Aborting for safety."
  rm -f "${PATCH_TAR}"
  exit 1
}
curl -fsSL --retry 3 --max-time 30 \
  "${OTA_BASE}/kibaos-ota-${LATEST}-${DEV_ARCH}-manifest.txt" -o "${MANIFEST}" || {
  log "Manifest download failed. Aborting."
  rm -f "${PATCH_TAR}" "${PATCH_SIG}"
  exit 1
}

log "Verifying signature..."
if ! gpg --no-default-keyring --keyring "${OTA_KEYRING}" \
         --verify "${PATCH_SIG}" "${PATCH_TAR}" 2>/dev/null; then
  log "SIGNATURE VERIFICATION FAILED. Patch rejected. Possible tampering."
  rm -f "${PATCH_TAR}" "${PATCH_SIG}" "${MANIFEST}"
  exit 1
fi
log "Signature verified."

log "Verifying checksums..."
EXTRACT_DIR="${OTA_WORKDIR}/patch-${LATEST}"
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar xzf "${PATCH_TAR}" -C "${EXTRACT_DIR}"

while IFS= read -r line; do
  EXPECTED_HASH=$(echo "${line}" | awk '{print $1}')
  FILEPATH=$(echo "${line}" | awk '{print $2}' | sed 's|^\./||')
  ACTUAL_HASH=$(sha256sum "${EXTRACT_DIR}/${FILEPATH}" 2>/dev/null | awk '{print $1}')
  if [ "${EXPECTED_HASH}" != "${ACTUAL_HASH}" ]; then
    log "CHECKSUM MISMATCH for ${FILEPATH}. Aborting."
    rm -rf "${EXTRACT_DIR}" "${PATCH_TAR}" "${PATCH_SIG}" "${MANIFEST}"
    exit 1
  fi
done < "${MANIFEST}"
log "All checksums verified."

NEEDS_DISPLAY_RESTART=false
NEEDS_COMPOSITOR_RESTART=false
while IFS= read -r line; do
  FILEPATH=$(echo "${line}" | awk '{print $2}' | sed 's|^\./||')
  case "${FILEPATH}" in
    etc/gdm*|usr/lib/gdm*|usr/bin/gdm*|usr/share/gdm*|etc/dconf/db/gdm.d*)
      NEEDS_DISPLAY_RESTART=true ;;
    usr/bin/labwc*)
      NEEDS_COMPOSITOR_RESTART=true ;;
  esac
done < "${MANIFEST}"

_active_user_info() {
  loginctl list-sessions --no-legend 2>/dev/null | while read -r _sid _uid _user _rest; do
    [ "${_user}" = "gdm" ] && continue
    [ "$(loginctl show-session "${_sid}" -p Class --value 2>/dev/null)" = "user" ] || continue
    [ "$(loginctl show-session "${_sid}" -p Active --value 2>/dev/null)" = "yes" ] || continue
    echo "${_uid} ${_user}"
    break
  done || true
}
as_desktop_user() {
  local uid="" user="" sock=""
  read -r uid user <<< "$(_active_user_info)" || true
  [ -n "${uid}" ] || return 1
  sock=$(ls "/run/user/${uid}"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n1 || true)
  runuser -u "${user}" -- env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    WAYLAND_DISPLAY="$(basename "${sock:-wayland-0}")" \
    GDK_BACKEND=wayland \
    "$@"
}
ui_updating() {
  as_desktop_user zenity --info --no-wrap --timeout=20 \
    --title="KibaOS is updating" \
    --text=$'<b>KibaOS is installing a small update.</b>\n\nYou can keep working \xe2\x80\x94 this won\'t interrupt anything.\nWe\'ll only ask you to restart if it\'s really needed.' \
    >/dev/null 2>&1 &
  return 0
}
ui_notify() {
  as_desktop_user notify-send -a "KibaOS" -i software-update-available "$1" "$2" >/dev/null 2>&1 || true
}
ui_ask_restart() {
  as_desktop_user zenity --question --no-wrap --timeout=300 \
    --title="One quick restart needed" \
    --ok-label="Restart now" --cancel-label="Later" \
    --text=$'<b>This update needs the screen to restart to finish.</b>\n\nIt only takes a few seconds, but open apps will close,\nso please save your work first.\n\nChoose \xe2\x80\x9cLater\xe2\x80\x9d and nothing changes \xe2\x80\x94 the update will\nfinish by itself the next time you sign in.' \
    >/dev/null 2>&1
}
do_session_restart() {
  fb_freeze
  if ${NEEDS_COMPOSITOR_RESTART}; then
    restart_compositor
  fi
  if ${NEEDS_DISPLAY_RESTART}; then
    restart_display_manager
  fi
  fb_unfreeze
}

ui_updating || true

if ! apply_patch; then
  log "Patch application failed. Initiating rollback."
  rollback_patch
  fb_unfreeze
  ui_notify "KibaOS update couldn't be installed" "Nothing was changed — your system is exactly as it was. We'll try again later."
  exit 1
fi

if ! run_post_hooks; then
  log "Post-patch hooks failed. Initiating rollback."
  rollback_patch
  fb_unfreeze
  ui_notify "KibaOS update couldn't be installed" "Nothing was changed — your system is exactly as it was. We'll try again later."
  exit 1
fi

echo "${LATEST}" > "${PATCH_LEVEL_FILE}"

if ${NEEDS_DISPLAY_RESTART} || ${NEEDS_COMPOSITOR_RESTART}; then
  if [ -n "$(_active_user_info)" ]; then
    if ui_ask_restart; then
      log "User chose to restart now."
      do_session_restart
    else
      log "User chose Later (or didn't answer) -- deferring session restart."
      mkdir -p "${OTA_WORKDIR}"
      touch "${OTA_WORKDIR}/restart-deferred"
      ui_notify "KibaOS update installed" "It'll finish by itself the next time you sign in. Nothing else to do."
    fi
  else
    log "Nobody is signed in -- restarting the session now."
    do_session_restart
  fi
else
  ui_notify "KibaOS is up to date" "The update finished. Nothing else to do."
fi

log "Successfully updated to patch level ${LATEST}."

rm -rf "${EXTRACT_DIR}" "${PATCH_TAR}" "${PATCH_SIG}" "${MANIFEST}"
log "Done."
OTASCRIPT
chmod +x /usr/local/bin/kibaos-ota

cat > /etc/systemd/system/kibaos-ota.service << 'OTASVC'
[Unit]
Description=KibaOS OTA Live Patch Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-ota
StandardOutput=append:/var/log/kibaos/ota.log
StandardError=append:/var/log/kibaos/ota.log
OTASVC

cat > /etc/systemd/system/kibaos-ota.timer << 'OTATIMER'
[Unit]
Description=KibaOS OTA patch check every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
RandomizedDelaySec=3min
Persistent=true

[Install]
WantedBy=timers.target
OTATIMER

systemctl enable kibaos-ota.timer

cat > /usr/local/bin/kibaos-firstboot-groups << 'FIRSTBOOTGROUPS'
#!/usr/bin/env bash
set -euo pipefail
MARKER="/etc/kibaos/pending-user-groups"
[ -f "$MARKER" ] || exit 0

while IFS=: read -r username groups; do
    [ -n "$username" ] || continue
    IFS=',' read -ra group_arr <<< "$groups"
    add_groups=()
    for g in "${group_arr[@]}"; do
        if getent group "$g" > /dev/null 2>&1; then
            add_groups+=("$g")
        else
            echo "kibaos-firstboot-groups: '$g' still doesn't exist, leaving pending" >&2
        fi
    done
    if [ "${#add_groups[@]}" -gt 0 ]; then
        joined=$(IFS=,; echo "${add_groups[*]}")
        usermod -aG "$joined" "$username" \
            && echo "kibaos-firstboot-groups: added $username to $joined" \
            || echo "kibaos-firstboot-groups: usermod failed for $username" >&2
    fi
done < "$MARKER"

if ! grep -qE ':.*[a-zA-Z]' "$MARKER" 2>/dev/null || \
   ! awk -F: '{print $2}' "$MARKER" | tr ',' '\n' | while read -r g; do
       [ -n "$g" ] && ! getent group "$g" > /dev/null 2>&1 && exit 1
   done; then
    : # some group still missing -- keep retrying on future boots
else
    rm -f "$MARKER"
fi
FIRSTBOOTGROUPS
chmod +x /usr/local/bin/kibaos-firstboot-groups

cat > /etc/systemd/system/kibaos-firstboot-groups.service << 'FIRSTBOOTSVC'
[Unit]
Description=KibaOS first-boot group catch-up (docker, etc.)
After=systemd-sysusers.service
Wants=systemd-sysusers.service
ConditionPathExists=/etc/kibaos/pending-user-groups

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-firstboot-groups
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
FIRSTBOOTSVC

systemctl enable kibaos-firstboot-groups.service

SKEL="/etc/skel"
mkdir -p \
  "${SKEL}/.config/gtk-3.0" \
  "${SKEL}/.config/gtk-4.0" \
  "${SKEL}/.config/autostart" \
  "${SKEL}/.config/fastfetch"

# Desktop icons: pcmanfm-qt (layer-shell). It also paints the desktop
# background, so it sets the wallpaper itself via its CLI (valid modes:
# color|stretch|fit|center|tile) instead of relying on the old
# budgie-desktop-view path.
cat > /usr/local/bin/kibaos-desktop-icons << 'DESKTOPICONSWRAP'
#!/bin/sh
pcmanfm-qt --desktop &
PID=$!
sleep 2
pcmanfm-qt --wallpaper-mode=stretch -w /usr/share/kibaos/wallpaper.jpg
wait "$PID"
DESKTOPICONSWRAP
chmod +x /usr/local/bin/kibaos-desktop-icons

cat > "${SKEL}/.config/autostart/pcmanfm-qt-desktop.desktop" << 'DESKTOPVIEW'
[Desktop Entry]
Type=Application
Name=PCManFM-Qt Desktop
Exec=/usr/local/bin/kibaos-desktop-icons
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-AutoRestart=true
DESKTOPVIEW

cat > "${SKEL}/.config/gtk-3.0/settings.ini" << 'GTK3SKEL'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Numix-Circle
gtk-font-name=Nunito 11
gtk-cursor-theme-size=24
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=rgb
gtk-button-images=1
gtk-menu-images=1
gtk-enable-animations=1
GTK3SKEL

cp /etc/gtk-3.0/gtk.css "${SKEL}/.config/gtk-3.0/gtk.css"
cp /etc/gtk-4.0/gtk.css "${SKEL}/.config/gtk-4.0/gtk.css"

dbus-run-session -- dconf write /com/solus-project/budgie-panel/panels "@as []" || true
cat > /usr/share/glib-2.0/schemas/99-kibaos-budgie.gschema.override << 'EOF'
[com.solus-project.budgie-panel]
panels=@as []
EOF
glib-compile-schemas /usr/share/glib-2.0/schemas/

cat > /usr/local/bin/kibaos-first-login << 'FIRSTLOGIN'
#!/usr/bin/env bash
STAMP="${HOME}/.config/.kibaos-configured"
[ -f "${STAMP}" ] && exit 0

gsettings set org.gnome.desktop.interface gtk-theme               'Adwaita-dark'
gsettings set org.gnome.desktop.interface icon-theme              'Numix-Circle'
gsettings set org.gnome.desktop.interface cursor-theme            'Adwaita'
gsettings set org.gnome.desktop.interface cursor-size             24
gsettings set org.gnome.desktop.interface font-name               'Nunito 11'
gsettings set org.gnome.desktop.interface document-font-name      'Nunito 11'
gsettings set org.gnome.desktop.interface monospace-font-name     'Noto Sans Mono 11'
gsettings set org.gnome.desktop.interface color-scheme            'prefer-dark'
gsettings set org.gnome.desktop.interface enable-animations       true
gsettings set org.gnome.desktop.interface text-scaling-factor     1.0

gsettings set org.gnome.desktop.background picture-uri      'file:///usr/share/kibaos/wallpaper.jpg'
gsettings set org.gnome.desktop.background picture-uri-dark 'file:///usr/share/kibaos/wallpaper.jpg'
gsettings set org.gnome.desktop.background picture-options  'zoom'
gsettings set org.gnome.desktop.background primary-color    '#0d1b2a'

gsettings set org.gnome.desktop.wm.preferences button-layout               'close,minimize,maximize:'
gsettings set org.gnome.desktop.wm.preferences titlebar-font               'Nunito SemiBold 10'
gsettings set org.gnome.desktop.wm.preferences action-double-click-titlebar 'toggle-maximize'
gsettings set org.gnome.desktop.wm.preferences num-workspaces               4
gsettings set org.gnome.desktop.wm.preferences focus-mode                  'click'

gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click                true
gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll               true
gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
gsettings set org.gnome.desktop.peripherals.mouse    natural-scroll               false
gsettings set org.gnome.desktop.peripherals.mouse    accel-profile                'adaptive'

gsettings set org.nemo.preferences show-hidden-files           false
gsettings set org.nemo.preferences default-folder-viewer       'icon-view'
gsettings set org.nemo.icon-view default-zoom-level            'standard'
gsettings set org.nemo.preferences show-location-entry         false

touch "${STAMP}"

FIRSTLOGIN
chmod +x /usr/local/bin/kibaos-first-login

cat > /usr/local/bin/kibaos-panel-guard << 'PANELGUARD'
#!/usr/bin/env bash
PANEL_SCHEMA="com.solus-project.budgie-panel"
PANEL_INSTANCE_SCHEMA="com.solus-project.budgie-panel.panel"
PANEL_BASE="/com/solus-project/budgie-panel/panels/"

EXISTING_UUIDS=$(gsettings get "${PANEL_SCHEMA}" panels 2>/dev/null | tr -d "[]'" | tr ',' ' ')
for uuid in ${EXISTING_UUIDS}; do
  loc=$(gsettings get "${PANEL_INSTANCE_SCHEMA}:${PANEL_BASE}{${uuid}}/" location 2>/dev/null)
  [ "${loc}" = "'bottom'" ] && exit 0
done

PANEL_UUID=$(uuidgen)
gsettings set "${PANEL_SCHEMA}" panels "['${PANEL_UUID}']"
PANEL_PATH="${PANEL_BASE}{${PANEL_UUID}}/"

gsettings set "${PANEL_INSTANCE_SCHEMA}:${PANEL_PATH}" location bottom
gsettings set "${PANEL_INSTANCE_SCHEMA}:${PANEL_PATH}" size 42
gsettings set "${PANEL_INSTANCE_SCHEMA}:${PANEL_PATH}" transparency none
gsettings set "${PANEL_INSTANCE_SCHEMA}:${PANEL_PATH}" enable-shadow true

find_desktop_id() {
  for candidate in "$@"; do
    [ -f "/usr/share/applications/${candidate}" ] && {
      echo "${candidate}"
      return 0
    }
  done
  return 1
}

DOCK_LAUNCHERS=()
for ids in \
  "kibaos-files.desktop nemo.desktop" \
  "org.gnome.Calendar.desktop gnome-calendar.desktop" \
  "org.gnome.Notes.desktop bijiben.desktop gnome-notes.desktop" \
  "org.gnome.eog.desktop eog.desktop" \
  "org.gnome.Geary.desktop geary.desktop" \
  "org.gnome.Music.desktop gnome-music.desktop" \
  "org.gnome.Todo.desktop gnome-todo.desktop" \
  "gnome-control-center.desktop org.gnome.Settings.desktop"
do
  FOUND=$(find_desktop_id ${ids}) && DOCK_LAUNCHERS+=("${FOUND}")
done

add_applet() {
  local plugin_name="$1"
  local uuid
  uuid=$(uuidgen)
  gsettings set \
    "com.solus-project.budgie-panel.applet:/com/solus-project/budgie-panel/applets/{${uuid}}/" \
    name \
    "${plugin_name}"
  echo "${uuid}"
}

MENU_UUID=$(add_applet "budgie-menu")
TASKLIST_UUID=$(add_applet "icon-tasklist")
CLOCK_UUID=$(add_applet "clock")

RAVEN_UUID=$(add_applet "raventriggerapplet")
APPLET_LIST="'${MENU_UUID}', '${TASKLIST_UUID}'"
if ls /usr/lib/budgie-desktop/plugins/visualspace/visualspace.so \
      /usr/lib/budgie-desktop/plugins/visualspace.so >/dev/null 2>&1; then
  VSPACE_UUID=$(add_applet "visualspace")
  APPLET_LIST="${APPLET_LIST}, '${VSPACE_UUID}'"
fi
APPLET_LIST="${APPLET_LIST}, '${RAVEN_UUID}', '${CLOCK_UUID}'"

gsettings set \
  "${PANEL_INSTANCE_SCHEMA}:${PANEL_PATH}" \
  applets \
  "[${APPLET_LIST}]"

if [ "${#DOCK_LAUNCHERS[@]}" -gt 0 ]; then
  LAUNCHERS_GVARIANT=$(printf "'%s', " "${DOCK_LAUNCHERS[@]}")
  gsettings set \
    "com.solus-project.budgie-panel.icon-tasklist:/com/solus-project/budgie-panel/instance/icon-tasklist/{${TASKLIST_UUID}}/" \
    pinned-launchers \
    "[${LAUNCHERS_GVARIANT%, }]"
fi
PANELGUARD
chmod +x /usr/local/bin/kibaos-panel-guard

cat > "${SKEL}/.config/autostart/kibaos-configure.desktop" << 'AUTOCFG'
[Desktop Entry]
Type=Application
Name=KibaOS First Login Setup
Exec=/usr/local/bin/kibaos-first-login
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTOCFG

cat > "${SKEL}/.config/autostart/kibaos-panel-guard.desktop" << 'PANELGUARDDESK'
[Desktop Entry]
Type=Application
Name=KibaOS Panel Guard
Exec=/usr/local/bin/kibaos-panel-guard
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
PANELGUARDDESK

cat > "${SKEL}/.config/autostart/kibaos-oem-finish.desktop" << 'OEMAUTOCFG'
[Desktop Entry]
Type=Application
Name=Finish Setting Up KibaOS
Exec=sh -c 'test -f /etc/kibaos/oem-pending && exec /usr/bin/io.kibaos.oobe'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
OEMAUTOCFG

install -Dm644 "${WINAPPS_SRC}/install/windows.svg" \
  /usr/share/icons/hicolor/scalable/apps/kibaos-winapps.svg 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

cat > /usr/local/bin/kibaos-winapps-workspace << 'WORKSPACE'
#!/bin/bash
CONF_DIR="${HOME}/.config/winapps"
COMPOSE_FILE="${CONF_DIR}/compose.yaml"
KWIN_SCRIPT_NAME="kibaos-winapps-workspace-tempbind"
KWIN_SCRIPT_FILE="/tmp/${KWIN_SCRIPT_NAME}.js"
KWIN_SCRIPT_ID_FILE="/tmp/${KWIN_SCRIPT_NAME}.id"
HINT_MARKER="${HOME}/.config/kibaos/.winapps-workspace-hint-shown"
WIN_URL="http://localhost:8006"

if [ ! -f "${COMPOSE_FILE}" ]; then
  zenity --question --title="Set Up Windows Workspace?" \
    --text="Windows Workspace lets you run Windows programs -- like Word, Excel, or other apps that don't have a Linux version -- right alongside everything else in KibaOS.\n\nWant to set it up now? It takes about 15–20 minutes, and you won't need to do anything but wait." \
    --ok-label="Yes, Let's Do It" --cancel-label="Maybe Later" 2>/dev/null
  if [ "$?" -eq 0 ]; then
    exec /usr/bin/io.kibaos.winapps-setup --manual-launch
  fi
  exit 1
fi

EXISTING_WIN="$(xdotool search --class "^chromium.*8006$|^Chromium.*8006$" 2>/dev/null | head -n1)"
if [ -z "${EXISTING_WIN}" ]; then
  EXISTING_WIN="$(xdotool search --name "localhost:8006" 2>/dev/null | head -n1)"
fi
if [ -n "${EXISTING_WIN}" ]; then
  xdotool windowactivate "${EXISTING_WIN}" 2>/dev/null
  exit 0
fi

KEYBIND_ADDED=0
add_keybind() {
  if [ ! -f "${KWIN_SCRIPT_ID_FILE}" ]; then
    cat > "${KWIN_SCRIPT_FILE}" << 'KWINTEMPBIND'
registerShortcut("KibaWinAppsWorkspaceMinimize", "Minimize Windows Workspace", "Meta+K", function() {
  if (workspace.activeWindow) {
    workspace.activeWindow.minimized = true;
  }
});
KWINTEMPBIND
    SCRIPT_ID="$(qdbus org.kde.KWin /Scripting loadScript "${KWIN_SCRIPT_FILE}" "${KWIN_SCRIPT_NAME}" 2>/dev/null)"
    if [ -n "${SCRIPT_ID}" ]; then
      qdbus "org.kde.KWin" "/Scripting/Script${SCRIPT_ID}" run 2>/dev/null || \
        qdbus "org.kde.KWin" "/${SCRIPT_ID}" run 2>/dev/null || true
      echo "${SCRIPT_ID}" > "${KWIN_SCRIPT_ID_FILE}"
      KEYBIND_ADDED=1
    fi
  fi
}

cleanup() {
  if [ "${KEYBIND_ADDED}" -eq 1 ] && [ -f "${KWIN_SCRIPT_ID_FILE}" ]; then
    SCRIPT_ID="$(cat "${KWIN_SCRIPT_ID_FILE}" 2>/dev/null)"
    if [ -n "${SCRIPT_ID}" ]; then
      qdbus "org.kde.KWin" /Scripting unloadScript "${KWIN_SCRIPT_NAME}" 2>/dev/null || true
    fi
    rm -f "${KWIN_SCRIPT_ID_FILE}" "${KWIN_SCRIPT_FILE}"
  fi
}
trap cleanup EXIT

ALREADY_UP=0
if curl -fsS -o /dev/null --max-time 2 "${WIN_URL}" 2>/dev/null; then
  ALREADY_UP=1
fi

if [ "${ALREADY_UP}" -eq 0 ]; then
  ( cd "${CONF_DIR}" && pkexec docker compose up -d ) >/dev/null 2>&1 &
  COMPOSE_PID=$!

  (
    for i in $(seq 1 60); do
      curl -fsS -o /dev/null --max-time 1 "${WIN_URL}" 2>/dev/null && break
      sleep 1
      echo "$((i * 100 / 60))"
    done
    echo "100"
  ) | zenity --progress --title="Windows Workspace" --text="Just a moment, opening your Windows Workspace…" \
      --pulsate --auto-close --no-cancel --width=360 2>/dev/null

  wait "${COMPOSE_PID}"
  COMPOSE_STATUS=$?

  if ! curl -fsS -o /dev/null --max-time 2 "${WIN_URL}" 2>/dev/null; then
    if [ "${COMPOSE_STATUS}" -ne 0 ]; then
      zenity --error --title="Windows Workspace" --width=420 \
        --text="Hmm, your Windows Workspace didn't start. Give it another try -- if it keeps happening, open 'Set Up Windows Workspace' from the app menu and we'll get it sorted." 2>/dev/null
    else
      zenity --error --title="Windows Workspace" --width=420 \
        --text="Your Windows Workspace is taking a little longer than usual to wake up. Nothing's broken -- just give it another moment, then try 'Open Windows Workspace' again." 2>/dev/null
    fi
    exit 1
  fi
fi

add_keybind

if [ "${KEYBIND_ADDED}" -eq 1 ] && [ ! -f "${HINT_MARKER}" ]; then
  mkdir -p "$(dirname "${HINT_MARKER}")"
  touch "${HINT_MARKER}"
  notify-send -i kibaos-winapps "Windows Workspace" \
    "Tip: press Super+K any time to duck back to your KibaOS desktop. Windows Workspace stays right where you left it." 2>/dev/null || \
    zenity --info --title="Windows Workspace" --width=380 \
      --text="Tip: press Super+K any time to duck back to your KibaOS desktop. Windows Workspace stays right where you left it." 2>/dev/null
fi

chromium --kiosk --app="${WIN_URL}" 2>/dev/null
WORKSPACE
chmod +x /usr/local/bin/kibaos-winapps-workspace

cat > /usr/share/applications/kibaos-winapps-workspace.desktop << 'WORKSPACEDESKTOP'
[Desktop Entry]
Type=Application
Name=Open Windows Workspace
Comment=Run Windows programs like Word and Excel, right alongside KibaOS
Icon=kibaos-winapps
Exec=/usr/local/bin/kibaos-winapps-workspace
Terminal=false
NoDisplay=false
Categories=System;
WORKSPACEDESKTOP

mkdir -p "${SKEL}/Desktop"
cp /usr/share/applications/kibaos-winapps-workspace.desktop \
  "${SKEL}/Desktop/kibaos-winapps-workspace.desktop"
chmod +x "${SKEL}/Desktop/kibaos-winapps-workspace.desktop"

cat > /usr/local/bin/kibaos-winapps-setup << 'WINAPPSSETUP'
WINAPPS_SRC="/opt/kibaos/winapps-src"
CONF_DIR="${HOME}/.config/winapps"
COMPOSE_FILE="${CONF_DIR}/compose.yaml"
MARKER="/etc/kibaos/winapps-pending"
MANUAL_LAUNCH="${1:-}"

progress() { echo "PROGRESS $1 $2"; }
fail()     { progress 100 "Setup failed: $1"; echo "FATAL: $1" >&2; exit 1; }

if [ -z "${WINAPPS_REGROUPED:-}" ] \
   && id -nG "${USER:-$(id -un)}" 2>/dev/null | tr ' ' '\n' | grep -qx docker \
   && ! groups 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  export WINAPPS_REGROUPED=1
  exec newgrp docker <<NEWGRPCMD
"$0" ${MANUAL_LAUNCH}
NEWGRPCMD
fi

progress 1 "Checking Windows Workspace status..."

if command -v winapps >/dev/null 2>&1 && [ -f "${CONF_DIR}/winapps.conf" ]; then
  rm -f "${MARKER}"
  progress 100 "Windows Workspace is already set up and running."
  exit 0
fi

RESUMING=0
if command -v docker >/dev/null 2>&1 && [ -f "${COMPOSE_FILE}" ]; then
  RESUMING=1
fi

if [ "${RESUMING}" -eq 1 ]; then
  progress 5 "Resuming Windows Workspace setup..."
else
  progress 5 "Setting up Windows Workspace..."
fi

progress 10 "Starting Docker..."
mkdir -p "${CONF_DIR}"

NVIDIA_HW=0
lspci -nnk 2>/dev/null | grep -qi 'nvidia' && NVIDIA_HW=1
ORIG_USER="$(id -un)"
GPU_FLAG_FILE="$(mktemp)"
PRIV_SCRIPT="$(mktemp)"

cat > "${PRIV_SCRIPT}" << 'PRIVILEGED'
#!/usr/bin/env bash
set -u
CONF_DIR="$1"; COMPOSE_FILE="$2"; NVIDIA_HW="$3"; ORIG_USER="$4"; GPU_FLAG_FILE="$5"
WINAPPS_SRC="/opt/kibaos/winapps-src"

echo "PROGRESS 10 Starting Docker..."
systemctl enable --now docker >/dev/null 2>&1
if ! systemctl is-active --quiet docker; then
  logger -t kibaos-winapps-setup "docker failed to start; see systemctl status docker"
  echo "PROGRESS 100 Setup failed: Docker couldn't be started -- check 'systemctl status docker'."
  echo "FATAL: Docker couldn't be started -- check 'systemctl status docker'." >&2
  exit 1
fi

if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "PROGRESS 15 Preparing Windows Workspace configuration..."
  cp "${WINAPPS_SRC}/compose.yaml" "${COMPOSE_FILE}"
  cp -r "${WINAPPS_SRC}/oem" "${CONF_DIR}/oem"
  if [ "$(uname -m)" = "aarch64" ]; then
    sed -i -E 's#image: dockurr/windows(:[^[:space:]]*)?$#image: dockurr/windows-arm\1#' "${COMPOSE_FILE}"
  fi

  echo "PROGRESS 20 Setting your Windows account password..."
  WIN_USER="KibaUser"
  WIN_PASS=""
  STASH="/etc/kibaos/winapps-userpass"
  if [ -f "${STASH}" ]; then
    WIN_PASS="$(cat "${STASH}" 2>/dev/null)"
    rm -f "${STASH}" 2>/dev/null || true
  fi
  if [ -z "${WIN_PASS}" ] || [ "${#WIN_PASS}" -lt 8 ]; then
    WIN_PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
    NOTE="/etc/kibaos/winapps-password-note"
    ( umask 077; printf '%s\n' "${WIN_PASS}" > "${NOTE}" ) 2>/dev/null || true
    logger -t kibaos-winapps-setup "no reusable KibaOS password found -- generated a new Windows password, stashed root-only at ${NOTE}"
  fi
  COMPOSE_TMP="$(mktemp)"
  while IFS= read -r line; do
    if [[ "${line}" =~ ^([[:space:]]*)USERNAME:[[:space:]]* ]]; then
      printf '%sUSERNAME: "%s"\n' "${BASH_REMATCH[1]}" "${WIN_USER}"
    elif [[ "${line}" =~ ^([[:space:]]*)PASSWORD:[[:space:]]* ]]; then
      printf '%sPASSWORD: "%s"\n' "${BASH_REMATCH[1]}" "${WIN_PASS}"
    else
      printf '%s\n' "${line}"
    fi
  done < "${COMPOSE_FILE}" > "${COMPOSE_TMP}"
  mv "${COMPOSE_TMP}" "${COMPOSE_FILE}"
  sed -i "s/^\([[:space:]]*VERSION:[[:space:]]*\).*/\1\"tiny11\"/" "${COMPOSE_FILE}"
  chmod 600 "${COMPOSE_FILE}"
fi

echo "PROGRESS 30 Checking for GPU passthrough..."
COMPOSE_ARGS=(--file "${COMPOSE_FILE}")
GPU_DETECTED=0
if [ "${NVIDIA_HW}" -eq 1 ] && docker info 2>/dev/null | grep -qi 'nvidia'; then
  OVERRIDE_FILE="${CONF_DIR}/compose.override.yaml"
  cat > "${OVERRIDE_FILE}" << 'GPUOVERRIDE'
services:
  windows:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: ["gpu"]
GPUOVERRIDE
  COMPOSE_ARGS+=(--file "${OVERRIDE_FILE}")
  GPU_DETECTED=1
fi
echo "${GPU_DETECTED}" > "${GPU_FLAG_FILE}"

echo "PROGRESS 35 Starting the Windows virtual machine..."
COMPOSE_LOG="$(mktemp)"
if ! ( cd "${CONF_DIR}" && docker compose "${COMPOSE_ARGS[@]}" up -d ) > "${COMPOSE_LOG}" 2>&1; then
  logger -t kibaos-winapps-setup "docker compose up -d failed: $(cat "${COMPOSE_LOG}")"
  rm -f "${COMPOSE_LOG}"
  echo "PROGRESS 100 Setup failed: Windows Workspace couldn't start -- nothing was changed permanently, retry from the app menu."
  echo "FATAL: Windows Workspace couldn't start -- nothing was changed permanently, retry from the app menu." >&2
  chown -R "${ORIG_USER}:${ORIG_USER}" "${CONF_DIR}" 2>/dev/null || true
  exit 1
fi
rm -f "${COMPOSE_LOG}"

chown -R "${ORIG_USER}:${ORIG_USER}" "${CONF_DIR}" 2>/dev/null || true
PRIVILEGED
chmod +x "${PRIV_SCRIPT}"

pkexec bash "${PRIV_SCRIPT}" "${CONF_DIR}" "${COMPOSE_FILE}" "${NVIDIA_HW}" "${ORIG_USER}" "${GPU_FLAG_FILE}"
PRIV_STATUS=$?
rm -f "${PRIV_SCRIPT}"
if [ "${PRIV_STATUS}" -eq 126 ] || [ "${PRIV_STATUS}" -eq 127 ]; then
  rm -f "${GPU_FLAG_FILE}"
  fail "Windows Workspace setup needs administrator access to continue -- retry from the app menu when you're ready to authenticate."
elif [ "${PRIV_STATUS}" -ne 0 ]; then
  rm -f "${GPU_FLAG_FILE}"
  exit "${PRIV_STATUS}"
fi
GPU_DETECTED="$(cat "${GPU_FLAG_FILE}" 2>/dev/null || echo 0)"
rm -f "${GPU_FLAG_FILE}"


progress 40 "Reading Windows account details..."
WIN_USER=$(grep -oP '^\s*USERNAME:\s*"\K[^"]+' "${COMPOSE_FILE}")
WIN_PASS=$(grep -oP '^\s*PASSWORD:\s*"\K[^"]+' "${COMPOSE_FILE}")

if [ -z "${WIN_USER}" ] || [ -z "${WIN_PASS}" ]; then
  fail "Couldn't read the Windows account details back out of compose.yaml."
fi

progress 45 "Writing Windows Workspace configuration..."
cat > "${CONF_DIR}/winapps.conf" << CONF
RDP_USER="${WIN_USER}"
RDP_PASS="${WIN_PASS}"
RDP_IP="127.0.0.1"
RDP_PORT="3389"
WAFLAVOR="docker"
DEBUG="true"
RDP_FLAGS="/gfx:AVC444 /network:lan"
CONF
chmod 600 "${CONF_DIR}/winapps.conf"

progress 50 "Waiting for Windows to finish installing (this can take up to 35 minutes)..."
RDP_UP=0
for i in $(seq 1 420); do
  nc -z 127.0.0.1 3389 >/dev/null 2>&1 && { RDP_UP=1; break; }
  sleep 5
  if [ $((i % 6)) -eq 0 ]; then
    progress "$((50 + i * 35 / 420))" "Still waiting for Windows to finish installing..."
  fi
done

if [ "${RDP_UP}" -ne 1 ]; then
  fail "Windows is taking longer than expected to finish installing -- nothing's broken, just re-run this to pick up where it left off."
fi

progress 85 "Setting up your Windows app shortcuts..."
SETUP_LOG="$(mktemp)"
if ! "${WINAPPS_SRC}/setup.sh" --user --setupAllOfficiallySupportedApps > "${SETUP_LOG}" 2>&1; then
  logger -t kibaos-winapps-setup "app shortcut setup failed: $(cat "${SETUP_LOG}")"
  rm -f "${SETUP_LOG}"
  fail "Windows itself is all set up and ready to go, but hooking up the individual app shortcuts hit a snag -- re-run this to retry just that step."
fi
rm -f "${SETUP_LOG}"

rm -f "${MARKER}"
if [ "${GPU_DETECTED}" -eq 1 ]; then
  progress 100 "All set! An NVIDIA GPU was detected and passed through to Windows for faster, hardware-accelerated apps."
else
  progress 100 "All set!"
fi
exit 0
WINAPPSSETUP
chmod +x /usr/local/bin/kibaos-winapps-setup

cat > /usr/share/applications/kibaos-winapps-setup.desktop << 'SETUPDESKTOP'
[Desktop Entry]
Type=Application
Name=Set Up Windows Workspace
Comment=Set up Windows so you can run Windows programs, like Office, right from KibaOS
Icon=kibaos-winapps
Exec=/usr/bin/io.kibaos.winapps-setup
Terminal=false
Categories=System;Settings;
SETUPDESKTOP

cat > "${SKEL}/.config/autostart/kibaos-winapps-firstrun.desktop" << 'WINAPPSAUTOCFG'
[Desktop Entry]
Type=Application
Name=Windows Workspace Setup
Exec=sh -c 'test -f /etc/kibaos/winapps-pending && exec /usr/bin/io.kibaos.winapps-setup'
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
WINAPPSAUTOCFG

cat > "${SKEL}/.config/autostart/kibaos-install-launch.desktop" << 'LIVELAUNCH'
[Desktop Entry]
Type=Application
Name=KibaOS Installer
Exec=sh -c '[ "$(whoami)" = "liveuser" ] && exec /usr/bin/io.kibaos.oobe'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
LIVELAUNCH

mkdir -p /etc/systemd/zram-generator.conf.d
cat > /etc/systemd/zram-generator.conf << 'ZRAM'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM

mkdir -p "${SKEL}/.config"

mkdir -p "${SKEL}/.config/fontconfig"
cat > "${SKEL}/.config/fontconfig/fonts.conf" << 'FONTCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
    <edit name="embeddedbitmap" mode="assign"><bool>false</bool></edit>
  </match>
  <alias>
    <family>sans-serif</family>
    <prefer><family>Nunito</family></prefer>
  </alias>
  <alias>
    <family>system-ui</family>
    <prefer><family>Nunito</family></prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer><family>Noto Sans Mono</family></prefer>
  </alias>
</fontconfig>
FONTCONF

cat > "${SKEL}/.config/electron-flags.conf" << 'ELECTRONFLAGS'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
--enable-wayland-ime
ELECTRONFLAGS

cat > "${SKEL}/.config/chrome-flags.conf" << 'CHROMEFLAGS'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
CHROMEFLAGS

cat > "${SKEL}/.config/autostart/polkit-agent.desktop" << 'POLKIT'
[Desktop Entry]
Type=Application
Name=Polkit Authentication Agent
Exec=/usr/lib/polkit-kde-authentication-agent-1
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
POLKIT

cat > "${SKEL}/.bashrc" << 'BASHRC'
[[ $- != *i* ]] && return
PS1='\[\e[1;36m\][KibaOS]\[\e[0m\] \[\e[32m\]\u@\h\[\e[0m\]:\[\e[34m\]\w\[\e[0m\]\$ '
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias grep='grep --color=auto'
alias install='io.kibaos.oobe'
alias update='sudo kiba update'
fastfetch 2>/dev/null || true
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
export HISTFILE="$XDG_STATE_HOME/bash/history"
BASHRC

mkdir -p "${SKEL}/.config/fastfetch"
cat > "${SKEL}/.config/fastfetch/config.jsonc" << 'FFCONF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "source": "kibaos",
    "color": { "1": "cyan", "2": "white" },
    "padding": { "top": 1 }
  },
  "display": { "separator": "  ", "color": { "keys": "cyan" } },
  "modules": [
    { "type": "title",  "format": "{user-name-colored}@{host-name-colored}" },
    "separator",
    { "type": "os",     "key": "OS" },
    { "type": "kernel", "key": "Kernel" },
    { "type": "de",     "key": "Desktop" },
    { "type": "wm",     "key": "WM" },
    { "type": "shell",  "key": "Shell" },
    { "type": "cpu",    "key": "CPU" },
    { "type": "gpu",    "key": "GPU" },
    { "type": "memory", "key": "Memory" },
    { "type": "disk",   "key": "Disk" },
    "break",
    { "type": "colors", "paddingLeft": 0 }
  ]
}
FFCONF

cp -aT "${SKEL}/" /home/liveuser/
chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser

mkdir -p /usr/local/bin
mkdir -p /usr/share/kibaos-welcome

(
  set -e
  JOPLIN_TAG=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/laurent22/joplin/releases/latest)
  JOPLIN_TAG="${JOPLIN_TAG##*/}"
  JOPLIN_URL="https://github.com/laurent22/joplin/releases/download/${JOPLIN_TAG}/Joplin-${JOPLIN_TAG#v}.AppImage"
  [ -n "${JOPLIN_URL}" ]
  JOPLIN_TMP="/tmp/joplin-appimage"
  rm -rf "${JOPLIN_TMP}" && mkdir -p "${JOPLIN_TMP}" && cd "${JOPLIN_TMP}"
  curl -fL --retry 3 -o Joplin.AppImage "${JOPLIN_URL}"
  chmod +x Joplin.AppImage
  ./Joplin.AppImage --appimage-extract >/dev/null
  rm -rf /opt/joplin && mv squashfs-root /opt/joplin
  chmod -R a+rX /opt/joplin
  for _sz in 512 256 128 64 48; do
    _ic="/opt/joplin/usr/share/icons/hicolor/${_sz}x${_sz}/apps/joplin.png"
    [ -f "${_ic}" ] && install -Dm644 "${_ic}" "/usr/share/icons/hicolor/${_sz}x${_sz}/apps/joplin.png"
  done
  cat > /usr/bin/joplin-desktop << 'JOPLINLAUNCH'
#!/bin/sh
exec /opt/joplin/AppRun --no-sandbox "$@"
JOPLINLAUNCH
  chmod 755 /usr/bin/joplin-desktop
  cat > /usr/share/applications/joplin.desktop << 'JOPLINDESKTOP'
[Desktop Entry]
Type=Application
Name=Joplin
Comment=Note-taking and to-do application with synchronisation
Exec=joplin-desktop %U
Icon=joplin
Terminal=false
Categories=Office;Utility;
StartupWMClass=Joplin
JOPLINDESKTOP
  rm -rf "${JOPLIN_TMP}"
) && echo "=== Joplin installed ===" \
  || echo "!! Joplin install failed -- continuing without it" >&2

(
  set -e
  KANDO_TAG=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/kando-menu/kando/releases/latest)
  KANDO_TAG="${KANDO_TAG##*/}"
  KANDO_URL="https://github.com/kando-menu/kando/releases/download/${KANDO_TAG}/Kando-${KANDO_TAG#v}-x86_64.AppImage"
  KANDO_TMP="/tmp/kando-appimage"
  rm -rf "${KANDO_TMP}" && mkdir -p "${KANDO_TMP}" && cd "${KANDO_TMP}"
  curl -fL --retry 3 -o Kando.AppImage "${KANDO_URL}"
  chmod +x Kando.AppImage
  ./Kando.AppImage --appimage-extract >/dev/null
  rm -rf /opt/kando && mv squashfs-root /opt/kando
  chmod -R a+rX /opt/kando
  for _sz in 512 256 128 64 48; do
    _ic="/opt/kando/usr/share/icons/hicolor/${_sz}x${_sz}/apps/kando.png"
    [ -f "${_ic}" ] && install -Dm644 "${_ic}" "/usr/share/icons/hicolor/${_sz}x${_sz}/apps/kando.png"
  done
  cat > /usr/bin/kando << 'KANDOLAUNCH'
#!/bin/sh
exec /opt/kando/AppRun --no-sandbox "$@"
KANDOLAUNCH
  chmod 755 /usr/bin/kando
  cat > /usr/share/applications/kando.desktop << 'KANDODESKTOP'
[Desktop Entry]
Type=Application
Name=Kando
Comment=The Cross-Platform Pie Menu
Exec=kando %U
Icon=kando
Terminal=false
Categories=Utility;
StartupWMClass=Kando
KANDODESKTOP
  mkdir -p /etc/xdg/autostart
  cp /usr/share/applications/kando.desktop /etc/xdg/autostart/kando.desktop
  rm -rf "${KANDO_TMP}"
) && echo "=== Kando installed ===" \
  || echo "!! Kando install failed -- continuing without it" >&2

(
  set -e
  VP_TAG=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/prankstr/vibepanel/releases/latest)
  VP_TAG="${VP_TAG##*/}"
  VP_BASE="https://github.com/prankstr/vibepanel/releases/download/${VP_TAG}"
  VP_TMP="/tmp/vibepanel-dl"
  rm -rf "${VP_TMP}" && mkdir -p "${VP_TMP}" && cd "${VP_TMP}"
  curl -fL --retry 3 -o vibepanel "${VP_BASE}/vibepanel-x86_64-unknown-linux-gnu"
  curl -fL --retry 3 -o vibepanel.sha256 "${VP_BASE}/vibepanel-x86_64-unknown-linux-gnu.sha256"
  [ "$(awk '{print $1}' vibepanel.sha256)" = "$(sha256sum vibepanel | awk '{print $1}')" ]
  install -Dm755 vibepanel /usr/bin/vibepanel
  mkdir -p /usr/share/kibaos
  cat > /usr/share/kibaos/vibepanel-config.toml << 'VPCONFIG'
[bar]
position = "top"
size = 32
border_radius = 0
background_opacity = 0.55

[widgets]
left = ["cpu"]
right = ["tray", "quick_settings", "battery"]
border_radius = 0
background_opacity = 0.0

[osd]
enabled = false
VPCONFIG
  cat > /usr/bin/vibepanel-session << 'VPWRAP'
#!/bin/sh
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/vibepanel/config.toml"
if [ ! -f "$CFG" ]; then
  mkdir -p "$(dirname "$CFG")"
  cp /usr/share/kibaos/vibepanel-config.toml "$CFG"
fi
exec /usr/bin/vibepanel "$@"
VPWRAP
  chmod 755 /usr/bin/vibepanel-session
  cat > /usr/share/applications/vibepanel.desktop << 'VPDESKTOP'
[Desktop Entry]
Type=Application
Name=VibePanel
Comment=Top panel with quick settings
Exec=vibepanel-session
Icon=preferences-system
Terminal=false
Categories=Utility;Settings;
NoDisplay=true
VPDESKTOP
  mkdir -p /etc/xdg/autostart
  cat > /etc/xdg/autostart/vibepanel.desktop << 'VPAUTO'
[Desktop Entry]
Type=Application
Name=VibePanel
Exec=vibepanel-session
OnlyShowIn=Budgie;GNOME;
X-GNOME-Autostart-Delay=2
VPAUTO
  rm -rf "${VP_TMP}"
) && echo "=== VibePanel installed ===" \
  || echo "!! VibePanel install failed -- continuing without it" >&2

sed -i 's/GTK_THEME=Adwaita-dark/GTK_THEME=KibaOS/' /etc/environment

(
  set -e
  BW_SRC="/tmp/budgie-welcome"
  rm -rf "${BW_SRC}"
  git clone --depth 1 https://github.com/UbuntuBudgie/budgie-welcome.git "${BW_SRC}"
  cd "${BW_SRC}"
  for _js in bootstrap baguetteBox popper; do
    cp "data/js/${_js}.js" "data/js/${_js}.min.js"
  done
  bash sassc-compile.sh
  mkdir -p /usr/share/budgie-welcome /usr/lib/budgie-welcome /usr/share/budgie-welcome-shims
  cp -r data/. /usr/share/budgie-welcome/
  install -Dm755 budgie-welcome /usr/lib/budgie-welcome/budgie-welcome.py
  install -Dm755 budgie-welcome-privileged-actions /usr/lib/budgie-welcome/budgie-welcome-privileged-actions
  install -Dm644 org.budgie.welcome.policy /usr/share/polkit-1/actions/org.budgie.welcome.policy
  install -Dm644 budgie-welcome.1 /usr/share/man/man1/budgie-welcome.1

  cat > /usr/share/budgie-welcome-shims/apt.py << 'APTSHIM'
class Cache(dict):
    def __getitem__(self, k): raise KeyError(k)
    def __contains__(self, k): return False
    def has_key(self, k): return False
    def open(self, *a, **k): pass
    def close(self, *a, **k): pass
APTSHIM
  cat > /usr/share/budgie-welcome-shims/notify2.py << 'NOTIFYSHIM'
def init(*a, **k): return True
class Notification:
    def __init__(self, *a, **k): pass
    def show(self): return True
    def set_timeout(self, *a): pass
    def add_action(self, *a, **k): pass
NOTIFYSHIM

  cat > /usr/bin/budgie-welcome << 'BWLAUNCH'
#!/bin/sh
export PYTHONPATH="/usr/share/budgie-welcome-shims${PYTHONPATH:+:${PYTHONPATH}}"
exec python3 /usr/lib/budgie-welcome/budgie-welcome.py "$@"
BWLAUNCH
  chmod 755 /usr/bin/budgie-welcome

  cat > /usr/share/applications/budgie-welcome.desktop << 'BWDESKTOP'
[Desktop Entry]
Type=Application
Name=Budgie Welcome
Comment=Find out about your desktop and Budgie applets
Exec=budgie-welcome
Icon=help-about
Terminal=false
Categories=Utility;GTK;
Keywords=welcome;budgie;tour;applets;
BWDESKTOP
  rm -rf "${BW_SRC}"
) && echo "=== Budgie Welcome installed ===" \
  || echo "!! Budgie Welcome install failed -- continuing without it" >&2

mkdir -p /usr/share/applications /etc/skel/Desktop /etc/skel/Documents \
         /etc/skel/Downloads /etc/skel/Pictures /etc/skel/Music /etc/skel/Videos
cat > /etc/skel/.config/user-dirs.dirs << 'USERDIRS'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_MUSIC_DIR="$HOME/Music"
XDG_VIDEOS_DIR="$HOME/Videos"
USERDIRS

cat > /usr/local/bin/kibaos-files << 'FILESWRAP'
#!/bin/bash
exec nemo "$HOME"
FILESWRAP
chmod +x /usr/local/bin/kibaos-files

cat > /usr/share/applications/kibaos-files.desktop << 'FILESDESK'
[Desktop Entry]
Type=Application
Name=Files
Comment=Browse your documents, downloads, and other files
Icon=nemo
Exec=/usr/local/bin/kibaos-files
Terminal=false
NoDisplay=false
Categories=System;FileTools;FileManager;
FILESDESK

mkdir -p /etc/skel/.config/autostart
cat > /usr/local/bin/kibaos-first-login-setup << 'FIRSTLOGIN'
#!/bin/bash
MARKER="$HOME/.config/.kibaos-first-login-done"
[ -f "$MARKER" ] && exit 0
mkdir -p "$HOME/.config/gtk-3.0"
cat > "$HOME/.config/gtk-3.0/bookmarks" << BOOKMARKS
file://$HOME/Desktop Desktop
file://$HOME/Documents Documents
file://$HOME/Downloads Downloads
file://$HOME/Pictures Pictures
file://$HOME/Music Music
file://$HOME/Videos Videos
BOOKMARKS
mkdir -p "$HOME/.config"
touch "$MARKER"
FIRSTLOGIN
chmod +x /usr/local/bin/kibaos-first-login-setup

cat > /etc/skel/.config/autostart/kibaos-first-login-setup.desktop << 'FIRSTLOGINDESK'
[Desktop Entry]
Type=Application
Name=KibaOS First Login Setup
Exec=/usr/local/bin/kibaos-first-login-setup
NoDisplay=true
X-GNOME-Autostart-Phase=Initialization
FIRSTLOGINDESK

mkdir -p /usr/share/kibapkg
cat > /usr/share/kibapkg/kibapkg.py << 'KIBAPKG'
#!/usr/bin/env python3
"""kibapkg — a friendly front-end to libalpm (via pyalpm) for KibaOS.
Invoked as `kiba`. Talks to libalpm directly; never shells out to pacman."""
import os
import re
import sys
import pyalpm

ROOT = "/"
DBPATH = "/var/lib/pacman"
PACMAN_CONF = "/etc/pacman.conf"
MIRRORLIST = "/etc/pacman.d/mirrorlist"


def die(msg):
    print(f"kiba: {msg}")
    sys.exit(1)


def need_root():
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", sys.executable, __file__] + sys.argv[1:])


def active_mirrors(limit=5):
    mirrors = []
    if os.path.exists(MIRRORLIST):
        with open(MIRRORLIST) as f:
            for line in f:
                line = line.strip()
                if line.startswith("Server"):
                    url = line.split("=", 1)[1].strip()
                    mirrors.append(url)
                    if len(mirrors) >= limit:
                        break
    return mirrors


def repo_names():
    repos = []
    if os.path.exists(PACMAN_CONF):
        with open(PACMAN_CONF) as f:
            for line in f:
                m = re.match(r"^\[(\w+)\]$", line.strip())
                if m and m.group(1) != "options":
                    repos.append(m.group(1))
    return repos or ["core", "extra", "multilib"]


def make_handle():
    h = pyalpm.Handle(ROOT, DBPATH)
    mirrors = active_mirrors()
    for repo in repo_names():
        db = h.register_syncdb(repo, pyalpm.SIG_DATABASE_OPTIONAL)
        db.servers = [m.replace("$repo", repo).replace("$arch", os.uname().machine) for m in mirrors]
    return h


def cb_event(*_):
    pass  # kept silent on purpose — kiba prints its own plain-language status


def run_transaction(h, build_trans, verb):
    h.dlcb = lambda name, xfered, total: None
    h.eventcb = cb_event
    t = h.init_transaction()
    try:
        build_trans(h, t)
        t.prepare()
        if not t.to_add and not t.to_remove:
            print(f"kiba: nothing to {verb}.")
            t.release()
            return
        for pkg in t.to_add:
            print(f"  + {pkg.name} {pkg.version}")
        for pkg in t.to_remove:
            print(f"  - {pkg.name} {pkg.version}")
        t.commit()
        print(f"kiba: {verb} complete.")
    except pyalpm.error as e:
        print(f"kiba: couldn't {verb} that — {e}")
        sys.exit(1)
    finally:
        try:
            t.release()
        except Exception:
            pass


def cmd_search(h, terms):
    seen = set()
    for db in h.get_syncdbs():
        for pkg in db.search(terms):
            if pkg.name not in seen:
                seen.add(pkg.name)
                print(f"{pkg.name:<28} {pkg.version:<16} {pkg.desc}")


def cmd_list(h):
    for pkg in h.get_localdb().pkgcache:
        print(f"{pkg.name:<28} {pkg.version}")


def cmd_info(h, name):
    pkg = h.get_localdb().get_pkg(name)
    source = "installed"
    if pkg is None:
        for db in h.get_syncdbs():
            pkg = db.get_pkg(name)
            if pkg:
                source = f"available in {db.name}"
                break
    if pkg is None:
        die(f"no package named '{name}'")
    print(f"{pkg.name}  {pkg.version}  ({source})")
    print(pkg.desc)


def cmd_install(h, names):
    def build(h, t):
        for name in names:
            pkg = None
            for db in h.get_syncdbs():
                pkg = db.get_pkg(name)
                if pkg:
                    break
            if pkg is None:
                die(f"no package named '{name}'")
            t.add_pkg(pkg)
    run_transaction(h, build, "install")


def cmd_remove(h, names):
    def build(h, t):
        for name in names:
            pkg = h.get_localdb().get_pkg(name)
            if pkg is None:
                die(f"'{name}' isn't installed")
            t.remove_pkg(pkg)
    run_transaction(h, build, "remove")


def cmd_update(h):
    def build(h, t):
        for db in h.get_syncdbs():
            db.update(force=False)
        h.sysupgrade(downgrade=False)
    run_transaction(h, build, "update")


HELP = """kiba — the KibaOS package manager

  kiba install <name...>   install one or more apps
  kiba remove  <name...>   remove one or more apps
  kiba update              update everything
  kiba search  <term>      search for an app
  kiba list                list installed apps
  kiba info    <name>      show details about an app
"""


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help", "help"):
        print(HELP)
        return
    cmd, rest = args[0], args[1:]
    if cmd in ("install", "remove", "update"):
        need_root()
    h = make_handle()
    if cmd == "install" and rest:
        cmd_install(h, rest)
    elif cmd == "remove" and rest:
        cmd_remove(h, rest)
    elif cmd == "update":
        cmd_update(h)
    elif cmd == "search" and rest:
        cmd_search(h, rest)
    elif cmd == "list":
        cmd_list(h)
    elif cmd == "info" and rest:
        cmd_info(h, rest[0])
    else:
        print(HELP)


if __name__ == "__main__":
    main()
KIBAPKG
chmod +x /usr/share/kibapkg/kibapkg.py
ln -sf /usr/share/kibapkg/kibapkg.py /usr/local/bin/kiba
ln -sf /usr/share/kibapkg/kibapkg.py /usr/local/bin/kibapkg

echo "=== Installing pacman shim (real pacman -> /usr/lib/kibaos/pacman-real) ==="
mkdir -p /usr/lib/kibaos
if [ -f /usr/bin/pacman ] && [ ! -f /usr/lib/kibaos/pacman-real ]; then
  mv /usr/bin/pacman /usr/lib/kibaos/pacman-real
fi

cat > /usr/bin/pacman << 'PACMANSHIM'
#!/usr/bin/env bash
REAL=/usr/lib/kibaos/pacman-real

if [ -n "${KIBAOS_REAL_PACMAN:-}" ] || [ ! -t 1 ]; then
  exec "${REAL}" "$@"
fi

rest=("$@"); rest=("${rest[@]:1}")
for a in "${rest[@]}"; do
  case "${a}" in -*) exec "${REAL}" "$@" ;; esac
done

case "$1" in
  -S|--sync)
    [ "${#rest[@]}" -ge 1 ] || exec "${REAL}" "$@"
    exec kiba install "${rest[@]}" ;;
  -R|--remove)
    [ "${#rest[@]}" -ge 1 ] || exec "${REAL}" "$@"
    exec kiba remove "${rest[@]}" ;;
  -Syu|-Syyu)
    [ "${#rest[@]}" -eq 0 ] || exec "${REAL}" "$@"
    exec kiba update ;;
  -Ss|--search)
    [ "${#rest[@]}" -ge 1 ] || exec "${REAL}" "$@"
    exec kiba search "${rest[@]}" ;;
  -Qi)
    [ "${#rest[@]}" -eq 1 ] || exec "${REAL}" "$@"
    exec kiba info "${rest[0]}" ;;
  -Q|--query)
    [ "${#rest[@]}" -eq 0 ] || exec "${REAL}" "$@"
    exec kiba list ;;
  *)
    exec "${REAL}" "$@" ;;
esac
PACMANSHIM
chmod +x /usr/bin/pacman
echo "=== pacman shim installed ==="

cat > /usr/share/applications/kibaos-install.desktop << 'INSTDESK'
[Desktop Entry]
Name=Install KibaOS
Comment=Install KibaOS to your hard drive
Exec=/usr/bin/io.kibaos.oobe
Icon=kibaos
Terminal=false
Type=Application
Categories=System;
Keywords=install;setup;kibaos;
INSTDESK

cat > /usr/share/applications/kibaos-about.desktop << 'ABOUTDESK'
[Desktop Entry]
Name=About KibaOS
Comment=Learn more about KibaOS
Exec=xdg-open https://github.com/WolfTech-Innovations/Kiba
Icon=kibaos
Terminal=false
Type=Application
Categories=System;
ABOUTDESK

for _avahi_desk in avahi-discover bssh bvnc; do
  if [ -f "/usr/share/applications/${_avahi_desk}.desktop" ]; then
    cp "/usr/share/applications/${_avahi_desk}.desktop" \
       "/usr/share/applications/${_avahi_desk}.desktop.bak" 2>/dev/null || true
    printf '[Desktop Entry]\nNoDisplay=true\n' \
      >> "/usr/share/applications/${_avahi_desk}.desktop"
  fi
done

if [ -f "/usr/share/applications/org.gnome.Terminal.desktop" ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/' \
      "/usr/share/applications/org.gnome.Terminal.desktop" || true
  grep -q '^NoDisplay=' "/usr/share/applications/org.gnome.Terminal.desktop" \
    || echo 'NoDisplay=true' >> "/usr/share/applications/org.gnome.Terminal.desktop"
fi

for _bcc_desk in budgie-control-center.desktop \
                 org.buddiesofbudgie.BudgieControlCenter.desktop \
                 budgie-desktop-settings.desktop \
                 org.buddiesofbudgie.BudgieDesktopSettings.desktop; do
  if [ -f "/usr/share/applications/${_bcc_desk}" ]; then
    sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/${_bcc_desk}" || true
    grep -q '^NoDisplay=' "/usr/share/applications/${_bcc_desk}" \
      || echo 'NoDisplay=true' >> "/usr/share/applications/${_bcc_desk}"
  fi
done

for _hidden_desk in kvantummanager.desktop \
                     org.gnome.Sysprof.desktop \
                     sysprof.desktop \
                     sysprof4.desktop \
                     org.gnome.Extensions.desktop \
                     com.github.hedges.gnome-extensions.desktop \
                     qv4l2.desktop \
                     qvidcap.desktop \
                     tuned-gui.desktop \
                     tuned-adm-gui.desktop \
                     lstopo.desktop \
                     hwloc.desktop; do
  if [ -f "/usr/share/applications/${_hidden_desk}" ]; then
    sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/${_hidden_desk}" || true
    grep -q '^NoDisplay=' "/usr/share/applications/${_hidden_desk}" \
      || echo 'NoDisplay=true' >> "/usr/share/applications/${_hidden_desk}"
  fi
done

for _gcc_desk in gnome-control-center.desktop \
                 org.gnome.Settings.desktop; do
  if [ -f "/usr/share/applications/${_gcc_desk}" ]; then
    sed -i 's/^Name=.*/Name=Settings/' "/usr/share/applications/${_gcc_desk}" || true
    sed -i '/^Name\[/d' "/usr/share/applications/${_gcc_desk}" || true
  fi
done

for _panel_desk in gnome-multitasking-panel.desktop \
                    gnome-search-panel.desktop \
                    gnome-wwan-panel.desktop \
                    gnome-online-accounts-panel.desktop; do
  if [ -f "/usr/share/applications/${_panel_desk}" ]; then
    sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/${_panel_desk}" || true
    grep -q '^NoDisplay=' "/usr/share/applications/${_panel_desk}" \
      || echo 'NoDisplay=true' >> "/usr/share/applications/${_panel_desk}"
  fi
done

for _sw_desk in org.gnome.Software.desktop; do
  if [ -f "/usr/share/applications/${_sw_desk}" ]; then
    sed -i 's/^Name=.*/Name=App Store/' "/usr/share/applications/${_sw_desk}" || true
    sed -i '/^Name\[/d' "/usr/share/applications/${_sw_desk}" || true
  fi
done

if [ -f "/usr/share/applications/nm-connection-editor.desktop" ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/nm-connection-editor.desktop" || true
  grep -q '^NoDisplay=' "/usr/share/applications/nm-connection-editor.desktop" \
    || echo 'NoDisplay=true' >> "/usr/share/applications/nm-connection-editor.desktop"
fi

if [ -f "/usr/share/applications/cmake-gui.desktop" ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/cmake-gui.desktop" || true
  grep -q '^NoDisplay=' "/usr/share/applications/cmake-gui.desktop" \
    || echo 'NoDisplay=true' >> "/usr/share/applications/cmake-gui.desktop"
fi

echo 'kernel.sysrq = 0' > /etc/sysctl.d/50-kibaos-disable-sysrq.conf

grep -q '^NAutoVTs' /etc/systemd/logind.conf \
  && sed -i 's/^NAutoVTs=.*/NAutoVTs=1/' /etc/systemd/logind.conf \
  || echo 'NAutoVTs=1' >> /etc/systemd/logind.conf
systemctl mask getty@tty2.service getty@tty3.service getty@tty4.service \
                getty@tty5.service getty@tty6.service

for _chromium_desk in chromium.desktop; do
  if [ -f "/usr/share/applications/${_chromium_desk}" ]; then
    sed -i 's/^Name=.*/Name=Browser/' "/usr/share/applications/${_chromium_desk}" || true
    sed -i '/^Name\[/d' "/usr/share/applications/${_chromium_desk}" || true
    sed -i 's/^Icon=.*/Icon=kibaos-browser/' "/usr/share/applications/${_chromium_desk}" || true
  fi
done

mkdir -p /home/liveuser/Desktop
for src_desktop in kibaos-install kibaos-about; do
  cp "/usr/share/applications/${src_desktop}.desktop" \
     "/home/liveuser/Desktop/${src_desktop}.desktop" 2>/dev/null || true
  chmod +x "/home/liveuser/Desktop/${src_desktop}.desktop" 2>/dev/null || true
done

cat > /etc/environment << 'ENV'
DESKTOP_SESSION=Budgie
XDG_CURRENT_DESKTOP=Budgie
XDG_SESSION_DESKTOP=Budgie
XDG_SESSION_TYPE=wayland
KWIN_FORCE_SW_CURSOR=1
MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
CLUTTER_BACKEND=wayland
SDL_VIDEODRIVER=wayland
KIBAOS_VERSION=rolling
KIBAOS_VENDOR="Kiba Labs, LLC"
ENV

cat > /etc/issue << 'ISSUE'

  ██╗  ██╗██╗██████╗  █████╗  ██████╗ ███████╗
  ██║ ██╔╝██║██╔══██╗██╔══██╗██╔═══██╗██╔════╝
  █████╔╝ ██║██████╔╝███████║██║   ██║███████╗
  ██╔═██╗ ██║██╔══██╗██╔══██║██║   ██║╚════██║
  ██║  ██╗██║██████╔╝██║  ██║╚██████╔╝███████║
  ╚═╝  ╚═╝╚═╝╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝

  KibaOS by Kiba Labs
  Live session: user=liveuser  password=live
  Install: click the desktop icon or run  install

ISSUE

cat > /etc/motd << 'MOTD'
Welcome to KibaOS
MOTD

mkdir -p /etc/systemd/
cat > /etc/systemd/timesyncd.conf << 'TIMESYNCD'
[Time]
NTP=0.arch.pool.ntp.org 1.arch.pool.ntp.org 2.arch.pool.ntp.org 3.arch.pool.ntp.org
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org time.cloudflare.com time.google.com
RootDistanceMaxSec=5
PollIntervalMinSec=32
PollIntervalMaxSec=1024
TIMESYNCD

timedatectl set-local-rtc 0 2>/dev/null || true
systemctl enable systemd-timesyncd

systemctl enable gdm

systemctl enable NetworkManager

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/dns.conf << 'NMDNS'
[main]
dns=none
NMDNS

cat > /usr/local/bin/kibaos-boot-dns << 'BOOTDNS'
#!/bin/bash
echo "nameserver 1.1.1.1" > /etc/resolv.conf
BOOTDNS
chmod +x /usr/local/bin/kibaos-boot-dns

cat > /etc/systemd/system/kibaos-boot-dns.service << 'BOOTDNSSVC'
[Unit]
Description=Pin /etc/resolv.conf to nameserver 1.1.1.1
DefaultDependencies=no
Before=sysinit.target network-pre.target NetworkManager.service
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-boot-dns
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
BOOTDNSSVC
systemctl enable kibaos-boot-dns.service

mkdir -p /usr/lib/kibaos/src
cat > /usr/lib/kibaos/src/kiba_tcpmask.c << 'TCPMASKC'
/* kiba-tcpmask: rewrite TTL + TCP window on outbound SYN/SYN-ACK packets
 * to mask the stock Linux TCP/IP fingerprint. See build.sh for the full
 * rationale on what's touched and what's deliberately left alone. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <linux/netfilter.h>
#include <libnetfilter_queue/libnetfilter_queue.h>

/* Windows 10/11's classic nmap/p0f-visible defaults. */
#define TARGET_TTL    128
#define TARGET_WINDOW 65535

static uint16_t in_cksum(const uint16_t *ptr, int nbytes) {
    long sum = 0;
    while (nbytes > 1) {
        sum += *ptr++;
        nbytes -= 2;
    }
    if (nbytes == 1) {
        uint16_t odd = 0;
        *((uint8_t *)&odd) = *(const uint8_t *)ptr;
        sum += odd;
    }
    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    return (uint16_t)(~sum);
}

static uint16_t tcp_cksum(const struct iphdr *iph, const struct tcphdr *tcph, int tcp_len) {
    struct {
        uint32_t src;
        uint32_t dst;
        uint8_t  zero;
        uint8_t  proto;
        uint16_t len;
    } __attribute__((packed)) ps;

    ps.src   = iph->saddr;
    ps.dst   = iph->daddr;
    ps.zero  = 0;
    ps.proto = IPPROTO_TCP;
    ps.len   = htons((uint16_t)tcp_len);

    int total = (int)sizeof(ps) + tcp_len;
    uint8_t *buf = malloc((size_t)total);
    if (!buf) return 0;
    memcpy(buf, &ps, sizeof(ps));
    memcpy(buf + sizeof(ps), tcph, (size_t)tcp_len);
    uint16_t sum = in_cksum((const uint16_t *)buf, total);
    free(buf);
    return sum;
}

static int cb(struct nfq_q_handle *qh, struct nfgenmsg *nfmsg,
              struct nfq_data *nfa, void *data) {
    (void)nfmsg; (void)data;
    struct nfqnl_msg_packet_hdr *ph = nfq_get_msg_packet_hdr(nfa);
    uint32_t id = ph ? ntohl(ph->packet_id) : 0;

    unsigned char *pkt = NULL;
    int len = nfq_get_payload(nfa, &pkt);
    if (len < (int)sizeof(struct iphdr) || !pkt) {
        return nfq_set_verdict(qh, id, NF_ACCEPT, 0, NULL);
    }

    struct iphdr *iph = (struct iphdr *)pkt;
    int ip_hlen = iph->ihl * 4;

    if (iph->protocol == IPPROTO_TCP && len >= ip_hlen + (int)sizeof(struct tcphdr)) {
        struct tcphdr *tcph = (struct tcphdr *)(pkt + ip_hlen);
        int tcp_len = len - ip_hlen;

        if (tcph->syn) {
            iph->ttl    = TARGET_TTL;
            tcph->window = htons(TARGET_WINDOW);

            iph->check = 0;
            iph->check = in_cksum((const uint16_t *)iph, ip_hlen);

            tcph->check = 0;
            tcph->check = tcp_cksum(iph, tcph, tcp_len);
        }
    }

    return nfq_set_verdict(qh, id, NF_ACCEPT, (uint32_t)len, pkt);
}

int main(void) {
    struct nfq_handle *h = nfq_open();
    if (!h) { perror("nfq_open"); return 1; }

    nfq_unbind_pf(h, AF_INET);
    if (nfq_bind_pf(h, AF_INET) < 0) { perror("nfq_bind_pf"); return 1; }

    struct nfq_q_handle *qh = nfq_create_queue(h, 100, &cb, NULL);
    if (!qh) { perror("nfq_create_queue"); return 1; }

    if (nfq_set_mode(qh, NFQNL_COPY_PACKET, 0xffff) < 0) {
        perror("nfq_set_mode"); return 1;
    }

    int fd = nfq_fd(h);
    char buf[65536];
    int rv;
    while ((rv = (int)recv(fd, buf, sizeof(buf), 0)) >= 0) {
        nfq_handle_packet(h, buf, rv);
    }

    nfq_destroy_queue(qh);
    nfq_close(h);
    return 0;
}
TCPMASKC

gcc -O2 -Wall $(pkg-config --cflags libnetfilter_queue) \
    -o /usr/local/bin/kiba-tcpmask /usr/lib/kibaos/src/kiba_tcpmask.c \
    $(pkg-config --libs libnetfilter_queue) \
  || { echo "FATAL: kiba_tcpmask.c failed to compile" >&2; exit 1; }

mkdir -p /etc/nftables-kiba
cat > /etc/nftables-kiba/tcpmask.conf << 'TCPMASKNFT'
table inet kiba_tcpmask {
  chain output {
    type filter hook output priority mangle; policy accept;
    tcp flags syn queue num 100 bypass
  }
}
TCPMASKNFT

cat > /etc/systemd/system/kiba-tcpmask.service << 'TCPMASKSVC'
[Unit]
Description=KibaOS outbound TCP/IP fingerprint mask
After=network-pre.target
Before=network.target NetworkManager.service
Wants=network-pre.target

[Service]
Type=simple
ExecStartPre=/usr/bin/nft -f /etc/nftables-kiba/tcpmask.conf
ExecStart=/usr/local/bin/kiba-tcpmask
ExecStopPost=-/usr/bin/nft delete table inet kiba_tcpmask
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
TCPMASKSVC
systemctl enable kiba-tcpmask.service

chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser

systemctl mask systemd-oomd.service systemd-oomd.socket
systemctl enable earlyoom

systemctl enable irqbalance

mkdir -p /etc/tuned
echo "balanced" > /etc/tuned/active_profile
systemctl enable tuned

mkdir -p /var/lib/extensions /etc/extensions
systemctl enable systemd-sysext

systemctl enable fstrim.timer

cat > /etc/tmpfiles.d/kibaos.conf << 'TMPFILES'
e /tmp/kibaos-ocr.* - - - 1d
TMPFILES
systemctl enable systemd-tmpfiles-clean.timer

rm -rf /var/cache/pacman/pkg/*
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/doc/*
find /usr/lib/firmware -mindepth 1 -maxdepth 1 \
  ! -name 'i915'    ! -name 'amdgpu'   ! -name 'radeon'  \
  ! -name 'nouveau' ! -name 'iwlwifi*' ! -name 'ath*'    \
  ! -name 'ath10k'  ! -name 'ath11k'   ! -name 'rtl_nic' \
  ! -name 'rtlwifi' ! -name 'rtw88'    ! -name 'rtw89'   \
  ! -name 'sof'     ! -name 'sof-tplg' ! -name 'intel'   \
  -exec rm -rf {} + 2>/dev/null || true
find /usr/share/locale -mindepth 1 -maxdepth 1 \
  ! -name 'en_US' ! -name 'en_GB' ! -name 'locale.alias' \
  -exec rm -rf {} + 2>/dev/null || true
find /usr -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find /usr -name '*.pyc' -delete 2>/dev/null || true
find /usr/lib -name '*.a' -delete 2>/dev/null || true
rm -rf /usr/include/* 2>/dev/null || true
find /usr/share/icons -name 'icon-theme.cache' -delete 2>/dev/null || true
rm -rf /var/lib/pacman/sync/* /tmp/* /var/tmp/* 2>/dev/null || true

chown -R 1000:1000 /home/liveuser

mkdir -p /home/liveuser/.config/autostart
cat > /home/liveuser/.config/autostart/org.buddiesofbudgie.labwc-bridge.desktop << 'NOLABWCBRIDGE'
[Desktop Entry]
Type=Application
Name=Budgie labwc bridge (disabled — KibaOS runs labwc, not labwc)
Exec=/bin/true
Hidden=true
NOLABWCBRIDGE

install -d -m 755 -o 1000 -g 1000 /home/liveuser/.config/dconf
chown -R 1000:1000 /home/liveuser/.config

for _desktop_file in /usr/share/applications/*.desktop; do
  [ -f "${_desktop_file}" ] || continue
  _basename=$(basename "${_desktop_file}")
  _name_line=$(grep -m1 '^Name=' "${_desktop_file}" 2>/dev/null || true)
  [ "${_basename}" = "budgie-welcome.desktop" ] && continue
  if echo "${_basename}" | grep -qi 'budgie' || echo "${_name_line}" | grep -qi 'budgie'; then
    if grep -q '^NoDisplay=' "${_desktop_file}"; then
      sed -i 's/^NoDisplay=.*/NoDisplay=true/' "${_desktop_file}"
    else
      echo 'NoDisplay=true' >> "${_desktop_file}"
    fi
    echo "=== Hid launcher entry: ${_basename} (matched 'budgie') ==="
  fi
done

cat > /etc/resolv.conf << 'RESOLVCONF'
nameserver 1.1.1.1
nameserver 1.0.0.1
RESOLVCONF

if [ "$(uname -m)" = "aarch64" ]; then
  _kver="$(ls -1 /usr/lib/modules | head -n1)"
  if [ -z "${_kver}" ]; then
    echo "ERROR: no kernel module directory found under /usr/lib/modules" >&2
    exit 1
  fi
  mkinitcpio -k "${_kver}" -c /etc/mkinitcpio.conf.d/archiso.conf -g /boot/initramfs-linux.img
fi

pkill -x gvfsd-fuse 2>/dev/null || true
pkill -x gvfsd 2>/dev/null || true
pkill -x dbus-daemon 2>/dev/null || true
sleep 1

# Unmount by reading /proc/mounts: stat() on a dead FUSE mount fails with
# ENOTCONN, so any [ -e ] guard would wrongly skip it.
awk '$3 ~ /^fuse/ {print $2}' /proc/mounts | while read -r _m; do
  fusermount3 -uz "${_m}" 2>/dev/null \
    || fusermount -uz "${_m}" 2>/dev/null \
    || umount -l "${_m}" 2>/dev/null || true
done

rm -rf /root/.gvfs /home/*/.gvfs 2>/dev/null || true
rmdir /run/user/*/gvfs 2>/dev/null || true

echo "=== remaining fuse mounts (should be none): ==="
grep -E 'gvfs|fuse' /proc/mounts || true

rm -f /etc/machine-id
touch /etc/machine-id

sed -i '/^IgnorePkg = linux linux-headers$/d' /etc/pacman.conf
rm -f /etc/kiba-custom-kernel

echo "=== customize_airootfs.sh complete ==="
CUSTOMIZE
chmod +x "${AIROOTFS}/root/customize_airootfs.sh"

cd "${WORKDIR}"
rm -rf "${WORKDIR}/work"

if [ "${KIBA_ARCH}" = "aarch64" ]; then
  mkdir -p "${WORKDIR}/work/pacman-gnupg"
  pacman-key --gpgdir "${WORKDIR}/work/pacman-gnupg" --init
  pacman-key --gpgdir "${WORKDIR}/work/pacman-gnupg" --populate archlinux
  pacman-key --gpgdir "${WORKDIR}/work/pacman-gnupg" --recv-keys \
    68B3537F39A313B3E574D06777193F152BDBE6A6 \
    --keyserver keyserver.ubuntu.com
  pacman-key --gpgdir "${WORKDIR}/work/pacman-gnupg" --lsign-key \
    68B3537F39A313B3E574D06777193F152BDBE6A6
fi

mkarchiso -v -w work -o out "${PROFILE}/"

# ── BIOS/UEFI hybrid ISO, assembled by hand ────────────────────────────────
# mkarchiso has now produced the complete ISO tree in work/iso (arch/ with the
# squashfs + kernel + initramfs, boot/syslinux/ from bios.syslinux, and
# EFI/BOOT/BOOTx64.EFI + boot/grub/ from uefi.grub) plus the FAT ESP image in
# work/efiboot.img. Re-pack that tree with the explicit xorriso command.
cd "${WORKDIR}"
rm -rf iso_root kibaos.iso
mv work/iso iso_root
rm -f out/*.iso   # mkarchiso's own (differently-laid-out) ISO is not needed

for _f in iso_root/boot/syslinux/isolinux.bin \
          iso_root/boot/syslinux/ldlinux.c32 \
          iso_root/boot/syslinux/syslinux.cfg \
          iso_root/EFI/BOOT/BOOTx64.EFI \
          work/efiboot.img \
          /usr/lib/syslinux/bios/isohdpfx.bin; do
  [ -f "${_f}" ] || { echo "ERROR: ${_f} is missing -- cannot build the hybrid ISO" >&2; exit 1; }
done

# the El Torito UEFI image has to live inside the tree it is booted from
cp -f work/efiboot.img iso_root/EFI/BOOT/efiboot.img

xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid KIBAOS \
  -eltorito-boot boot/syslinux/isolinux.bin \
  -eltorito-catalog boot/syslinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -isohybrid-mbr /usr/lib/syslinux/bios/isohdpfx.bin \
  -eltorito-alt-boot -e EFI/BOOT/efiboot.img -no-emul-boot \
  -isohybrid-gpt-basdat -o kibaos.iso iso_root/

if [ -f kibaos.iso ]; then
  mv kibaos.iso "${ISO}.iso"
  # log both boot entries (BIOS + UEFI) and the hybrid MBR/GPT for the build record
  xorriso -indev "${ISO}.iso" -report_el_torito plain -report_system_area plain 2>&1 | tail -n 40 || true
  sha256sum "${ISO}.iso" > "${ISO}.iso.sha256"
  echo "╔══════════════════════════════════════╗"
  echo "║  KibaOS build complete!       ║"
  echo "║  ${ISO}.iso            ║"
  echo "╚══════════════════════════════════════╝"
else
  echo "ERROR: kibaos.iso not found after xorriso!"
  exit 1
fi
