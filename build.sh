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

  KIBA_WALLPAPER_URL="https://github.com/KibaLabsLLC/KibaOS/blob/784ae57c6b8cc0dced3bad2421dcff997935b01c/assets/wallpapers/894220129_2005734460387115_2005077653475460188_n.webp?raw=true"
  KIBA_BOOT_SPLASH_URL="https://github.com/WolfTech-Innovations/Kiba/blob/main/assets/splash/splash.png?raw=true"
  mkdir -p "${_root}/usr/share/kibaos"

  # Source is a WebP; convert to a real JPEG (cover-crop to phone aspect).
  if curl -fL --retry 5 --retry-delay 3 -o /tmp/kiba-wallpaper-src "${KIBA_WALLPAPER_URL}" && \
     magick /tmp/kiba-wallpaper-src -resize 1080x2400^ -gravity center -extent 1080x2400 -quality 92 \
       "${_root}/usr/share/kibaos/wallpaper.jpg"; then
    :
  else
    magick -size 1080x2400 gradient:"#003f5c-#0099cc" "${_root}/usr/share/kibaos/wallpaper.jpg"
  fi
  rm -f /tmp/kiba-wallpaper-src

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
Website=https://kibaos.com
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
HOME_URL="https://kibaos.com"
DOCUMENTATION_URL="https://github.com/KibaLabsLLC/KibaOS/blob/main/WIKI.md"
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
xterm
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

virtiofsd
qemu-guest-agent
breeze-icons
dialog
iproute2
openbsd-netcat
zenity
pciutils


lvm2

tuned
PACKAGES

# ── NVIDIA open kernel modules (Turing / GTX 16xx / RTX 20-series and newer) ──
# nvidia-open is the prebuilt module package for the stock `linux` kernel
# (no DKMS compile in the chroot); it pins the exact linux version from the
# same repo snapshot. nvidia-utils ships the GSP firmware, the nouveau
# blacklist, nvidia_drm modeset/fbdev defaults and the Vulkan/GL ICDs.
# Pascal/Maxwell and older are NOT supported by the open modules; they fall
# back to nouveau/NVK via kibaos-gpu-select (see the GDM section below).
# x86_64 only: Arch ships prebuilt nvidia-open for x86_64 alone.
if [ "${KIBA_ARCH}" = "x86_64" ]; then
  cat >> "${PROFILE}/packages.x86_64" << 'NVIDIAPKGS'
nvidia-open
nvidia-utils
lib32-nvidia-utils
nvidia-settings
egl-wayland
libva-nvidia-driver
NVIDIAPKGS
fi
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
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G systemd.unit=multi-user.target systemd.log_level=info
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
    APPEND archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G systemd.unit=multi-user.target systemd.log_level=info
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
options archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G systemd.unit=multi-user.target systemd.log_level=info
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

WALLPAPER_URL="https://github.com/KibaLabsLLC/KibaOS/blob/10fe6391083a26716f270b4e664bfb8f75424541/assets/wallpapers/DEFC1CA8-F1B1-417E-9612-380D234006C3.png?raw=true"
BOOT_SPLASH_URL="https://github.com/KibaLabsLLC/KibaOS/blob/main/assets/splash/splash.png?raw=true"
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

# Source is a WebP; convert to a real JPEG so every consumer (GDM, gsettings,
# pcmanfm-qt, SDDM) can read it without a webp loader.
if curl -fL --retry 5 --retry-delay 3 -o /tmp/kiba-wallpaper-src "${WALLPAPER_URL}" && \
   magick /tmp/kiba-wallpaper-src -quality 92 "${WALLPAPER_DEST}"; then
  :
else
  magick -size 1920x1080 gradient:"#003f5c-#0099cc" "${WALLPAPER_DEST}"
fi
rm -f /tmp/kiba-wallpaper-src

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
useradd -m -G wheel,audio,video,input,network,storage,power -s /bin/bash "${USERNAME_VAL}" \
  || fail "useradd failed"
echo "${USERNAME_VAL}:${PASSWORD_VAL}" | chpasswd || fail "chpasswd failed"

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

id oem &>/dev/null || useradd -m -G wheel,audio,video,input,network,storage,power -s /bin/bash oem
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

# 8px anti-aliased white dot for the spinner (supersampled 5x, then Lanczos down).
magick -size 40x40 xc:none -fill white -draw "circle 20,20 20,2" \
  -filter Lanczos -resize 8x8 "${KIBA_PLYMOUTH_DIR}/dot.png"
test -s "${KIBA_PLYMOUTH_DIR}/dot.png" || { echo "ERROR: failed to render Plymouth spinner dot" >&2; exit 1; }

# Peeking Kiba mascot (animated, bottom-right of the splash). Fetched from the
# repo and exploded into per-frame PNGs because Plymouth's script module can't
# play GIFs directly.
KIBA_PEEK_URL="https://github.com/KibaLabsLLC/KibaOS/blob/cd80900a3f2c6f319a5733c01f25b3f5e0f5e20e/assets/splash/FCE6EED9-BA57-45CF-AF90-5AA056A069F2.gif?raw=true"
curl -fL --retry 5 --retry-delay 3 -o "${KIBA_PLYMOUTH_DIR}/peek.gif" "${KIBA_PEEK_URL}" || true
file "${KIBA_PLYMOUTH_DIR}/peek.gif" | grep -qi 'GIF image' \
  || { echo "ERROR: failed to download Plymouth mascot GIF (${KIBA_PEEK_URL})" >&2; exit 1; }
magick "${KIBA_PLYMOUTH_DIR}/peek.gif" -coalesce -background none -strip \
  -filter Lanczos -resize 240x "${KIBA_PLYMOUTH_DIR}/peek-%d.png"
rm -f "${KIBA_PLYMOUTH_DIR}/peek.gif"
test -s "${KIBA_PLYMOUTH_DIR}/peek-8.png" || { echo "ERROR: failed to extract mascot frames for Plymouth" >&2; exit 1; }

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
// Centered brand image on a dark background, with a minimal Windows 11-style
// orbiting-dot spinner underneath and a minimal password prompt for
// full-disk-encryption unlocks.

Window.SetBackgroundTopColor(0.043, 0.055, 0.078);
Window.SetBackgroundBottomColor(0.043, 0.055, 0.078);

logo.image = Image("splash.png");
logo.image = logo.image.Scale(logo.image.GetWidth() - 6, logo.image.GetHeight() - 6);
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(Window.GetWidth() / 2 - logo.image.GetWidth() / 2);
logo.sprite.SetY(Window.GetHeight() / 2 - logo.image.GetHeight() / 2);
logo.sprite.SetOpacity(1);

// Peeking mascot: bottom-right corner, flush with the bottom edge so it looks
// like it is peeking up over the screen. Frames are peek-0.png .. peek-8.png
// (extracted from the source GIF at build time), cycled from refresh_callback.
peek_scale = Window.GetHeight() / 1080;
if (peek_scale < 0.6) peek_scale = 0.6;
peek_count = 9;
peek_ticks = 8;      // ticks (~50/s) per frame, matches the GIF's 0.16s delay
peek_margin = Math.Int(40 * peek_scale);
peek_frames = [];
for (peek_i = 0; peek_i < peek_count; peek_i++) {
  peek_img = Image("peek-" + peek_i + ".png");
  peek_frames[peek_i] = peek_img.Scale(Math.Int(peek_img.GetWidth() * peek_scale),
                                       Math.Int(peek_img.GetHeight() * peek_scale));
}
peek_sprite = Sprite(peek_frames[0]);
peek_sprite.SetX(Window.GetWidth() - peek_frames[0].GetWidth() - peek_margin);
peek_sprite.SetY(Window.GetHeight() - peek_frames[0].GetHeight());
peek_sprite.SetZ(10);

// Windows 11-style spinner: five small dots enter one after another, sweep
// around a circle with an ease-in-out (slow, fast, slow, so they bunch up and
// spread out), then fade. Positions come from Math.Sin/Cos; dot.png is a
// pre-rendered anti-aliased circle (see the magick call in the build script).
pi = 3.14159265;
spin_count = 5;
spin_radius = 20;
spin_period = 110;   // ticks (~50/s) for one full cycle
spin_run = 72;       // ticks each dot spends travelling
spin_stagger = 7;    // ticks between consecutive dots
spin_cx = Window.GetWidth() / 2;
spin_cy = logo.sprite.GetY() + logo.image.GetHeight() + 56;

spin_image = Image("dot.png");
spin = [];
for (i = 0; i < spin_count; i++) {
  spin[i] = Sprite(spin_image);
  spin[i].SetOpacity(0);
}

progress_tick = 0;
fun refresh_callback() {
  progress_tick++;
  peek_n = Math.Int(progress_tick / peek_ticks);
  peek_n = peek_n - Math.Int(peek_n / peek_count) * peek_count;
  peek_sprite.SetImage(peek_frames[peek_n]);
  tm = progress_tick - Math.Int(progress_tick / spin_period) * spin_period;
  for (i = 0; i < spin_count; i++) {
    t = tm - i * spin_stagger;
    if (t < 0 || t > spin_run) {
      spin[i].SetOpacity(0);
    } else {
      u = t / spin_run;
      e = u * u * (3 - 2 * u);
      a = 2 * pi * e;
      spin[i].SetX(spin_cx + spin_radius * Math.Sin(a) - spin_image.GetWidth() / 2);
      spin[i].SetY(spin_cy - spin_radius * Math.Cos(a) - spin_image.GetHeight() / 2);
      o = 1;
      if (u < 0.12) o = u / 0.12;
      if (u > 0.88) o = (1 - u) / 0.12;
      spin[i].SetOpacity(o);
    }
  }
}
Plymouth.SetRefreshFunction(refresh_callback);

fun display_password_callback(prompt, bullets) {
  if (prompt == "")
    prompt = "Enter your password to unlock the disk:";
  prompt_text.image = Image.Text(prompt, 1, 1, 1, 1);
  prompt_text.sprite = Sprite(prompt_text.image);
  prompt_text.sprite.SetX(Window.GetWidth() / 2 - prompt_text.image.GetWidth() / 2);
  prompt_text.sprite.SetY(spin_cy + spin_radius + 36);
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

# Cutefish icon theme (https://github.com/cutefishos/icons, Colloid-based).
# Its index.theme inherits hicolor,breeze, so breeze-icons covers anything it
# lacks (it's added to the package list). Installs as /usr/share/icons/Cutefish.
CUTEFISH_ICONS_BUILD="/tmp/cutefish-icons"
rm -rf "${CUTEFISH_ICONS_BUILD}"
git clone --depth 1 https://github.com/cutefishos/icons.git "${CUTEFISH_ICONS_BUILD}"
CMAKE_WAS_PRESENT=1; command -v cmake >/dev/null 2>&1 || { CMAKE_WAS_PRESENT=0; pacman -S --noconfirm --needed cmake; }
cmake -S "${CUTEFISH_ICONS_BUILD}" -B "${CUTEFISH_ICONS_BUILD}/build" -DCMAKE_INSTALL_PREFIX=/usr
cmake --install "${CUTEFISH_ICONS_BUILD}/build"
[ "${CMAKE_WAS_PRESENT}" -eq 0 ] && pacman -Rns --noconfirm cmake || true
test -f /usr/share/icons/Cutefish/index.theme
gtk-update-icon-cache -f /usr/share/icons/Cutefish 2>/dev/null || true
rm -rf "${CUTEFISH_ICONS_BUILD}"
echo "=== Icon theme: Cutefish installed ==="

# VibePanel (https://github.com/prankstr/vibepanel) replaces wl-dock as the
# bottom dock. It's a GTK4 + wlr-layer-shell panel; on labwc it uses its
# "generic" backend (wlr-foreign-toplevel) for the taskbar widget. That generic
# taskbar landed on upstream main after v0.17.2, so this builds a pinned main
# commit with cargo instead of using a release/AUR binary. Only the taskbar
# widget is configured (see ~/.config/vibepanel/ below): no launcher, since the
# look launcher (Super key) does that job. Non-fatal: the session still boots
# without a dock. Needs GTK >= 4.22 (Arch rolling has it).
VIBEPANEL_REPO="https://github.com/prankstr/vibepanel.git"
VIBEPANEL_COMMIT="cd751b15137aa32610ebce2c75644c7be745e35b"
VIBEPANEL_BUILD="/tmp/vibepanel"
rm -f /etc/xdg/autostart/cutefish-dock.desktop /etc/xdg/autostart/wl-dock.desktop
pacman -R --noconfirm cutefish-dock 2>/dev/null || true
pacman -Rns --noconfirm wl-dock 2>/dev/null || true
rm -f /usr/bin/wl-dock
VIBEPANEL_RUST_WAS_PRESENT=1; command -v cargo >/dev/null 2>&1 || VIBEPANEL_RUST_WAS_PRESENT=0
if pacman -S --noconfirm --needed rust pkgconf gettext git \
     gtk4 gtk4-layer-shell libpulse systemd-libs dbus wayland \
   && rm -rf "${VIBEPANEL_BUILD}" && mkdir -p "${VIBEPANEL_BUILD}" \
   && git -C "${VIBEPANEL_BUILD}" init -q \
   && git -C "${VIBEPANEL_BUILD}" fetch -q --depth 1 "${VIBEPANEL_REPO}" "${VIBEPANEL_COMMIT}" \
   && git -C "${VIBEPANEL_BUILD}" checkout -q FETCH_HEAD \
   && (cd "${VIBEPANEL_BUILD}" \
       && CARGO_HOME="${VIBEPANEL_BUILD}/.cargo-home" CARGO_TARGET_DIR="${VIBEPANEL_BUILD}/target" \
          cargo build --release --locked -p vibepanel) \
   && install -Dm755 "${VIBEPANEL_BUILD}/target/release/vibepanel" /usr/bin/vibepanel \
   && test -x /usr/bin/vibepanel; then
  mkdir -p /etc/xdg/autostart
  cat > /etc/xdg/autostart/vibepanel.desktop << 'VIBEPANELAUTO'
[Desktop Entry]
Type=Application
Name=VibePanel
Exec=vibepanel
TryExec=vibepanel
OnlyShowIn=Budgie;GNOME;
X-GNOME-Autostart-Delay=2
NoDisplay=true
VIBEPANELAUTO
  echo "=== vibepanel installed ==="
else
  echo "!! vibepanel build failed -- continuing without a dock" >&2
fi
rm -rf "${VIBEPANEL_BUILD}"
[ "${VIBEPANEL_RUST_WAS_PRESENT}" -eq 0 ] && pacman -Rns --noconfirm rust || true

# look-bin (AUR): keyboard-first launcher for apps, files, clipboard, commands.
# Same steps as `git clone https://aur.archlinux.org/look-bin.git && cd look-bin
# && makepkg -si`, but makepkg refuses to run as root, so it runs as a throwaway
# user (removed afterwards). --noconfirm because the chroot is non-interactive.
# Retried since AUR git/TLS hiccups are common; non-fatal if it still fails.
id kibabuild >/dev/null 2>&1 || useradd -m kibabuild
echo 'kibabuild ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/kibabuild
chmod 440 /etc/sudoers.d/kibabuild
LOOK_OK=0
for _try in 1 2 3 4 5; do
  if su - kibabuild -c 'cd /tmp && rm -rf look-bin && git clone https://aur.archlinux.org/look-bin.git && cd look-bin && makepkg -si --noconfirm --needed'; then
    LOOK_OK=1; break
  fi
  echo "!! look-bin AUR build attempt ${_try}/5 failed -- retrying in 10s" >&2
  sleep 10
done
if [ "${LOOK_OK}" -eq 1 ] && pacman -Q look-bin >/dev/null 2>&1; then
  echo "=== look-bin installed ==="
else
  echo "!! look-bin AUR build failed -- continuing without it" >&2
fi
rm -rf /tmp/look-bin

# Lost Island (https://github.com/MarcoZorn/lost-island): GTK4 + layer-shell
# "Dynamic Island" pill (clock, MPRIS media, volume OSD, notification peeks).
# Upstream's Arch install is `git clone ... && cd lost-island/packaging &&
# makepkg -si`; same throwaway build user as look-bin. Tracks upstream main (not
# pinned). Non-fatal if it fails.
LI_OK=0
for _try in 1 2 3 4 5; do
  if su - kibabuild -c 'cd /tmp && rm -rf lost-island && git clone https://github.com/MarcoZorn/lost-island && cd lost-island/packaging && makepkg -si --noconfirm --needed'; then
    LI_OK=1; break
  fi
  echo "!! lost-island build attempt ${_try}/5 failed -- retrying in 10s" >&2
  sleep 10
done
if [ "${LI_OK}" -eq 1 ] && command -v lost-island >/dev/null 2>&1; then
  echo "=== lost-island installed ==="
else
  echo "!! lost-island build failed -- continuing without it" >&2
fi
rm -rf /tmp/lost-island
rm -f /etc/sudoers.d/kibabuild
userdel -r kibabuild 2>/dev/null || true

# ── Windows Workspace: LSW (Linux Subsystem for Windows) ──────────────
# https://github.com/acceleration3/linux-subsystem-windows
# Installed from the upstream release tarball (same payload as the AUR
# lsw-bin package -- makepkg can't run as root in this chroot). Pinned and
# checksummed; to bump, take pkgver/sha256sums from
# packaging/aur/PKGBUILD at the new tag. x86-64 only (upstream limitation).
LSW_VERSION="0.2.3"
LSW_SHA256="e091f5ece29fb100a3a4cf95f620e18dbb7116a267dffcbc481eeed7dce24e8e"
if [ "$(uname -m)" = "x86_64" ]; then
  # Runtime deps from lsw-bin's PKGBUILD (version constraints dropped;
  # vulkan-driver is virtual, so name the AMD/Intel ICDs explicitly --
  # NVIDIA users get theirs from nvidia-utils).
  pacman -S --noconfirm --needed \
    qt6-base libvirt libisofs libvncserver wimlib hivex \
    spdlog fmt zlib wayland libxkbcommon libdrm \
    vulkan-icd-loader ocl-icd libglvnd libpipewire \
    glib2 pixman gnutls libpng libjpeg-turbo libsasl snappy lzo \
    zstd numactl keyutils libslirp libbpf \
    libelf libcbor systemd-libs libseccomp dtc pam fuse3 \
    libaio liburing capstone libusb \
    edk2-ovmf qemu-img 7zip curl hicolor-icon-theme sdl3 \
    vulkan-radeon vulkan-intel \
    virtiofsd

  LSW_TARBALL="/tmp/lsw-${LSW_VERSION}-x86_64.tar.zst"
  curl -fL --retry 5 --retry-delay 5 -o "${LSW_TARBALL}" \
    "https://github.com/acceleration3/linux-subsystem-windows/releases/download/v${LSW_VERSION}/lsw-${LSW_VERSION}-x86_64.tar.zst"
  echo "${LSW_SHA256}  ${LSW_TARBALL}" | sha256sum -c -
  tar --zstd -xf "${LSW_TARBALL}" -C / --no-same-owner usr
  rm -f "${LSW_TARBALL}"
  # Same rename lsw-bin's package() does, so license files don't collide.
  [ -d /usr/share/licenses/lsw ] && mv /usr/share/licenses/lsw /usr/share/licenses/lsw-bin
  gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
  update-desktop-database /usr/share/applications 2>/dev/null || true
  test -x /usr/bin/lsw-manager
  echo "=== LSW: installed v${LSW_VERSION} ($(/usr/bin/lsw-manager --help >/dev/null 2>&1 && echo ok || echo 'help check skipped')) ==="
else
  echo "=== LSW: skipped -- upstream is x86-64 only, Windows Workspace unavailable on $(uname -m) ==="
fi

# ── LSW auto-install: provision the Windows VM on the installed system's first login ──
# No UI: a background job started from XDG autostart that runs LSW's headless
# installer and reports start/finish/failure as desktop notifications. It does
# nothing on the live ISO or the OEM account (the autostart is in /etc/skel, so
# the user created at install time inherits it), when KVM/disk space aren't
# there, or once a Windows VM already exists. The Windows account password is a
# fresh random string -- the user's KibaOS login password is never stored or
# reused -- kept 0600 in the user's home in case Windows ever asks for it.
if [ -x /usr/bin/lsw-manager ]; then
  cat > /usr/local/bin/kibaos-lsw-autoinstall << 'LSWAUTO'
#!/bin/bash
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kibaos"
DONE="${STATE_DIR}/lsw-installed"
TRIES="${STATE_DIR}/lsw-attempts"
LOG="${STATE_DIR}/lsw-install.log"
PASSFILE="${HOME}/.config/kibaos/windows-password"
MAX_TRIES=3

# Not on the live ISO, not in the OEM staging account, not on non-x86-64.
[ -d /run/archiso ] && exit 0
case "$(id -un)" in liveuser|oem|root) exit 0 ;; esac
[ "$(uname -m)" = "x86_64" ] || exit 0
command -v lsw-manager >/dev/null 2>&1 || exit 0

mkdir -p "${STATE_DIR}"
[ -f "${DONE}" ] && exit 0

note() { command -v notify-send >/dev/null 2>&1 && notify-send -a "Windows" "$1" "$2" 2>/dev/null; logger -t kibaos-lsw-autoinstall "$1: $2"; }

# A VM from an earlier/manual run counts as done.
if command -v virsh >/dev/null 2>&1 \
   && virsh -c qemu:///session list --all --name 2>/dev/null | grep -q '[^[:space:]]'; then
  touch "${DONE}"; exit 0
fi

n=$(cat "${TRIES}" 2>/dev/null || echo 0)
if [ "${n}" -ge "${MAX_TRIES}" ]; then exit 0; fi

# Preconditions that are the machine's fault, not the installer's: don't burn a try.
[ -r /dev/kvm ] && [ -w /dev/kvm ] || { logger -t kibaos-lsw-autoinstall "KVM not available, skipping"; exit 0; }
FREE_GIB="$(df -BG --output=avail "${HOME}" 2>/dev/null | tail -n1 | tr -dc '0-9')"
if [ -n "${FREE_GIB}" ] && [ "${FREE_GIB}" -lt 70 ]; then
  logger -t kibaos-lsw-autoinstall "only ${FREE_GIB} GB free (need ~70), skipping"; exit 0
fi

echo $(( n + 1 )) > "${TRIES}"

# Size the VM from the machine: half the cores and RAM, within sane bounds.
CORES="$(nproc 2>/dev/null || echo 4)"
VM_CPU=$(( CORES / 2 )); [ "${VM_CPU}" -lt 2 ] && VM_CPU=2; [ "${VM_CPU}" -gt 8 ] && VM_CPU=8
MEM_MIB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
VM_MEM=$(( ${MEM_MIB:-8192} / 2 )); [ "${VM_MEM}" -lt 4096 ] && VM_MEM=4096; [ "${VM_MEM}" -gt 16384 ] && VM_MEM=16384

if [ ! -s "${PASSFILE}" ]; then
  mkdir -p "$(dirname "${PASSFILE}")"
  ( umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 > "${PASSFILE}" )
fi
WIN_PASS="$(cat "${PASSFILE}")"

note "Setting up Windows" "Installing in the background -- this can take 15-35 minutes. You can keep using your PC."
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
nice -n 10 ionice -c3 lsw-manager \
  --accept-license \
  --edition "Windows 11" --language "English" \
  --user "KibaUser" --password "${WIN_PASS}" \
  --cpu "${VM_CPU}" --memory "${VM_MEM}" --disk 64 \
  >> "${LOG}" 2>&1
rc=$?

if [ "${rc}" -eq 0 ]; then
  touch "${DONE}"
  note "Windows is ready" "Your Windows apps are available from the app menu."
else
  note "Windows setup hit a snag" "It will retry next time you log in. Details: ${LOG}"
fi
exit "${rc}"
LSWAUTO
  chmod +x /usr/local/bin/kibaos-lsw-autoinstall

  mkdir -p /etc/skel/.config/autostart
  cat > /etc/skel/.config/autostart/kibaos-lsw-autoinstall.desktop << 'LSWAUTODESK'
[Desktop Entry]
Type=Application
Name=Windows auto-setup
Exec=/usr/local/bin/kibaos-lsw-autoinstall
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=30
LSWAUTODESK
  echo "=== LSW: first-login auto-install armed ==="
fi

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

flatpak install --system --noninteractive flathub re.sonny.Junction
echo "=== Junction: installed via flatpak (re.sonny.Junction) ==="

# Planify (task manager, Todoist/Nextcloud sync). Non-fatal if Flathub is unreachable.
if flatpak install --system --noninteractive flathub io.github.alainm23.planify; then
  echo "=== Planify: installed via flatpak (io.github.alainm23.planify) ==="
else
  echo "!! Planify flatpak install failed -- continuing without it" >&2
fi

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
gtk-icon-theme-name=Cutefish
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
gtk-icon-theme-name=Cutefish
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

/* === KibaOS: Floating white squircle panel (top; the VibePanel dock sits at the bottom) ===
 * GTK3 CSS can't draw a true superellipse, so the "squircle" is a
 * rounded rectangle with a radius of ~38% of the 42px panel height (16px) --
 * (the old top bar is gone, so this is the only bar). White fill with
 * dark text/icons; the soft shadow keeps it readable on light wallpapers. */
.budgie-panel {
    margin: 8px 120px 0 120px;
    border-radius: 16px;
    background-image: none;
    background-color: #ffffff;
    color: #1b1f27;
    border: 1px solid rgba(0, 0, 0, 0.06);
    box-shadow:
        0 8px 28px rgba(0, 0, 0, 0.22),
        0 2px 6px  rgba(0, 0, 0, 0.12);
    padding: 0 10px;
}
.budgie-panel .budgie-applet-button,
.budgie-panel button.flat {
    border-radius: 12px;
    background: transparent;
    color: #1b1f27;
    transition: background-color 220ms cubic-bezier(0.5, 0, 0.75, 0); /* fade out */
}
.budgie-panel .budgie-applet-button:hover,
.budgie-panel button.flat:hover {
    background-color: rgba(0, 0, 0, 0.07);
    transition: background-color 150ms cubic-bezier(0.22, 1, 0.36, 1); /* settle in */
}
.budgie-panel .budgie-applet-button:active,
.budgie-panel button.flat:active {
    background-color: rgba(0, 153, 204, 0.25);
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
cat > /usr/local/bin/kibaos-session << 'KIBASESSION'
#!/bin/bash
# Runs labwc + budgie and restarts it if it dies shortly after starting, so a
# crash does not bounce GDM back to the greeter (autologin is only attempted
# once per boot). labwc is started with --session=budgie-desktop, which tells
# labwc to exit when budgie-desktop exits -- and budgie-desktop can exit with
# status 0 even on failure (e.g. the compositor-ready wait fails, or a required
# component such as budgie-panel goes away). So an exit code of 0 only counts as
# a real logout if the session had been up for a while.
# Everything labwc/budgie print goes to the journal under kibaos-labwc.
MAX_QUICK_CRASHES=5     # give up after this many quick exits in a row
QUICK_SECS=20           # a run shorter than this counts as a crash, even rc=0
crashes=0
while :; do
  start=$(date +%s)
  systemd-cat -t kibaos-labwc /usr/bin/labwc --session=/usr/bin/budgie-desktop
  rc=$?
  run=$(( $(date +%s) - start ))
  logger -t kibaos-session "labwc exited rc=${rc} after ${run}s"
  if [ "$run" -lt "$QUICK_SECS" ]; then
    # Keep evidence of why the session died where it survives the greeter:
    # budgie-session logs "Unrecoverable failure in required component ..."
    # when budgie-panel/budgie-daemon crash, which ends the whole session.
    mkdir -p "$HOME/.cache" 2>/dev/null
    {
      echo "=== $(date -Is) labwc rc=${rc} after ${run}s ==="
      journalctl --user -b --no-pager -n 400 2>/dev/null \
        | grep -i -E 'unrecoverable|killed by signal|dumped core|segfault|abort|budgie-session|kibaos-labwc|labwc' \
        | tail -n 60
    } >> "$HOME/.cache/kibaos-session-crash.log" 2>/dev/null
  fi
  # terminated by logout/shutdown signal
  [ "$rc" -eq 143 ] && exit 0
  if [ "$run" -ge "$QUICK_SECS" ]; then
    # a long-running session ending cleanly is a normal logout
    [ "$rc" -eq 0 ] && exit 0
    crashes=0
  else
    crashes=$((crashes + 1))
  fi
  if [ "$crashes" -ge "$MAX_QUICK_CRASHES" ]; then
    logger -t kibaos-session "session exited ${crashes}x in under ${QUICK_SECS}s, giving up"
    exit 1
  fi
  sleep 1
done
KIBASESSION
chmod +x /usr/local/bin/kibaos-session

cat > /usr/share/wayland-sessions/budgie-desktop.desktop << 'WFSESSION'
[Desktop Entry]
Name=Budgie Desktop on labwc
Comment=This session logs you into the Budgie Desktop
Exec=/usr/local/bin/kibaos-session
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
chmod 644 /etc/gdm/custom.conf
chmod 600 /var/lib/AccountsService/users/liveuser
chown root:root /var/lib/AccountsService/users/liveuser

# ── Autologin hardening ─────────────────────────────────────────────────────
# 1. Known-good PAM stack for GDM autologin (pam_shells needs bash in
#    /etc/shells, pam_nologin must not trip, no password prompt).
grep -qx '/bin/bash' /etc/shells || echo '/bin/bash' >> /etc/shells
{
  echo '#%PAM-1.0'
  echo 'auth       required     pam_shells.so'
  echo 'auth       requisite    pam_nologin.so'
  echo 'auth       required     pam_permit.so'
  echo 'account    include      system-local-login'
  echo 'password   required     pam_deny.so'
  echo 'session    include      system-local-login'
  [ -e /usr/lib/security/pam_gnome_keyring.so ] && \
    echo 'session    optional     pam_gnome_keyring.so auto_start'
} > /etc/pam.d/gdm-autologin

# 1b. GDM's udev rule (61-gdm.rules) runs /usr/lib/gdm-disable-wayland on
#     NVIDIA / virtual GPUs, which writes WaylandEnable=false to
#     /run/gdm/custom.conf (overrides /etc/gdm/custom.conf). KibaOS only has a
#     Wayland session (labwc), so GDM then cannot find the autologin session
#     and falls back to the greeter. Mask the rule (ArchWiki GDM page).
mkdir -p /etc/udev/rules.d
ln -sf /dev/null /etc/udev/rules.d/61-gdm.rules

# 2. liveuser must not be locked or expired, or PAM account stage rejects it.
passwd -u liveuser 2>/dev/null || true
chage -I -1 -m 0 -M 99999 -E -1 liveuser 2>/dev/null || true

# 3. Re-assert the config on every boot before GDM starts, in case anything
#    (package update, OEM leftovers) removed or replaced custom.conf.
cat > /usr/local/bin/kibaos-live-autologin << 'LIVEAUTOLOGIN'
#!/bin/bash
# Only act on the live ISO (archiso mounts /run/archiso) and only while the
# live user exists.
[ -d /run/archiso ] || exit 0
# Drop any runtime override that disabled Wayland (see gdm-disable-wayland).
rm -f /run/gdm/custom.conf
id liveuser >/dev/null 2>&1 || exit 0
if ! grep -qs '^AutomaticLogin=liveuser' /etc/gdm/custom.conf; then
  mkdir -p /etc/gdm
  printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=liveuser\nWaylandEnable=true\n' > /etc/gdm/custom.conf
  chmod 644 /etc/gdm/custom.conf
  logger -t kibaos-live-autologin "custom.conf was missing autologin; rewrote it"
fi
mkdir -p /var/lib/AccountsService/users
if ! grep -qs '^Session=budgie-desktop' /var/lib/AccountsService/users/liveuser; then
  printf '[User]\nSession=budgie-desktop\nXSession=budgie-desktop\nSystemAccount=false\n' > /var/lib/AccountsService/users/liveuser
  chmod 600 /var/lib/AccountsService/users/liveuser
fi
passwd -u liveuser >/dev/null 2>&1 || true
exit 0
LIVEAUTOLOGIN
chmod +x /usr/local/bin/kibaos-live-autologin
cat > /etc/systemd/system/kibaos-live-autologin.service << 'LIVEAUTOLOGINSVC'
[Unit]
Description=Ensure GDM autologin for the KibaOS live user
Before=gdm.service display-manager.service
After=local-fs.target systemd-sysusers.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-live-autologin

[Install]
WantedBy=graphical.target
LIVEAUTOLOGINSVC
systemctl enable kibaos-live-autologin.service

# 3b. Make GDM wait for the real GPU driver. Since kernel 6.9 GDM can start its
#     greeter/autologin session on the simpledrm framebuffer before amdgpu/i915/
#     nouveau has loaded; the GPU then appears mid-start and the session dies
#     or hangs, so autologin falls back to the greeter (Ubuntu LP #2115451;
#     Ubuntu patched gdm3 to wait for the real DRM driver). Gate GDM ourselves:
#     wait up to 20s for a DRM card that isn't simpledrm, then go ahead anyway
#     so headless or GPU-less machines still boot.
cat > /usr/local/bin/kibaos-wait-drm << 'WAITDRM'
#!/bin/bash
for _ in $(seq 1 40); do
  for c in /sys/class/drm/card[0-9]*; do
    [ -e "$c/device/driver" ] || continue
    drv="$(basename "$(readlink -f "$c/device/driver")")"
    case "$drv" in
      simpledrm|simple-framebuffer|simplefb|efifb|vesafb) ;;
      *) exit 0 ;;
    esac
  done
  sleep 0.5
done
logger -t kibaos-wait-drm "no non-simpledrm GPU driver after 20s, starting GDM anyway"
exit 0
WAITDRM
chmod +x /usr/local/bin/kibaos-wait-drm
mkdir -p /etc/systemd/system/gdm.service.d
cat > /etc/systemd/system/gdm.service.d/10-kibaos-wait-drm.conf << 'GDMWAITDRM'
[Service]
ExecStartPre=/usr/local/bin/kibaos-wait-drm
TimeoutStartSec=90
GDMWAITDRM

# 3c. NVIDIA: open modules only drive Turing (device ID 0x1e00) and newer.
#     nvidia-utils blacklists nouveau, so a Pascal/Maxwell/Kepler card would
#     be left with no real DRM driver. For those, explicitly modprobe nouveau
#     (blacklist only blocks alias autoload, not an explicit modprobe) before
#     GDM starts. Supported cards are untouched: udev autoloads nvidia.
cat > /usr/local/bin/kibaos-gpu-select << 'GPUSELECT'
#!/bin/bash
for d in /sys/bus/pci/devices/*; do
  [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
  case "$(cat "$d/class" 2>/dev/null)" in 0x0300*|0x0302*) ;; *) continue ;; esac
  id=$(( $(cat "$d/device") ))
  if [ "$id" -lt $((0x1e00)) ]; then
    logger -t kibaos-gpu-select "pre-Turing NVIDIA GPU $(cat "$d/device"): using nouveau"
    modprobe nouveau || true
    exit 0
  fi
done
exit 0
GPUSELECT
chmod +x /usr/local/bin/kibaos-gpu-select
cat > /etc/systemd/system/kibaos-gpu-select.service << 'GPUSELECTSVC'
[Unit]
Description=Use nouveau for NVIDIA GPUs the open kernel modules do not support
After=systemd-udev-trigger.service
Before=gdm.service display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-gpu-select

[Install]
WantedBy=graphical.target
GPUSELECTSVC
systemctl enable kibaos-gpu-select.service

# 4. Fail the build loudly if the pieces autologin depends on are missing.
for _f in /usr/share/wayland-sessions/budgie-desktop.desktop /usr/local/bin/kibaos-session /usr/lib/systemd/system/gdm.service /etc/pam.d/gdm-autologin; do
  [ -e "$_f" ] || { echo "ERROR: autologin prerequisite missing: $_f" >&2; exit 1; }
done
id gdm >/dev/null 2>&1 || echo "WARNING: gdm user missing at build time (created by sysusers at boot)" >&2
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
Description=KibaOS first-boot group catch-up
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
gtk-icon-theme-name=Cutefish
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
gsettings set org.gnome.desktop.interface icon-theme              'Cutefish'
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

# ── No Budgie panel ──────────────────────────────────────────────────────
# budgie-panel rebuilds a default panel whenever its `panels` list is empty
# ("No panels to load" -> create_system_default()). That reads, in order,
# /etc/budgie-desktop/panel.ini, /usr/share/budgie-desktop/panel.ini, then its
# built-in layout. An existing [Panels] section with an empty Panels= list
# creates zero panels, so shipping one here stops the rebuild.
mkdir -p /etc/budgie-desktop
cat > /etc/budgie-desktop/panel.ini << 'EMPTYPANELINI'
[Panels]
Panels=
EMPTYPANELINI

# Backup in case that layout is ignored: shortly after login, if a panel
# showed up anyway, clear the list so budgie-panel drops it. (A bar may flash
# for a few seconds when this fires.)
cat > /usr/local/bin/kibaos-no-panel << 'NOPANEL'
#!/usr/bin/env bash
sleep 6
for _ in 1 2 3; do
  cur="$(gsettings get com.solus-project.budgie-panel panels 2>/dev/null)"
  case "${cur}" in
    "@as []"|"[]") ;;
    *) gsettings set com.solus-project.budgie-panel panels "@as []" ;;
  esac
  sleep 4
done
NOPANEL
chmod +x /usr/local/bin/kibaos-no-panel

cat > "${SKEL}/.config/autostart/kibaos-no-panel.desktop" << 'NOPANELDESK'
[Desktop Entry]
Type=Application
Name=KibaOS No Panel
Exec=/usr/local/bin/kibaos-no-panel
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
NOPANELDESK

cat > "${SKEL}/.config/autostart/kibaos-configure.desktop" << 'AUTOCFG'
[Desktop Entry]
Type=Application
Name=KibaOS First Login Setup
Exec=/usr/local/bin/kibaos-first-login
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTOCFG

cat > "${SKEL}/.config/autostart/kibaos-oem-finish.desktop" << 'OEMAUTOCFG'
[Desktop Entry]
Type=Application
Name=Finish Setting Up KibaOS
Exec=sh -c 'test -f /etc/kibaos/oem-pending && exec /usr/bin/io.kibaos.oobe'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
OEMAUTOCFG


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

# ── look launcher: Super key opens it (labwc), look's own hotkey disabled ──
# look-bin registers its own global hotkey (Alt+Space by default) at runtime;
# launcher_hotkey=none turns that off ("bind lookapp --toggle yourself"), and
# labwc owns the binding instead. Super_L on its own is bound with
# onRelease="yes" so Super+<key> shortcuts (e.g. W-q) don't also pop the
# launcher. lookapp must already be running for --toggle to work, hence the
# autostart. The default labwc keybinds are kept via <default />.
mkdir -p "${SKEL}/.look" "${SKEL}/.config/labwc"
cat > "${SKEL}/.look/config" << 'LOOKCONF'
launcher_hotkey=none
LOOKCONF

cat > "${SKEL}/.config/labwc/rc.xml" << 'LABWCRC'
<?xml version="1.0"?>
<labwc_config>
  <keyboard>
    <default />
    <keybind key="Super_L" onRelease="yes">
      <action name="Execute" command="lookapp --toggle" />
    </keybind>
  </keyboard>

  <!-- On sway/i3/Hyprland look registers its own window rules at runtime; on
       labwc it doesn't, so do the equivalent here: no titlebar/border, and
       keep the launcher out of the dock and the Alt-Tab list. -->
  <windowRules>
    <windowRule identifier="lookapp">
      <serverDecoration>no</serverDecoration>
      <skipTaskbar>yes</skipTaskbar>
      <skipWindowSwitcher>yes</skipWindowSwitcher>
    </windowRule>
    <windowRule identifier="look">
      <serverDecoration>no</serverDecoration>
      <skipTaskbar>yes</skipTaskbar>
      <skipWindowSwitcher>yes</skipWindowSwitcher>
    </windowRule>
  </windowRules>
</labwc_config>
LABWCRC

mkdir -p "${SKEL}/.config/autostart"
cat > "${SKEL}/.config/autostart/lookapp.desktop" << 'LOOKAUTO'
[Desktop Entry]
Type=Application
Name=Look
Exec=lookapp
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
NoDisplay=true
LOOKAUTO

# Lost Island: XDG autostart (upstream also ships a systemd user unit, but the
# session here is labwc+budgie, so autostart is the simpler hook). It exits
# quietly if it isn't installed.
cat > "${SKEL}/.config/autostart/lost-island.desktop" << 'LIAUTO'
[Desktop Entry]
Type=Application
Name=Lost Island
Exec=lost-island
TryExec=lost-island
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
NoDisplay=true
LIAUTO

# ── VibePanel: rounded glass-rectangle dock (bottom, taskbar only) ──────
# No launcher/pinned apps (look on Super does that). The bar surface itself is
# fully transparent; the only visible thing is the taskbar "island" in the
# centre, styled as a frosted-glass rounded rectangle. Hot-reloads on edit.
# GTK CSS has no backdrop-filter, so the glass is a translucent white tint +
# gradient + 1px light rim; theme.blur additionally asks the compositor for real
# blur through ext-background-effect-v1 and is ignored where unsupported.
# The OSD is off so Budgie's own OSD isn't doubled; the notification daemon
# only claims org.freedesktop.Notifications if nothing else already owns it.
mkdir -p "${SKEL}/.config/vibepanel"
cat > "${SKEL}/.config/vibepanel/config.toml" << 'VIBEPANELCONF'
[bar]
position = "bottom"
size = 56
padding = 6
screen_margin = 12
border_radius = 30
background_opacity = 0.0   # transparent bar: only the dock island is drawn
auto_hide = "never"

[widgets]
left = []
center = ["taskbar"]
right = []
border_radius = 30         # % of height: rounded rectangle, not a pill
background_color = "#ffffff"
background_opacity = 0.18  # frosted tint; style.css adds the gloss
popover_background_opacity = 0.85

[widgets.taskbar]
show_icon = true
show_title = false
icon_size = 36
show_workspace_separator = false
show_active = true

[theme]
mode = "dark"
animations = true
ripple = false
shadows = true
blur = true
outline = true
outline_width = 1
outline_color = "#ffffff"
outline_opacity = 0.35

[osd]
enabled = false

[polkit]
enabled = false
VIBEPANELCONF

cat > "${SKEL}/.config/vibepanel/style.css" << 'VIBEPANELCSS'
/* Glass dock: soft top-lit gradient over the translucent tint, bright inner
   top edge, faint dark inner bottom edge, small drop shadow. */
.widget.taskbar {
  background-image: linear-gradient(
    180deg,
    rgba(255, 255, 255, 0.30) 0%,
    rgba(255, 255, 255, 0.10) 55%,
    rgba(255, 255, 255, 0.16) 100%
  );
  box-shadow:
    inset 0 1px 0 rgba(255, 255, 255, 0.50),
    inset 0 -1px 0 rgba(0, 0, 0, 0.12),
    0 2px 10px rgba(0, 0, 0, 0.28);
}

.taskbar-button {
  border-radius: 14px;
}
VIBEPANELCSS

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
  ! -name 'nouveau' ! -name 'nvidia'  ! -name 'iwlwifi*' ! -name 'ath*' \
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
