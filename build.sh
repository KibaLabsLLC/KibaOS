#!/bin/bash
set -ex
KIBA_ARCH="x86_64"
for _a in "$@";do
case "$_a" in
--mobile)KIBA_ARCH="mobile"
esac
done
[ "$KIBA_ARCH" = "x86_64" ]&&[ "${KIBA_MOBILE:-0}" = "1" ]&&KIBA_ARCH="mobile"
export KIBA_ARCH
echo "=== KibaOS build target: $KIBA_ARCH ==="
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
grep -q '^alpm:' "$AIROOTFS/etc/passwd" 2>/dev/null||echo 'alpm:x:951:951::/var/cache/pacman/pkg:/usr/bin/nologin' >>"$AIROOTFS/etc/passwd"
grep -q '^alpm:' "$AIROOTFS/etc/group" 2>/dev/null||echo 'alpm:x:951:' >>"$AIROOTFS/etc/group"
grep -q '^alpm:' "$AIROOTFS/etc/shadow" 2>/dev/null||echo 'alpm:!*:19000::::::' >>"$AIROOTFS/etc/shadow"
mkdir -p "$AIROOTFS/var/cache/pacman/pkg"
chmod 755 "$AIROOTFS/var/cache/pacman" "$AIROOTFS/var/cache/pacman/pkg"
pacman-key --init
pacman-key --populate archlinux
pacman -Syy --noconfirm
pacman -Su --noconfirm
if [ "$KIBA_ARCH" = "mobile" ];then
pacman -S --noconfirm --needed \
base-devel git arch-install-scripts openssl curl jq e2fsprogs zip unzip imagemagick
else
pacman -S --noconfirm --needed \
base-devel git squashfs-tools libisoburn mtools dosfstools \
cmake ninja meson \
grub \
arch-install-scripts \
openssl curl imagemagick jq \
python-docutils
fi
build_kibaos_mobile(){
local _root="/w/mobile-rootfs"
local _out="/w/out"
rm -rf "$_root"
mkdir -p "$_root" "$_out"
pacman-key --init
pacman-key --populate archlinux
pacman-key --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6 \
--keyserver keyserver.ubuntu.com
pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6
cat >/etc/pacman.d/mobile-mirrorlist <<'MIRRORLIST'
Server = http://mirror.archlinuxarm.org/aarch64/$repo
MIRRORLIST
cat >/tmp/mobile-pacman.conf <<'PACMANCONF'
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
mkdir -p "$_root/var/lib/pacman"
pacstrap -C /tmp/mobile-pacman.conf -c -G "$_root" \
base sudo networkmanager \
labwc-is-not-used-placeholder 2>/dev/null||true
pacstrap -C /tmp/mobile-pacman.conf -c -G "$_root" \
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
  ' "$_root/etc/pacman.conf" >"$_root/etc/pacman.conf.new"&&mv "$_root/etc/pacman.conf.new" "$_root/etc/pacman.conf"
sed -i 's/^CheckSpace/#CheckSpace/' "$_root/etc/pacman.conf"
arch-chroot "$_root" pacman-key --init
arch-chroot "$_root" pacman-key --populate archlinux
arch-chroot "$_root" pacman-key --recv-keys \
68B3537F39A313B3E574D06777193F152BDBE6A6 \
--keyserver keyserver.ubuntu.com
arch-chroot "$_root" pacman-key --lsign-key \
68B3537F39A313B3E574D06777193F152BDBE6A6
arch-chroot "$_root" pacman -Syy --noconfirm
arch-chroot "$_root" useradd -m -G wheel builder||true
echo 'builder ALL=(ALL) NOPASSWD: ALL' >"$_root/etc/sudoers.d/builder"
_aur_build(){
local _pkg="$1"
local _extra_args="${2:-}"
arch-chroot "$_root" bash -c "
      su - builder -c '
        cd /tmp &&
        rm -rf $_pkg &&
        git clone --depth 1 https://aur.archlinux.org/$_pkg.git &&
        cd $_pkg &&
        makepkg -si --noconfirm --needed $_extra_args
      '
    "
}
_aur_build_retry(){
local _pkg="$1"
local _extra_args="${2:-}"
local _tries
for _tries in 1 2 3 4 5;do
if _aur_build "$_pkg" "$_extra_args";then
return 0
fi
if [ "$_tries" -lt 5 ];then
echo "!! $_pkg AUR build attempt $_tries/5 failed -- retrying in 10s (this is usually a transient AUR git/TLS blip, not a real package error)..." >&2
sleep 10
fi
done
return 1
}
_aur_build_retry ofono||{
echo "ERROR: ofono AUR build failed -- refusing to ship a mobile rootfs with no working telephony stack. Check the makepkg log above." >&2
rm -f "$_root/etc/sudoers.d/builder"
arch-chroot "$_root" userdel -r builder||true
exit 1
}
for _pkg in wlrctl;do
_aur_build_retry "$_pkg"||echo "!! $_pkg AUR build failed -- check the log above, continuing" >&2
done
rm -f "$_root/etc/sudoers.d/builder"
arch-chroot "$_root" userdel -r builder||true
if ! arch-chroot "$_root" pacman -S --noconfirm --needed sddm;then
echo "ERROR: sddm not available -- refusing to build a mobile rootfs with no lock/login screen. Check the ALARM [extra] repo/mirror." >&2
exit 1
fi
arch-chroot "$_root" systemctl enable sddm
arch-chroot "$_root" bash -c "
    grep -q '^liveuser:' /etc/passwd || \
      echo 'liveuser:x:1000:1000:KibaOS Live User (Password is live):/home/liveuser:/bin/bash' >> /etc/passwd
    grep -q '^liveuser:' /etc/group || \
      echo 'liveuser:x:1000:liveuser' >> /etc/group
    mkdir -p /home/liveuser
    chown 1000:1000 /home/liveuser
  "
KIBA_WALLPAPER_URL="https://raw.githubusercontent.com/KibaLabsLLC/KibaOS/379e9a72e646ad11ce9ab60106e8f1b105486172/assets/wallpapers/914452461_2654744054977065_9116017112023096619_n.webp"
KIBA_BOOT_SPLASH_URL="https://github.com/WolfTech-Innovations/Kiba/blob/main/assets/splash/splash.png?raw=true"
mkdir -p "$_root/usr/share/kibaos"
if curl -fL --retry 5 --retry-delay 3 -o /tmp/kiba-wallpaper-src "$KIBA_WALLPAPER_URL"&&magick /tmp/kiba-wallpaper-src[0] -resize 1080x2400^ -gravity center -extent 1080x2400 -quality 92 \
"$_root/usr/share/kibaos/wallpaper.jpg";then
:
else
magick -size 1080x2400 gradient:"#003f5c-#0099cc" "$_root/usr/share/kibaos/wallpaper.jpg"
fi
rm -f /tmp/kiba-wallpaper-src
curl -fL --retry 5 --retry-delay 3 -o /tmp/kiba-boot-splash-raw.png "$KIBA_BOOT_SPLASH_URL"||true
if [ -f /tmp/kiba-boot-splash-raw.png ]&&file /tmp/kiba-boot-splash-raw.png|grep -qi image;then
magick /tmp/kiba-boot-splash-raw.png -filter Lanczos -resize 256x256 "$_root/usr/share/kibaos/logo-256.png"
rm -f /tmp/kiba-boot-splash-raw.png
else
magick -size 256x256 xc:none \
-fill '#0099cc' -draw 'circle 128,128 128,1' \
-fill white -pointsize 128 -gravity Center -annotate 0 'K' \
"$_root/usr/share/kibaos/logo-256.png"
fi
SDDM_THEME_DIR="$_root/usr/share/sddm/themes/kibaos"
mkdir -p "$SDDM_THEME_DIR"
cp "$_root/usr/share/kibaos/wallpaper.jpg" "$SDDM_THEME_DIR/background.png" 2>/dev/null||true
cp "$_root/usr/share/kibaos/logo-256.png" "$SDDM_THEME_DIR/logo.png" 2>/dev/null||true
cat >"$SDDM_THEME_DIR/metadata.desktop" <<'SDDMMETA'
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
cat >"$SDDM_THEME_DIR/Main.qml" <<'SDDMQML'
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
mkdir -p "$_root/usr/share/wayland-sessions"
cat >"$_root/usr/share/wayland-sessions/kibaos-mobile.desktop" <<'MOBILESESSION'
[Desktop Entry]
Name=KibaOS Mobile
Comment=Budgie panel/raven on phoc
Exec=phoc
Type=Application
DesktopNames=Budgie
MOBILESESSION
mkdir -p "$_root/etc/sddm.conf.d"
cat >"$_root/etc/sddm.conf.d/kibaos-mobile.conf" <<'SDDMMOBILECONF'
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
arch-chroot "$_root" bash -c "
    mkdir -p /var/lib/sddm
    chown sddm:sddm /var/lib/sddm 2>/dev/null || true
    chmod 750 /var/lib/sddm
  "
install -d -m 755 -o 1000 -g 1000 "$_root/home/liveuser/.config/dconf" 2>/dev/null||true
cat >"$_root/etc/resolv.conf" <<'RESOLVCONF'
nameserver 1.1.1.1
nameserver 1.0.0.1
RESOLVCONF
mkdir -p "$_root/etc/phoc"
cat >"$_root/etc/phoc/phoc.ini" <<'PHOCINI'
[core]
xwayland=true

[output:DSI-1]
scale=2
PHOCINI
mkdir -p "$_root/etc/xdg/waybar"
cat >"$_root/etc/xdg/waybar/config" <<'WAYBARCONFIG'
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
cat >"$_root/etc/xdg/waybar/style.css" <<'WAYBARCSS'
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
mkdir -p "$_root/etc/xdg/waybar"
cat >"$_root/etc/xdg/waybar/statusbar-config" <<'STATUSBARCONFIG'
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
cat >"$_root/etc/xdg/waybar/statusbar-style.css" <<'STATUSBARCSS'
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
cat >"$_root/usr/local/bin/kibaos-mobile-cellular" <<'CELLULARSCRIPT'
#!/bin/bash
set -u
_empty(){ echo '{"text":"","tooltip":"No SIM/modem detected","class":"none"}';}
command -v gdbus >/dev/null 2>&1||{
_empty
exit 0
}
_modem_path="$(gdbus call --system --dest org.ofono --object-path / \
--method org.ofono.Manager.GetModems 2>/dev/null|grep -oP "(?<=objpath ')[^']+"|head -n1)"
[ -z "$_modem_path" ]&&{
_empty
exit 0
}
_netreg="$(gdbus call --system --dest org.ofono --object-path "$_modem_path" \
--method org.ofono.NetworkRegistration.GetProperties 2>/dev/null)"
[ -z "$_netreg" ]&&{
_empty
exit 0
}
_status="$(echo "$_netreg"|grep -oP "'Status': <'\K[^']+")"
_strength="$(echo "$_netreg"|grep -oP "'Strength': <(uint16 |byte )?\K[0-9]+"|head -n1)"
_tech="$(echo "$_netreg"|grep -oP "'Technology': <'\K[^']+")"
_carrier="$(echo "$_netreg"|grep -oP "'Name': <'\K[^']+")"
if [ "$_status" != "registered" ]&&[ "$_status" != "roaming" ];then
echo '{"text":"✕","tooltip":"No service","class":"none"}'
exit 0
fi
_strength="${_strength:-0}"
if [ "$_strength" -ge 80 ];then
_bar="█"
elif [ "$_strength" -ge 60 ];then
_bar="▆"
elif [ "$_strength" -ge 40 ];then
_bar="▄"
elif [ "$_strength" -ge 20 ];then
_bar="▂"
else
_bar="▁"
fi
_tech_label="$(echo "$_tech"|tr '[:lower:]' '[:upper:]')"
_roam_suffix=""
[ "$_status" = "roaming" ]&&_roam_suffix=" (roaming)"
echo "{\"text\":\"$_bar $_tech_label\",\"tooltip\":\"$_carrier$_roam_suffix · $_strength%\",\"class\":\"connected\"}"
CELLULARSCRIPT
chmod +x "$_root/usr/local/bin/kibaos-mobile-cellular"
cat >"$_root/usr/local/bin/kibaos-mobile-recents" <<'RECENTSSCRIPT'
#!/bin/bash
if command -v wlrctl >/dev/null 2>&1;then
wlrctl toplevel list
else
echo "kibaos-mobile-recents: wlrctl not installed, no toplevel list available" >&2
fi
RECENTSSCRIPT
chmod +x "$_root/usr/local/bin/kibaos-mobile-recents"
cat >"$_root/etc/xdg/autostart/kibaos-mobile-navbar.desktop" <<'NAVBARAUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Navigation Bar
Exec=waybar -c /etc/xdg/waybar/config -s /etc/xdg/waybar/style.css
X-GNOME-Autostart-enabled=true
NAVBARAUTOSTART
cat >"$_root/etc/xdg/autostart/kibaos-mobile-statusbar.desktop" <<'STATUSBARAUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Status Bar
Exec=waybar -c /etc/xdg/waybar/statusbar-config -s /etc/xdg/waybar/statusbar-style.css
X-GNOME-Autostart-enabled=true
STATUSBARAUTOSTART
arch-chroot "$_root" systemctl enable bluetooth upower||true
cat >"$_root/etc/xdg/autostart/kibaos-mobile-shell.desktop" <<'AUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Shell
Exec=budgie-panel
X-GNOME-Autostart-enabled=true
AUTOSTART
pacstrap -C /tmp/mobile-pacman.conf -c -G "$_root" \
gtk4 libadwaita vala meson ninja glib2 networkmanager
mkdir -p "$_root/root/kibaos-mobile-oobe/src"
cat >"$_root/root/kibaos-mobile-oobe/meson.build" <<'MESONBUILD'
project('kibaos-mobile-oobe', 'vala', 'c')
gtk_dep = dependency('gtk4')
adw_dep = dependency('libadwaita-1')
gio_dep = dependency('gio-2.0')
executable('kibaos-mobile-oobe', 'src/main.vala',
  dependencies: [gtk_dep, adw_dep, gio_dep],
  install: true)
MESONBUILD
mkdir -p "$_root/usr/share/kibaos-mobile-oobe"
cat >"$_root/usr/share/kibaos-mobile-oobe/oobe.css" <<'MOBILEOOBECSS'
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
cat >"$_root/root/kibaos-mobile-oobe/src/main.vala" <<'OOBEVALA'
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
arch-chroot "$_root" bash -c "
    cd /root/kibaos-mobile-oobe &&
    meson setup build &&
    ninja -C build &&
    ninja -C build install
  "||echo "!! kibaos-mobile-oobe failed to build -- check the meson/ninja log above" >&2
cat >"$_root/etc/xdg/autostart/kibaos-mobile-oobe.desktop" <<'OOBEAUTOSTART'
[Desktop Entry]
Type=Application
Name=KibaOS Mobile Setup
Exec=kibaos-mobile-oobe
X-GNOME-Autostart-enabled=true
OOBEAUTOSTART
: "${KIBA_MOBILE_GSI_URL:=https://mirrors.lolinet.com/firmware/halium/GSI/ubports_GSI_installer_v10.zip}"
if [ "${KIBA_SKIP_GSI_FETCH:-0}" = "1" ];then
echo "=== KIBA_SKIP_GSI_FETCH=1 -- skipping Halium GSI fetch (see README-INSTALL.md for a manual pointer) ==="
else
mkdir -p /w/halium-gsi&&cd /w/halium-gsi
if curl -fL -o gsi-fetch.zip "$KIBA_MOBILE_GSI_URL";then
unzip -o gsi-fetch.zip -d extracted >/dev/null
_gsi_img="$(find extracted -maxdepth 3 \( -iname 'system.img' -o -iname '*.img' \) 2>/dev/null|head -n1)"
if [ -n "$_gsi_img" ]&&[ -f "$_gsi_img" ];then
cp "$_gsi_img" "$_out/kibaos-mobile-gsi-arm64.img"
sha256sum "$_out/kibaos-mobile-gsi-arm64.img" >"$_out/kibaos-mobile-gsi-arm64.img.sha256"
echo "=== Fetched Halium GSI: $_out/kibaos-mobile-gsi-arm64.img ==="
else
echo "ERROR: GSI zip downloaded from $KIBA_MOBILE_GSI_URL but no .img found inside -- check KIBA_MOBILE_GSI_URL / mirror layout. Refusing to continue with a mobile build that has no bundled GSI (the installer zip stage would fail anyway, just later and with a more confusing error). Set KIBA_SKIP_GSI_FETCH=1 if you intend to ship a thin installer and push the GSI manually per README-INSTALL.md." >&2
cd /w
return 1
fi
else
echo "ERROR: GSI fetch failed -- curl could not retrieve $KIBA_MOBILE_GSI_URL (bad URL, 404, or network issue). Refusing to continue with a mobile build that has no bundled GSI (the installer zip stage would fail anyway, just later and with a more confusing error). Set KIBA_SKIP_GSI_FETCH=1 if you intend to ship a thin installer and push the GSI manually per README-INSTALL.md." >&2
cd /w
return 1
fi
cd /w
fi
: "${KIBA_MOBILE_HALIUM_RAMDISK_URL:=https://github.com/halium/initramfs-tools-halium/releases/download/continuous/initrd.img-touch-arm64}"
echo "=== Fetching boot.img repack ingredients (generic Halium ramdisk + magiskboot) ==="
mkdir -p /w/boot-repack-tools&&cd /w/boot-repack-tools
curl -fL -o halium-generic-ramdisk.cpio.gz "$KIBA_MOBILE_HALIUM_RAMDISK_URL"||{
echo "!! Halium generic ramdisk fetch failed ($KIBA_MOBILE_HALIUM_RAMDISK_URL) -- see docs.halium.org for the current generic-ramdisk artifact and re-run with a corrected KIBA_MOBILE_HALIUM_RAMDISK_URL. No fallback -- failing the build." >&2
exit 1
}
_magisk_apk_url="$(curl -fsL https://api.github.com/repos/topjohnwu/Magisk/releases/latest|jq -r '.assets[] | select(.name | test("\\.apk$")) | .browser_download_url'|head -n1)"
[ -n "$_magisk_apk_url" ]&&[ "$_magisk_apk_url" != "null" ]||{
echo "!! couldn't resolve the latest Magisk release APK via the GitHub API -- can't fetch magiskboot. No fallback -- failing the build." >&2
exit 1
}
curl -fL -o magisk-latest.apk "$_magisk_apk_url"||{
echo "!! Magisk release APK fetch failed ($_magisk_apk_url) -- can't fetch magiskboot. No fallback -- failing the build." >&2
exit 1
}
unzip -o -j magisk-latest.apk 'lib/arm64-v8a/libmagiskboot.so' -d .||{
echo "!! couldn't extract libmagiskboot.so (arm64-v8a) from the Magisk APK -- release layout may have changed. No fallback -- failing the build." >&2
exit 1
}
[ -f libmagiskboot.so ]||{
echo "!! Magisk APK didn't contain lib/arm64-v8a/libmagiskboot.so -- can't repack boot images on-device. No fallback -- failing the build." >&2
exit 1
}
mv libmagiskboot.so magiskboot
chmod 0755 magiskboot
echo "=== Bundled magiskboot + generic Halium ramdisk for on-device boot.img repack ==="
cd /w
tar -C "$_root" --numeric-owner -cpf "$_out/kibaos-mobile-rootfs.tar" .
gzip -9 "$_out/kibaos-mobile-rootfs.tar"
sha256sum "$_out/kibaos-mobile-rootfs.tar.gz" >"$_out/kibaos-mobile-rootfs.tar.gz.sha256"
_rootfs_kb="$(du -sk "$_root"|cut -f1)"
_img_kb=$((_rootfs_kb+(_rootfs_kb / 5)+262144))
mkfs.ext4 -q -F -L kibaos-rootfs -d "$_root" -m 0 \
"$_out/kibaos-mobile-rootfs.img" "${_img_kb}K"
sha256sum "$_out/kibaos-mobile-rootfs.img" >"$_out/kibaos-mobile-rootfs.img.sha256"
_zip_root="/w/kibaos-mobile-installer-zip"
rm -rf "$_zip_root"
mkdir -p "$_zip_root/META-INF/com/google/android"
cp "$_out/kibaos-mobile-rootfs.img" "$_zip_root/rootfs.img"
if [ -f "$_out/kibaos-mobile-gsi-arm64.img" ];then
cp "$_out/kibaos-mobile-gsi-arm64.img" "$_zip_root/android-rootfs.img"
fi
cp /w/boot-repack-tools/magiskboot "$_zip_root/magiskboot"
cp /w/boot-repack-tools/halium-generic-ramdisk.cpio.gz "$_zip_root/halium-generic-ramdisk.cpio.gz"
echo "# this zip is installed by update-binary directly, not parsed as edify" > \
"$_zip_root/META-INF/com/google/android/updater-script"
cat >"$_zip_root/META-INF/com/google/android/update-binary" <<'UPDATEBINARY'
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
chmod 0755 "$_zip_root/META-INF/com/google/android/update-binary"
(cd "$_zip_root"&&zip -r -X "$_out/kibaos-mobile-installer.zip" . >/dev/null)
sha256sum "$_out/kibaos-mobile-installer.zip" >"$_out/kibaos-mobile-installer.zip.sha256"
rm -rf "$_zip_root"
cat >"$_out/README-INSTALL.md" <<'READMEDOC'
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
echo "║  $_out/kibaos-mobile-rootfs.tar.gz  ║"
echo "╚══════════════════════════════════════╝"
}
if [ "$KIBA_ARCH" = "mobile" ];then
build_kibaos_mobile
exit 0
fi
install_archiso(){
pacman -S --noconfirm --needed archiso
}
install_archiso
WORKDIR="/w"
ISO="kibaos-v$RUN_NUM"
PROFILE="$WORKDIR/kiba-profile"
AIROOTFS="$PROFILE/airootfs"
cd "$WORKDIR"
cp -r /usr/share/archiso/configs/releng/ "$PROFILE"
if [ -f "$PROFILE/airootfs/usr/lib/initcpio/install/archiso" ];then
sed -i '/11-dm-initramfs\.rules/d' \
"$PROFILE/airootfs/usr/lib/initcpio/install/archiso"
fi
mkdir -p "$AIROOTFS"
sed -i 's/^CheckSpace/#CheckSpace/' "$PROFILE/pacman.conf"
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' "$PROFILE/pacman.conf"
if [ "$KIBA_ARCH" = "x86_64" ];then
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "$PROFILE/pacman.conf"
fi
cat >"$PROFILE/profiledef.sh" <<'PROFILEDEF'
#!/usr/bin/env bash
iso_name="kibaos"
iso_label="KIBAOS"
iso_publisher="Kiba Labs, LLC <https://kibaos.com>"
iso_application="KibaOS — A friendly OS"
iso_version="$(date +%Y.%m)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1048576' '-Xdict-size' '1048576' '-no-duplicates' '-noappend')
file_permissions=(
["/etc/shadow"]="0:0:400"
["/etc/gshadow"]="0:0:400"
["/root"]="0:0:750"
["/home/liveuser"]="1000:1000:750")
PROFILEDEF
chmod +x "$PROFILE/profiledef.sh"
if [ "$KIBA_ARCH" = "aarch64" ];then
sed -i "s/bootmodes=('uefi.grub')/bootmodes=('uefi-aarch64.systemd-boot.esp' 'uefi-aarch64.systemd-boot.eltorito')/" "$PROFILE/profiledef.sh"
sed -i 's/arch="x86_64"/arch="aarch64"/' "$PROFILE/profiledef.sh"
sed -i "s/'-Xbcj' 'x86'/'-Xbcj' 'arm64'/" "$PROFILE/profiledef.sh"
fi
mkdir -p "$AIROOTFS/etc"
cat >"$AIROOTFS/etc/os-release" <<'OSRELEASE'
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
cat >"$PROFILE/packages.x86_64" <<'PACKAGES'
archlinux-keyring
dosfstools
mtools
base
linux
linux-headers
linux-firmware
linux-firmware-intel
amd-ucode
intel-ucode
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
pv
lib32-mesa
lib32-vulkan-icd-loader
pkg-config
greetd
greetd-tuigreet
dconf
gsettings-desktop-schemas
pcmanfm-qt
qt6-wayland
webkit2gtk-4.1
python-gobject
grim
slurp
wl-clipboard
tesseract
tesseract-data-eng
libnotify
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
pipewire-jack
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
if [ "$KIBA_ARCH" = "x86_64" ];then
cat >>"$PROFILE/packages.x86_64" <<'NVIDIAPKGS'
nvidia-open
nvidia-utils
lib32-nvidia-utils
nvidia-settings
egl-wayland
libva-nvidia-driver
NVIDIAPKGS
fi
if [ "$KIBA_ARCH" = "aarch64" ];then
sed -i '/^linux-firmware-intel$/d' "$PROFILE/packages.x86_64"
sed -i '/^\(amd\|intel\)-ucode$/d' "$PROFILE/packages.x86_64"
sed -i '/^# linux-firmware split the Intel GuC\/HuC blobs/,/^# fails and KWin can never get a working renderer/d' \
"$PROFILE/packages.x86_64"
sed -i '/^thermald$/d' "$PROFILE/packages.x86_64"
sed -i '/^syslinux$/d' "$PROFILE/packages.x86_64"
sed -i '/^lib32-mesa$/d; /^lib32-vulkan-icd-loader$/d' "$PROFILE/packages.x86_64"
sed -i '/^mkinitcpio-archiso$/d' "$PROFILE/packages.x86_64"
sed -i 's/^linux$/linux-aarch64/; s/^linux-headers$/linux-aarch64-headers/' \
"$PROFILE/packages.x86_64"
mv "$PROFILE/packages.x86_64" "$PROFILE/packages.aarch64"
fi
mkdir -p "$AIROOTFS/etc/mkinitcpio.conf.d"
cat >"$AIROOTFS/etc/mkinitcpio.conf.d/archiso.conf" <<'INITRAMFS'
HOOKS=(base udev kms plymouth keyboard keymap modconf memdisk archiso block filesystems)
COMPRESSION="gzip"
INITRAMFS
if [ "$KIBA_ARCH" = "aarch64" ];then
sed -i 's/ memdisk / /' "$AIROOTFS/etc/mkinitcpio.conf.d/archiso.conf"
fi
cat >"$AIROOTFS/etc/mkinitcpio.conf.d/installed.conf" <<'INSTALLED_HOOKS'
HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap block filesystems fsck)
COMPRESSION="gzip"
INSTALLED_HOOKS
mkdir -p "$AIROOTFS/etc/mkinitcpio.d"
cat >"$AIROOTFS/etc/mkinitcpio.d/linux.preset" <<'PRESET'
PRESETS=('archiso')
ALL_kver='/boot/vmlinuz-linux'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'
archiso_image='/boot/initramfs-linux.img'
PRESET
if [ "$KIBA_ARCH" = "aarch64" ];then
rm -f "$AIROOTFS/etc/mkinitcpio.d/linux-aarch64.preset"
fi
rm -rf "$PROFILE/syslinux"
if [ "$KIBA_ARCH" = "x86_64" ];then
rm -rf "$PROFILE/efiboot"
mkdir -p "$PROFILE/grub"
cat >"$PROFILE/grub/grub.cfg" <<'GRUBCFG'
set default=0
set timeout=0
insmod all_video
insmod gfxterm
terminal_output gfxterm

search --no-floppy --set=root --label %ARCHISO_LABEL%

menuentry "KibaOS" --class kibaos {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.use-simpledrm=1
    initrd /%INSTALL_DIR%/boot/intel-ucode.img /%INSTALL_DIR%/boot/amd-ucode.img /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
}

menuentry "KibaOS (safe mode)" --class kibaos {
    linux /%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G systemd.unit=multi-user.target systemd.log_level=info
    initrd /%INSTALL_DIR%/boot/intel-ucode.img /%INSTALL_DIR%/boot/amd-ucode.img /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
}

menuentry 'UEFI Firmware Settings' --id 'uefi-firmware' {
    fwsetup
}
GRUBCFG
else
mkdir -p "$PROFILE/efiboot/loader/entries"
cat >"$PROFILE/efiboot/loader/loader.conf" <<'LOADERCONF'
timeout 0
default kibaos.conf
LOADERCONF
cat >"$PROFILE/efiboot/loader/entries/kibaos.conf" <<'ENTRYCONF'
title   KibaOS
linux   /%INSTALL_DIR%/boot/%ARCH%/Image
initrd  /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
options archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 plymouth.use-simpledrm=1
ENTRYCONF
cat >"$PROFILE/efiboot/loader/entries/kibaos-safe.conf" <<'ENTRYCONF'
title   KibaOS (safe mode)
linux   /%INSTALL_DIR%/boot/%ARCH%/Image
initrd  /%INSTALL_DIR%/boot/%ARCH%/initramfs-linux.img
options archisobasedir=%INSTALL_DIR% archisolabel=%ARCHISO_LABEL% cow_spacesize=4G systemd.unit=multi-user.target systemd.log_level=info
ENTRYCONF
fi
PACMAN_CONF="$PROFILE/pacman.conf"
if [ -f "$PACMAN_CONF" ];then
grep -q 'NoExtract' "$PACMAN_CONF"||sed -i '/^\[options\]/a NoExtract  = usr/share/man/* usr/share/info/* usr/share/doc/*\nNoExtract  = usr/share/locale/* !usr/share/locale/en_US/* !usr/share/locale/en_GB/* !usr/share/locale/locale.alias' \
"$PACMAN_CONF"
fi
LIVE_HASH=$(openssl passwd -6 "live")
grep -q '^liveuser:' "$AIROOTFS/etc/passwd" 2>/dev/null||echo 'liveuser:x:1000:1000:KibaOS Live User:/home/liveuser:/bin/bash' >>"$AIROOTFS/etc/passwd"
grep -q '^liveuser:' "$AIROOTFS/etc/group" 2>/dev/null||echo 'liveuser:x:1000:liveuser' >>"$AIROOTFS/etc/group"
grep -q '^liveuser:' "$AIROOTFS/etc/shadow" 2>/dev/null||echo "liveuser:$LIVE_HASH:19000:0:99999:7:::" >>"$AIROOTFS/etc/shadow"
mkdir -p "$AIROOTFS/home/liveuser"
mkdir -p "$AIROOTFS/etc/sudoers.d"
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' >"$AIROOTFS/etc/sudoers.d/liveuser"
chmod 0440 "$AIROOTFS/etc/sudoers.d/liveuser"
WANTS="$AIROOTFS/etc/systemd/system"
mkdir -p "$WANTS/default.target.wants" "$WANTS/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/graphical.target "$WANTS/default.target"
ln -sf /usr/lib/systemd/system/aurade-greetd.service "$WANTS/display-manager.service"
ln -sf /usr/lib/systemd/system/pacman-init.service "$WANTS/multi-user.target.wants/pacman-init.service"
ln -sf /usr/lib/systemd/system/bluetooth.service "$WANTS/multi-user.target.wants/bluetooth.service"
mkdir -p "$AIROOTFS/root"
cat >"$AIROOTFS/root/customize_airootfs.sh" <<'CUSTOMIZE'
#!/usr/bin/env bash
set -e
export GVFS_DISABLE_FUSE=1
rm -f /etc/machine-id
touch /etc/machine-id
systemd-machine-id-setup
rm /usr/lib/sysusers.d/basic.conf
rm /usr/lib/sysusers.d/arch.conf
systemd-sysusers||true
systemd-tmpfiles --create 2>/dev/null||true
id polkitd &>/dev/null||useradd -r -U -M -d /run/polkit -s /usr/bin/nologin polkitd
useradd -r -s /usr/bin/nologin -U alpm 2>/dev/null||true
mkdir -p /var/cache/pacman/pkg
chmod 755 /var/cache/pacman /var/cache/pacman/pkg
chown -R alpm:alpm /var/cache/pacman
if [ "$(uname -m)" = "x86_64" ];then
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
fi
if [ "$(uname -m)" = "x86_64" ];then
cat >/etc/pacman.d/mirrorlist <<'MIRRORLIST'
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
if [ "$(uname -m)" = "aarch64" ];then
pacman-key --recv-keys 68B3537F39A313B3E574D06777193F152BDBE6A6 \
--keyserver keyserver.ubuntu.com
pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6
fi
pacman -Syy --noconfirm
pacman -Scc --noconfirm
systemctl disable earlyoom 2>/dev/null||true
mkdir -p /etc/systemd/oomd.conf.d
cat >/etc/systemd/oomd.conf.d/kibaos.conf <<'OOMDCONF'
[OOM]
SwapUsedLimit=90%
DefaultMemoryPressureDurationSec=20s
OOMDCONF
systemctl enable systemd-oomd
cat >/etc/sysctl.d/99-kibaos.conf <<'SYSCTL'
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
echo 'LANG=en_US.UTF-8' >/etc/locale.conf
echo 'kibaos' >/etc/hostname
cat >/etc/hosts <<'HOSTS'
127.0.0.1   localhost
::1         localhost
127.0.1.1   kibaos.localdomain kibaos
HOSTS
for g in users wheel audio video input network storage power;do
groupadd -r "$g" 2>/dev/null||true
usermod -aG "$g" liveuser 2>/dev/null||true
done
echo "liveuser:live"|chpasswd
grep -qx '/bin/bash' /etc/shells||echo '/bin/bash' >>/etc/shells
cp -aT /etc/skel/ /home/liveuser/ 2>/dev/null||true
chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser
sed -i 's/#Storage=auto/Storage=volatile/' /etc/systemd/journald.conf
sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sed -i 's/#HandleSuspendKey=suspend/HandleSuspendKey=ignore/' /etc/systemd/logind.conf
sed -i 's/#IdleAction=ignore/IdleAction=ignore/' /etc/systemd/logind.conf
grep -q 'IdleActionSec' /etc/systemd/logind.conf||echo 'IdleActionSec=0' >>/etc/systemd/logind.conf
grep -q 'HandleHibernateKey' /etc/systemd/logind.conf||echo 'HandleHibernateKey=ignore' >>/etc/systemd/logind.conf
grep -q 'HandleLidSwitchDocked' /etc/systemd/logind.conf||echo 'HandleLidSwitchDocked=ignore' >>/etc/systemd/logind.conf
grep -q 'HandleLidSwitchExternalPower' /etc/systemd/logind.conf||echo 'HandleLidSwitchExternalPower=ignore' >>/etc/systemd/logind.conf
grep -q 'HandlePowerKey' /etc/systemd/logind.conf&&sed -i 's/^HandlePowerKey=.*/HandlePowerKey=poweroff/' /etc/systemd/logind.conf
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
WALLPAPER_URL="https://raw.githubusercontent.com/KibaLabsLLC/KibaOS/379e9a72e646ad11ce9ab60106e8f1b105486172/assets/wallpapers/914452461_2654744054977065_9116017112023096619_n.webp"
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
curl -fL --retry 5 --retry-delay 3 -o "$BOOT_SPLASH_RAW" "$BOOT_SPLASH_URL"||true
if [ -f "$BOOT_SPLASH_RAW" ]&&file "$BOOT_SPLASH_RAW"|grep -qi 'image';then
magick "$BOOT_SPLASH_RAW" -filter Lanczos -resize '480x480>' "$BOOT_SPLASH"
cp "$BOOT_SPLASH_RAW" "$LOGO_SRC"
rm -f "$BOOT_SPLASH_RAW"
fi
if curl -fL --retry 5 --retry-delay 3 -o /tmp/kiba-wallpaper-src "$WALLPAPER_URL"&&magick /tmp/kiba-wallpaper-src[0] -quality 92 "$WALLPAPER_DEST";then
:
else
magick -size 1920x1080 gradient:"#003f5c-#0099cc" "$WALLPAPER_DEST"
fi
rm -f /tmp/kiba-wallpaper-src
if [ -f "$LOGO_SRC" ]&&file "$LOGO_SRC"|grep -qi 'image';then
magick "$LOGO_SRC" -filter Lanczos -resize 256x256 "$LOGO_256"
magick "$LOGO_SRC" -filter Lanczos -resize 96x96 "$LOGO_96"
magick "$LOGO_SRC" -filter Lanczos -resize 48x48 "$LOGO_48"
magick "$LOGO_SRC" -filter Lanczos -resize 32x32 "$LOGO_32"
rm -f "$LOGO_SRC"
else
for sz in 256 96 48 32;do
magick -size ${sz}x$sz xc:none \
-fill '#0099cc' -draw "circle $((sz/2)),$((sz/2)) $((sz/2)),1" \
-fill white -pointsize $((sz/2)) -gravity Center -annotate 0 'K' \
"/usr/share/kibaos/logo-$sz.png"
done
fi
cp "$LOGO_256" /usr/share/pixmaps/kibaos.png
ln -sf /usr/share/pixmaps/kibaos.png /usr/share/pixmaps/kibaos-logo.png
mkdir -p /usr/share/icons/hicolor/256x256/apps \
/usr/share/icons/hicolor/48x48/apps \
/usr/share/icons/hicolor/32x32/apps
cp "$LOGO_256" /usr/share/icons/hicolor/256x256/apps/kibaos.png
cp "$LOGO_48" /usr/share/icons/hicolor/48x48/apps/kibaos.png
cp "$LOGO_32" /usr/share/icons/hicolor/32x32/apps/kibaos.png
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null||true
BADGE_WHITE_SRC="/usr/share/kibaos/badge-white.png"
magick "$LOGO_256" -alpha extract -threshold 50% /tmp/kiba-badge-alpha.png
magick -size 256x256 xc:white /tmp/kiba-badge-white.png
magick /tmp/kiba-badge-white.png /tmp/kiba-badge-alpha.png \
-alpha off -compose CopyOpacity -composite "$BADGE_WHITE_SRC"
rm -f /tmp/kiba-badge-alpha.png /tmp/kiba-badge-white.png
mkdir -p /usr/share/icons/hicolor/scalable/actions \
/usr/share/icons/hicolor/symbolic/actions \
/usr/share/icons/hicolor/24x24/actions \
/usr/share/icons/hicolor/22x22/actions \
/usr/share/icons/hicolor/16x16/actions
for sz in 16 22 24 32 48;do
magick "$BADGE_WHITE_SRC" -filter Lanczos -resize ${sz}x$sz \
"/usr/share/icons/hicolor/${sz}x$sz/actions/pane-show-symbolic.png"
done
cp "$BADGE_WHITE_SRC" /usr/share/icons/hicolor/scalable/actions/pane-show-symbolic.png
cp "$BADGE_WHITE_SRC" /usr/share/icons/hicolor/symbolic/actions/pane-show-symbolic.png
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null||true
if [ -f "$BOOT_SPLASH" ];then
cp "$BOOT_SPLASH" "$INSTALLER_LOGO"
else
cp "$LOGO_256" "$INSTALLER_LOGO"
fi
pacman -Syu --noconfirm git
set -euo pipefail
mkdir -p /usr/share/icons/hicolor/scalable/actions
cp /usr/share/kibaos/logo-256.png /usr/share/icons/hicolor/scalable/actions/kibaos-watermark-symbolic.png 2>/dev/null||true
gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null||true
userdel -r builduser 2>/dev/null||true
rm -f /etc/sudoers.d/builduser
KIBA_PLYMOUTH_DIR="/usr/share/plymouth/themes/kibaos"
mkdir -p "$KIBA_PLYMOUTH_DIR"
if [ -f "$BOOT_SPLASH" ];then
cp "$BOOT_SPLASH" "$KIBA_PLYMOUTH_DIR/splash.png"
else
cp /usr/share/kibaos/logo-256.png "$KIBA_PLYMOUTH_DIR/splash.png" 2>/dev/null||true
fi
KIBA_WAVE_DEPS=""
for _p in python-numpy python-pillow;do
pacman -Q "$_p" >/dev/null 2>&1||KIBA_WAVE_DEPS="$KIBA_WAVE_DEPS $_p"
done
pacman -S --noconfirm --needed python-numpy python-pillow
cat >/tmp/kiba-wave-gen.py <<'KIBAWAVEGEN'
#!/usr/bin/env python3
"""
Generates the assets for KibaOS's boot animation: kAI's gradient wave (see
KibaLabsLLC/kAI ui/widgets.cpp, WaveWidget::paintEvent) on white, the colour of
kAI's card.

Why two kinds of asset instead of full-colour frames
----------------------------------------------------
All four wave layers are filled with the *same* gradient colour G(x) at
different opacities a_i, so over a background colour BG

    pixel = G(x) * C(x, y) + BG * (1 - C(x, y)),
    C = 1 - prod_i(1 - a_i * m_i(x, y))

where m_i is each layer's antialiased coverage. Plymouth's script module
cannot draw polygons, but it can stack sprites, so the theme shows:

    1. gradient strip   (wave-gradient.png)    scrolled with SetX -> exact drift
    2. BG-coloured alpha mask (wave-N.png), alpha = 1 - C, one per loop frame
    3. BG-coloured side covers (wave-cover.png) hiding the part of the strip that
       sticks out past the wave region

The mask frames loop seamlessly: every sine's angular rate is rounded to a whole
number of cycles per loop (LOOP_S), staying within a few percent of kAI's rates.

Usage: kiba-wave-gen.py OUTDIR
Needs: python-numpy, python-pillow
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

W, H = 640, 240
SS = 8                      # supersampling for antialiasing
BG = (255, 255, 255)         # background; also the colour of the masks and covers
FPS = 25                    # Plymouth refreshes at ~50 Hz, so 2 ticks per frame
LOOP_S = 6                  # seconds per seamless loop
NFRAMES = FPS * LOOP_S

FEATHER_X = 0.14
FEATHER_Y = 0.30

CYAN, BLUE = (0x6A, 0xD8, 0xFD), (0x3E, 0x64, 0xEB)
VIOLET, PINK = (0x7E, 0x63, 0xFA), (0xF2, 0x9E, 0xF5)
STOPS = [(0.00, CYAN), (0.33, BLUE), (0.66, VIOLET), (1.00, PINK)]
GRAD_LEN = 1.15 * W                 # gradient runs 0 .. 1.15*w, ReflectSpread
GRAD_PERIOD = 2 * GRAD_LEN          # reflect pattern repeats every 2 lengths
DRIFT_PX_PER_S = 36.0 * (W / 320)   # kAI: 36 px/s at its 320 px width

LAYERS = [(1.15, 0.55, 70, 0.0), (0.80, 0.90, 105, 1.7),
          (0.55, 1.25, 150, 3.1), (0.95, 0.75, 255, 4.6)]

SPEED = 3.4                  # phase rate, rad/s (kAI Thinking)
AMP_BASE, AMP_SWING, AMP_RATE = 0.30, 0.12, 3.2


def cycles_per_loop(rate):
    return max(1, round(rate * LOOP_S / (2 * math.pi)))


def coverage(angle1, angle2, amp):
    """C(x, y) in 0..1, shape (H, W): union of the four translucent layers."""
    xs = np.arange(0, W + 4 + 1, 3.0)
    u = xs / W
    env = np.power(np.sin(math.pi * np.clip(u, 0, 1)), 0.9) * 0.65 + 0.35
    A = H * 0.40 * amp
    base_y = H * 0.60
    keep = np.ones((H, W), dtype=np.float64)          # prod(1 - a_i * m_i)
    for (wl, _sm, alpha, off), a1, a2 in zip(LAYERS, angle1, angle2):
        y = base_y - A * env * (np.sin(u * 2 * math.pi / wl * 1.6 + a1 + off)
                                + 0.35 * np.sin(u * 2 * math.pi * 2.3 - a2 + off * 2))
        o = 0.5
        pts = ([(0.0 * SS - o, H * SS - o)] + [(x * SS - o, yy * SS - o) for x, yy in zip(xs, y)]
               + [((W + 4) * SS - o, H * SS - o)])
        im = Image.new("L", (W * SS, H * SS), 0)
        ImageDraw.Draw(im).polygon(pts, fill=255)
        m = np.asarray(im, dtype=np.float64).reshape(H, SS, W, SS).mean(axis=(1, 3)) / 255.0
        keep *= 1.0 - (alpha / 255.0) * m
    return 1.0 - keep


def feather():
    def ramp(d, span):
        if span <= 0:
            return np.ones_like(d)
        t = np.clip(d / span, 0, 1)
        return t * t * (3 - 2 * t)
    x = np.arange(W) + 0.5
    y = np.arange(H) + 0.5
    fx = ramp(np.minimum(x, W - x), FEATHER_X * W)
    fy = ramp(H - y, FEATHER_Y * H)
    return np.outer(fy, fx)


def gradient_strip(width, height):
    """kAI's reflecting 4-stop gradient, sampled over `width` px."""
    t = (np.arange(width) + 0.5) / GRAD_LEN
    t = np.mod(t, 2.0)
    t = np.where(t > 1.0, 2.0 - t, t)
    pos = [s[0] for s in STOPS]
    chans = [np.interp(t, pos, [s[1][c] for s in STOPS]) for c in range(3)]
    row = np.stack(chans, axis=-1)
    return np.repeat(row[None, :, :], height, axis=0)


def main(outdir):
    os.makedirs(outdir, exist_ok=True)
    rates1 = [cycles_per_loop(SPEED * sm) * 2 * math.pi / LOOP_S for (_, sm, _, _) in LAYERS]
    rates2 = [cycles_per_loop(SPEED * 0.7 * sm) * 2 * math.pi / LOOP_S for (_, sm, _, _) in LAYERS]
    amp_rate = cycles_per_loop(AMP_RATE) * 2 * math.pi / LOOP_S
    fe = feather()

    masks = []
    for f in range(NFRAMES):
        t = f / FPS
        amp = AMP_BASE + AMP_SWING * math.sin(amp_rate * t)
        c = coverage([r * t for r in rates1], [r * t for r in rates2], amp) * fe
        masks.append(1.0 - c)                          # BG overlay's alpha

    lit = np.min(np.stack(masks), axis=0) < 0.999
    rows = np.where(lit.any(axis=1))[0]
    top = max(0, int(rows[0]) - 2)
    hc = H - top

    for f, a in enumerate(masks):
        rgba = np.zeros((hc, W, 4), dtype=np.uint8)
        rgba[..., :3] = BG
        rgba[..., 3] = np.round(a[top:] * 255).astype(np.uint8)
        Image.fromarray(rgba, "RGBA").save(os.path.join(outdir, "wave-%d.png" % f), optimize=True)

    strip_w = int(math.ceil(GRAD_PERIOD)) + W
    strip = gradient_strip(strip_w, hc).round().astype(np.uint8)
    Image.fromarray(strip, "RGB").save(os.path.join(outdir, "wave-gradient.png"), optimize=True)

    cover_w = int(math.ceil(GRAD_PERIOD))
    Image.new("RGB", (cover_w, hc), BG).save(os.path.join(outdir, "wave-cover.png"), optimize=True)

    with open(os.path.join(outdir, "wave-params.script"), "w") as fh:
        fh.write("wave_w = %d;\nwave_h = %d;\nwave_frames = %d;\nwave_fps = %d;\n"
                 % (W, hc, NFRAMES, FPS))
        fh.write("wave_period = %d;\nwave_drift = %.4f;\nwave_cover_w = %d;\n"
                 % (math.ceil(GRAD_PERIOD), DRIFT_PX_PER_S, cover_w))
    print("wave: %d frames, %dx%d, strip %dx%d" % (NFRAMES, W, hc, strip_w, hc))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: kiba-wave-gen.py OUTDIR")
    main(sys.argv[1])
KIBAWAVEGEN
python3 /tmp/kiba-wave-gen.py "$KIBA_PLYMOUTH_DIR"||{
echo "ERROR: failed to render the Plymouth wave animation" >&2
exit 1
}
test -s "$KIBA_PLYMOUTH_DIR/wave-0.png" -a -s "$KIBA_PLYMOUTH_DIR/wave-149.png" \
-a -s "$KIBA_PLYMOUTH_DIR/wave-gradient.png" -a -s "$KIBA_PLYMOUTH_DIR/wave-cover.png"||{
echo "ERROR: Plymouth wave frames are missing" >&2
exit 1
}
rm -f /tmp/kiba-wave-gen.py
cat >"$KIBA_PLYMOUTH_DIR/kibaos.plymouth" <<'PLYMOUTHDESC'
[Plymouth Theme]
Name=KibaOS
Description=KibaOS boot splash (kAI wave)
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/kibaos
ScriptFile=/usr/share/plymouth/themes/kibaos/kibaos.script
PLYMOUTHDESC
cat "$KIBA_PLYMOUTH_DIR/wave-params.script" - >"$KIBA_PLYMOUTH_DIR/kibaos.script" <<'PLYMOUTHSCRIPT'
// KibaOS boot splash -- Plymouth script theme.
// kAI's gradient wave, centered on white (kAI's card colour). Nothing else is drawn.
// wave_* constants are prepended by the build (generated alongside the frames).
//
// Compositing, bottom to top:
//   z=1  wave-gradient.png  kAI's reflecting gradient, scrolled sideways (exact drift)
//   z=2  wave-N.png         white alpha mask whose holes are the wave (looping frames)
//   z=3  wave-cover.png     white blocks hiding the strip outside the wave region
// Because every layer of kAI's wave is the same gradient colour at a different
// opacity, gradient under a white overlay of alpha (1 - coverage) is
// pixel-identical to painting the layers on white.

Window.SetBackgroundTopColor(1, 1, 1);
Window.SetBackgroundBottomColor(1, 1, 1);

wave_x = Math.Int((Window.GetWidth() - wave_w) / 2);
wave_y = Math.Int((Window.GetHeight() - wave_h) / 2);

wave_strip = Sprite(Image("wave-gradient.png"));
wave_strip.SetZ(1);
wave_strip.SetX(wave_x);
wave_strip.SetY(wave_y);

wave_images = [];
for (wave_i = 0; wave_i < wave_frames; wave_i++)
  wave_images[wave_i] = Image("wave-" + wave_i + ".png");
wave_mask = Sprite(wave_images[0]);
wave_mask.SetZ(2);
wave_mask.SetX(wave_x);
wave_mask.SetY(wave_y);

wave_cover_image = Image("wave-cover.png");
wave_cover_left = Sprite(wave_cover_image);
wave_cover_left.SetZ(3);
wave_cover_left.SetX(wave_x - wave_cover_w);
wave_cover_left.SetY(wave_y);
wave_cover_right = Sprite(wave_cover_image);
wave_cover_right.SetZ(3);
wave_cover_right.SetX(wave_x + wave_w);
wave_cover_right.SetY(wave_y);

// The refresh callback runs ~50 times per second.
wave_tick = 0;
fun refresh_callback() {
  wave_tick++;

  frame = Math.Int(wave_tick * wave_fps / 50);
  frame = frame - Math.Int(frame / wave_frames) * wave_frames;
  wave_mask.SetImage(wave_images[frame]);

  drift = wave_tick * wave_drift / 50;
  drift = drift - Math.Int(drift / wave_period) * wave_period;
  wave_strip.SetX(wave_x - Math.Int(drift));
}
Plymouth.SetRefreshFunction(refresh_callback);

// Full-disk-encryption unlock: the only other thing that is ever drawn, and
// only while a password is being asked for. Sits just under the wave.
pw_prompt_sprite = Sprite();
pw_bullets_sprite = Sprite();
pw_y = wave_y + wave_h + 24;

fun display_password_callback(prompt, bullets) {
  if (prompt == "")
    prompt = "Enter your password to unlock the disk:";
  pw_prompt_image = Image.Text(prompt, 0.482, 0.510, 0.722, 1);   // kAI "muted" 7B82B8
  pw_prompt_sprite.SetImage(pw_prompt_image);
  pw_prompt_sprite.SetOpacity(1);
  pw_prompt_sprite.SetX(Window.GetWidth() / 2 - pw_prompt_image.GetWidth() / 2);
  pw_prompt_sprite.SetY(pw_y);

  pw_text = "";
  for (pw_i = 0; pw_i < bullets; pw_i++)
    pw_text = pw_text + "*";
  if (pw_text == "") pw_text = " ";
  pw_bullets_image = Image.Text(pw_text, 0.078, 0.118, 0.310, 1); // kAI "navy" 141E4F
  pw_bullets_sprite.SetImage(pw_bullets_image);
  pw_bullets_sprite.SetOpacity(1);
  pw_bullets_sprite.SetX(Window.GetWidth() / 2 - pw_bullets_image.GetWidth() / 2);
  pw_bullets_sprite.SetY(pw_y + pw_prompt_image.GetHeight() + 8);
}
Plymouth.SetDisplayPasswordFunction(display_password_callback);

fun display_normal_callback() {
  pw_prompt_sprite.SetOpacity(0);
  pw_bullets_sprite.SetOpacity(0);
}
Plymouth.SetDisplayNormalFunction(display_normal_callback);
PLYMOUTHSCRIPT
rm -f "$KIBA_PLYMOUTH_DIR/wave-params.script"
mkdir -p /etc/plymouth
cat >/etc/plymouth/plymouthd.conf <<'PLYMOUTHD'
[Daemon]
Theme=kibaos
ShowDelay=0
DeviceTimeout=8
PLYMOUTHD
plymouth-set-default-theme -R kibaos 2>/dev/null||true
echo "=== Boot splash: custom kibaos Plymouth theme installed ==="
cp "$KIBA_PLYMOUTH_DIR/splash.png" /usr/share/plymouth/arch-logo.png
for _theme_dir in bgrt spinner;do
if [ -d "/usr/share/plymouth/themes/$_theme_dir" ];then
cp "$KIBA_PLYMOUTH_DIR/splash.png" \
"/usr/share/plymouth/themes/$_theme_dir/watermark.png"
fi
done
rm -rf /tmp/kiba-plymouth-snapshot
cp -a "$KIBA_PLYMOUTH_DIR" /tmp/kiba-plymouth-snapshot
CUTEFISH_ICONS_BUILD="/tmp/cutefish-icons"
rm -rf "$CUTEFISH_ICONS_BUILD"
git clone --depth 1 https://github.com/cutefishos/icons.git "$CUTEFISH_ICONS_BUILD"
CMAKE_WAS_PRESENT=1
command -v cmake >/dev/null 2>&1||{
CMAKE_WAS_PRESENT=0
pacman -S --noconfirm --needed cmake
}
cmake -S "$CUTEFISH_ICONS_BUILD" -B "$CUTEFISH_ICONS_BUILD/build" -DCMAKE_INSTALL_PREFIX=/usr
cmake --install "$CUTEFISH_ICONS_BUILD/build"
[ "$CMAKE_WAS_PRESENT" -eq 0 ]&&pacman -Rns --noconfirm cmake||true
test -f /usr/share/icons/Cutefish/index.theme
gtk-update-icon-cache -f /usr/share/icons/Cutefish 2>/dev/null||true
rm -rf "$CUTEFISH_ICONS_BUILD"
echo "=== Icon theme: Cutefish installed ==="
rm -f /etc/xdg/autostart/cutefish-dock.desktop /etc/xdg/autostart/wl-dock.desktop
pacman -R --noconfirm cutefish-dock 2>/dev/null||true
pacman -Rns --noconfirm wl-dock 2>/dev/null||true
rm -f /usr/bin/wl-dock
# Resolve JACK provider conflict: prefer pipewire-jack, drop jack2
if pacman -Q jack2 >/dev/null 2>&1;then
pacman -Rdd --noconfirm jack2
fi
pacman -S --noconfirm --needed pipewire-jack qt6-multimedia-ffmpeg
AURADE_KEY_FPR="BC390DCF360B2184DBBF008B8B2AB2EFE667CB69"
AURADE_KEY_URL="https://raw.githubusercontent.com/Cam396/aurade/main/pins/aurade-release.gpg"
AURADE_REPO_URL="https://github.com/Cam396/aurade/releases/download/repo-x86_64"
AURADE_OK=0
if curl -fsSL --retry 5 --retry-delay 3 -o /tmp/aurade-release.gpg "$AURADE_KEY_URL"&&[ "$(gpg --show-keys --with-colons /tmp/aurade-release.gpg|awk -F: '$1=="fpr"{print $10;exit}')" = "$AURADE_KEY_FPR" ]&&pacman-key --add /tmp/aurade-release.gpg&&pacman-key --lsign-key "$AURADE_KEY_FPR";then
grep -q '^\[aurade\]' /etc/pacman.conf||printf '\n[aurade]\nServer = %s\n' "$AURADE_REPO_URL" >>/etc/pacman.conf
if pacman -Syu --noconfirm --needed aurade&&[ -x /usr/bin/aurade-session-supervisor ]&&[ -f /usr/share/wayland-sessions/aurade.desktop ];then
AURADE_OK=1
fi
else
echo "ERROR: could not fetch/verify the AuraDE release key (expected $AURADE_KEY_FPR)" >&2
fi
rm -f /tmp/aurade-release.gpg
if [ "$AURADE_OK" -eq 1 ];then
pacman -S --noconfirm --needed aurade-greeter weston||{ echo "ERROR: could not install aurade-greeter" >&2;exit 1; }
echo "=== AuraDE installed ==="
else
echo "ERROR: AuraDE install failed -- Budgie is gone, so there is no desktop to fall back to" >&2
exit 1
fi
# Find every file containing the string (raw bytes), then same-length replace, binary-safe, display-case only
# Rebrand AuraDE -> KibaOS and set the tagline. The old raw grep|sed could not see
# names inside gzip/brotli-compressed .pak entries or UTF-16 strings, which is where
# the "Welcome to AuraDE" OOBE title lives. This walks paks properly.
pacman -S --noconfirm --needed python python-brotli||echo "!! python-brotli missing -- brotli pak entries will be skipped" >&2
cat >/usr/local/bin/kiba-rebrand <<'KIBAREBRAND'
#!/usr/bin/env python3
"""Rebrand AuraDE -> KibaOS everywhere it can hide, and set the tagline.

Handles what a raw `grep -F | sed` cannot see:
  * .pak resource bundles (v5): entries are gzip/brotli compressed, so the
    name is invisible until decompressed. Entries are rewritten and the pak is
    rebuilt (ids, aliases and entry order unchanged, verified before writing).
  * UTF-16LE strings (Chromium keeps many as char16_t).
  * Only the display spelling "AuraDE" (never AURADE_* env vars or *Aurade* identifiers).
Name swaps are same length (6 chars) so ELF binaries stay valid; the tagline is
only rewritten in paks and text files, where length may change.
"""
import gzip, os, struct, sys

# Display name ONLY. AURADE_* are environment variables read by the session scripts and
# *Aurade* (requestAuradeNetworkApps, onAuradeUpdateClick_ ...) are identifiers shared
# between the WebUI JS and the browser binary: renaming either breaks things.
NAME = [("AuraDE", "KibaOS")]
TAGLINES_OLD = ["Fast. Secure. Effortless."]
TAGLINE_NEW = "Fast. Simple. Limitless."
BROTLI_MAGIC = b"\x1e\x9b"
try:
    import brotli
except Exception:
    brotli = None

stats = {"paks": 0, "entries": 0, "files": 0, "skipped": []}

def swap(b, tagline):
    """Replace in UTF-8 and UTF-16LE; returns (new_bytes, changed)."""
    out = b
    pairs = list(NAME)
    if tagline:
        pairs.extend((t, TAGLINE_NEW) for t in TAGLINES_OLD)
    for old, new in pairs:
        for enc in ("utf-8", "utf-16-le"):
            o, n = old.encode(enc), new.encode(enc)
            if o in out:
                out = out.replace(o, n)
    return out, out != b

# ---- OOBE welcome-screen art ------------------------------------------------
# The welcome page stacks a static first frame (iron-icon oobe-illos:connect-illo)
# under a Lottie player (welcome_screen_animation.json). There is no file to swap:
# both are pak entries and the SVG/Lottie are themed vector art. So: (1) the page
# markup is edited to show a plain <img> of /images/cfm/welcome.svg instead (the
# JS looks the Lottie element up with querySelector + instanceof, so removing it
# is safe), and (2) that SVG resource -- identified by content, ids move between
# builds -- is replaced with one that wraps the KibaOS raccoon art (data: URI
# inside an SVG-as-image is not subject to the page CSP).
WELCOME_ART_B64 = "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"
WELCOME_SVG = ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
               'width="648" height="320" viewBox="0 0 648 320"><image width="648" height="320" '
               'preserveAspectRatio="xMidYMid meet" href="data:image/png;base64,' + WELCOME_ART_B64 + '"/></svg>').encode()
WELCOME_IMG = b'<img src="/images/cfm/welcome.svg" class="oobe-illustration" id="kibaWelcomeImage" aria-hidden="true">'
import re
WELCOME_BLOCK = re.compile(rb'<iron-icon id="welcomeAnimationFirstFrame".*?</oobe-cr-lottie>', re.S)
art_done = {"html": 0, "svg": 0}

def welcome_art(raw):
    if raw.startswith(b'<svg id="welcomeSvg"'):
        art_done["svg"] += 1
        return WELCOME_SVG
    if b'id="welcomeAnimationFirstFrame"' in raw and b'welcome_screen_animation.json' in raw:
        new, n = WELCOME_BLOCK.subn(WELCOME_IMG, raw)
        if n:
            art_done["html"] += 1
            return new
    return raw

def unpack_entry(p):
    if p[:2] == b"\x1f\x8b":
        return "gzip", gzip.decompress(p)
    if p[:2] == BROTLI_MAGIC:
        if brotli is None:
            raise RuntimeError("brotli entry but python brotli module missing")
        size = int.from_bytes(p[2:8], "little")
        raw = brotli.decompress(p[8:])
        if len(raw) != size:
            raise RuntimeError("brotli size mismatch")
        return "brotli", raw
    return None, p

def pack_entry(kind, raw):
    if kind == "gzip":
        return gzip.compress(raw, 9, mtime=0)
    if kind == "brotli":
        return BROTLI_MAGIC + len(raw).to_bytes(6, "little") + brotli.compress(raw)
    return raw

def do_pak(path):
    d = open(path, "rb").read()
    # Locale paks (locales/*.pak) are gzip-compressed as a WHOLE FILE around a
    # normal pak; unwrap, rewrite the inner pak, and gzip it back.
    if d[:2] == b"\x1f\x8b":
        return do_pak_bytes(path, gzip.decompress(d), True)
    return do_pak_bytes(path, d, False)

def do_pak_bytes(path, d, wrapped):
    if len(d) < 12 or struct.unpack_from("<I", d, 0)[0] != 5:
        stats["skipped"].append(path + " (not pak v5)")
        return False
    enc = d[4]
    count, acount = struct.unpack_from("<HH", d, 8)
    ents = [struct.unpack_from("<HI", d, 12 + i * 6) for i in range(count + 1)]
    abase = 12 + (count + 1) * 6
    aliases = d[abase:abase + acount * 4]
    payloads, changed = [], 0
    for i in range(count):
        p = d[ents[i][1]:ents[i + 1][1]]
        try:
            kind, raw = unpack_entry(p)
        except Exception as e:
            stats["skipped"].append("%s entry %d: %s" % (path, ents[i][0], e))
            payloads.append(p)
            continue
        raw2 = welcome_art(raw)
        new, ch = swap(raw2, True)
        ch = ch or raw2 is not raw
        if ch:
            p = pack_entry(kind, new)
            changed += 1
        payloads.append(p)
    if not changed:
        return False
    # rebuild
    head = d[:8] + struct.pack("<HH", count, acount)
    off = 12 + (count + 1) * 6 + acount * 4
    table, body = b"", b""
    for i in range(count):
        table += struct.pack("<HI", ents[i][0], off + len(body))
        body += payloads[i]
    table += struct.pack("<HI", ents[count][0], off + len(body))
    out = head + table + aliases + body
    # verify: same ids, same alias table, same count
    c2, a2 = struct.unpack_from("<HH", out, 8)
    e2 = [struct.unpack_from("<HI", out, 12 + i * 6) for i in range(c2 + 1)]
    assert (c2, a2) == (count, acount)
    assert [x[0] for x in e2] == [x[0] for x in ents]
    assert out[abase:abase + acount * 4] == aliases
    tmp = path + ".kiba-tmp"
    open(tmp, "wb").write(gzip.compress(out, 9, mtime=0) if wrapped else out)
    os.chmod(tmp, os.stat(path).st_mode)
    os.replace(tmp, path)
    stats["paks"] += 1
    stats["entries"] += changed
    return True

def do_file(path):
    # never touch signed/keyed material: a changed byte breaks the signature
    if "keyring" in path or "gnupg" in path or path.endswith((".gpg", ".sig", ".asc", ".kbx", ".key", ".pem")):
        return
    try:
        if os.path.islink(path) or not os.path.isfile(path) or os.path.getsize(path) > 2 * 1024 ** 3:
            return
        d = open(path, "rb").read()
    except OSError:
        return
    if b"AuraDE" not in d and "AuraDE".encode("utf-16-le") not in d and \
       not any(t.encode() in d or t.encode("utf-16-le") in d for t in TAGLINES_OLD):
        if not path.endswith(".pak"):
            return
    if path.endswith(".pak"):
        do_pak(path)
        return
    is_text = b"\x00" not in d[:8192] and not d.startswith(b"\x7fELF")
    new, ch = swap(d, is_text)
    if ch:
        mode = os.stat(path).st_mode
        open(path, "wb").write(new)
        os.chmod(path, mode)
        stats["files"] += 1

def pak_entries(path):
    d = open(path, "rb").read()
    if d[:2] == b"\x1f\x8b":
        d = gzip.decompress(d)
    if len(d) < 12 or struct.unpack_from("<I", d, 0)[0] != 5:
        return
    count = struct.unpack_from("<H", d, 8)[0]
    ents = [struct.unpack_from("<HI", d, 12 + i * 6) for i in range(count + 1)]
    for i in range(count):
        p = d[ents[i][1]:ents[i + 1][1]]
        try:
            p = unpack_entry(p)[1]
        except Exception:
            continue
        yield ents[i][0], p

def verify(roots):
    """Fail the build if the welcome title could still say AuraDE."""
    bad = []
    for root in roots:
        for dp, dn, fn in os.walk(root):
            for f in fn:
                path = os.path.join(dp, f)
                if f.endswith(".pak") and not os.path.islink(path):
                    for i, p in pak_entries(path):
                        if b"AuraDE" in p or "AuraDE".encode("utf-16-le") in p:
                            bad.append("%s entry %d" % (path, i))
    en = [r for r in roots if os.path.isdir(r)]
    found_locale = any(os.path.exists(os.path.join(r, "locales", "en-US.pak")) for r in en)
    print("kiba-rebrand: verify: %d pak entr(ies) still contain AuraDE; en-US locale pak %s"
          % (len(bad), "present" if found_locale else "NOT FOUND"))
    for b in bad[:20]:
        print("kiba-rebrand: STILL AuraDE: " + b, file=sys.stderr)
    return not bad and found_locale

def main(roots):
    for root in roots:
        for dp, dn, fn in os.walk(root):
            for f in fn:
                do_file(os.path.join(dp, f))
    print("kiba-rebrand: welcome art: page=%(html)d svg=%(svg)d" % art_done)
    print("kiba-rebrand: %(paks)d pak(s) / %(entries)d pak entries / %(files)d file(s) rewritten" % stats)
    for s in stats["skipped"]:
        print("kiba-rebrand: SKIPPED " + s, file=sys.stderr)
    if not verify(roots):
        sys.exit(2)

if __name__ == "__main__":
    main(sys.argv[1:] or ["/usr/lib/chromiumos-ash", "/usr/lib/aurade-greeter", "/usr/share"])
KIBAREBRAND
chmod +x /usr/local/bin/kiba-rebrand
python3 /usr/local/bin/kiba-rebrand /usr/lib/chromiumos-ash /usr/lib/aurade-greeter /usr/share /opt||{ echo "ERROR: kiba-rebrand failed" >&2;exit 1; }
# Verify: no display-case name left in ASCII or UTF-16, anywhere that ships
_left="$(grep -rlaE 'AuraDE|A.u.r.a.D.E|Fast\. Secure\. Effortless' /usr/lib/chromiumos-ash /usr/lib/aurade-greeter /usr/share /opt 2>/dev/null|grep -v '\.pak$'||true)"
[ -n "$_left" ]&&echo "!! rebrand: display-name strings still present in: $_left" >&2
# Keep the tool and re-run it whenever pacman reinstalls/updates the AuraDE packages --
# otherwise an update (or the installer pulling the package again) restores "AuraDE".
mkdir -p /etc/pacman.d/hooks
cat >/etc/pacman.d/hooks/99-kibaos-rebrand.hook <<'KIBAHOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = chromiumos-ash
Target = aurade
Target = aurade-greeter

[Action]
Description = Rebranding AuraDE -> KibaOS...
When = PostTransaction
Exec = /usr/bin/python3 /usr/local/bin/kiba-rebrand /usr/lib/chromiumos-ash /usr/lib/aurade-greeter
KIBAHOOK
sed -i '/^CHROME=/a CHROME_FLAGS="${CHROME_FLAGS:-} --default-wallpaper-large=/usr/share/kibaos/wallpaper.jpg --default-wallpaper-small=/usr/share/kibaos/wallpaper.jpg"' /usr/bin/chromiumos-ash-session
id kibabuild >/dev/null 2>&1||useradd -m kibabuild
echo 'kibabuild ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/kibabuild
chmod 440 /etc/sudoers.d/kibabuild
LI_OK=0
for _try in 1 2 3 4 5;do
if su - kibabuild -c 'cd /tmp && rm -rf lost-island && git clone https://github.com/MarcoZorn/lost-island && cd lost-island/packaging && makepkg -si --noconfirm --needed';then
LI_OK=1
break
fi
echo "!! lost-island build attempt $_try/5 failed -- retrying in 10s" >&2
sleep 10
done
if [ "$LI_OK" -eq 1 ]&&command -v lost-island >/dev/null 2>&1;then
echo "=== lost-island installed ==="
else
echo "!! lost-island build failed -- continuing without it" >&2
fi
rm -rf /tmp/lost-island
rm -f /etc/sudoers.d/kibabuild
userdel -r kibabuild 2>/dev/null||true
LSW_VERSION="0.2.3"
LSW_SHA256="e091f5ece29fb100a3a4cf95f620e18dbb7116a267dffcbc481eeed7dce24e8e"
if [ "$(uname -m)" = "x86_64" ];then
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
LSW_TARBALL="/tmp/lsw-$LSW_VERSION-x86_64.tar.zst"
curl -fL --retry 5 --retry-delay 5 -o "$LSW_TARBALL" \
"https://github.com/acceleration3/linux-subsystem-windows/releases/download/v$LSW_VERSION/lsw-$LSW_VERSION-x86_64.tar.zst"
echo "$LSW_SHA256  $LSW_TARBALL"|sha256sum -c -
tar --zstd -xf "$LSW_TARBALL" -C / --no-same-owner usr
rm -f "$LSW_TARBALL"
[ -d /usr/share/licenses/lsw ]&&mv /usr/share/licenses/lsw /usr/share/licenses/lsw-bin
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null||true
update-desktop-database /usr/share/applications 2>/dev/null||true
test -x /usr/bin/lsw-manager
echo "=== LSW: installed v$LSW_VERSION ($(/usr/bin/lsw-manager --help >/dev/null 2>&1&&echo ok||echo 'help check skipped')) ==="
else
echo "=== LSW: skipped -- upstream is x86-64 only, Windows Workspace unavailable on $(uname -m) ==="
fi
if [ -x /usr/bin/lsw-manager ];then
cat >/usr/local/bin/kibaos-lsw-autoinstall <<'LSWAUTO'
#!/bin/bash
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kibaos"
DONE="$STATE_DIR/lsw-installed"
TRIES="$STATE_DIR/lsw-attempts"
LOG="$STATE_DIR/lsw-install.log"
PASSFILE="$HOME/.config/kibaos/windows-password"
MAX_TRIES=3
[ -d /run/archiso ]&&exit 0
case "$(id -un)" in liveuser|oem|root)exit 0;esac
[ "$(uname -m)" = "x86_64" ]||exit 0
command -v lsw-manager >/dev/null 2>&1||exit 0
mkdir -p "$STATE_DIR"
[ -f "$DONE" ]&&exit 0
note(){
command -v notify-send >/dev/null 2>&1&&notify-send -a "Windows" "$1" "$2" 2>/dev/null
logger -t kibaos-lsw-autoinstall "$1: $2"
}
if command -v virsh >/dev/null 2>&1&&virsh -c qemu:///session list --all --name 2>/dev/null|grep -q '[^[:space:]]';then
touch "$DONE"
exit 0
fi
n=$(cat "$TRIES" 2>/dev/null||echo 0)
if [ "$n" -ge "$MAX_TRIES" ];then exit 0;fi
[ -r /dev/kvm ]&&[ -w /dev/kvm ]||{
logger -t kibaos-lsw-autoinstall "KVM not available, skipping"
exit 0
}
FREE_GIB="$(df -BG --output=avail "$HOME" 2>/dev/null|tail -n1|tr -dc '0-9')"
if [ -n "$FREE_GIB" ]&&[ "$FREE_GIB" -lt 70 ];then
logger -t kibaos-lsw-autoinstall "only $FREE_GIB GB free (need ~70), skipping"
exit 0
fi
echo $((n+1)) >"$TRIES"
CORES="$(nproc 2>/dev/null||echo 4)"
VM_CPU=$((CORES/2))
[ "$VM_CPU" -lt 2 ]&&VM_CPU=2
[ "$VM_CPU" -gt 8 ]&&VM_CPU=8
MEM_MIB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
VM_MEM=$((${MEM_MIB:-8192}/2))
[ "$VM_MEM" -lt 4096 ]&&VM_MEM=4096
[ "$VM_MEM" -gt 16384 ]&&VM_MEM=16384
if [ ! -s "$PASSFILE" ];then
mkdir -p "$(dirname "$PASSFILE")"
(umask 077
tr -dc 'A-Za-z0-9' </dev/urandom|head -c 20 >"$PASSFILE")
fi
WIN_PASS="$(cat "$PASSFILE")"
note "Setting up Windows" "Installing in the background -- this can take 15-35 minutes. You can keep using your PC."
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"
nice -n 10 ionice -c3 lsw-manager \
--accept-license \
--edition "Windows 11" --language "English" \
--user "KibaUser" --password "$WIN_PASS" \
--cpu "$VM_CPU" --memory "$VM_MEM" --disk 64 >> \
"$LOG" 2>&1
rc=$?
if [ "$rc" -eq 0 ];then
touch "$DONE"
note "Windows is ready" "Your Windows apps are available from the app menu."
else
note "Windows setup hit a snag" "It will retry next time you log in. Details: $LOG"
fi
exit "$rc"
LSWAUTO
chmod +x /usr/local/bin/kibaos-lsw-autoinstall
mkdir -p /etc/skel/.config/autostart
cat >/etc/skel/.config/autostart/kibaos-lsw-autoinstall.desktop <<'LSWAUTODESK'
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
if flatpak install --system --noninteractive flathub io.github.alainm23.planify;then
echo "=== Planify: installed via flatpak (io.github.alainm23.planify) ==="
else
echo "!! Planify flatpak install failed -- continuing without it" >&2
fi
ADWAITA_ICONS="/usr/share/icons/Adwaita"
LAUNCHER_MASTER="/tmp/kibaos-launcher-icon.png"
if [ -f "$LOGO_256" ];then
cp "$LOGO_256" "$LAUNCHER_MASTER"
else
magick -size 512x512 xc:none \
-fill black -draw "circle 256,256 256,16" \
-stroke white -strokewidth 20 -fill none -draw "circle 256,256 256,60" \
"$LAUNCHER_MASTER"
fi
if [ -d "$ADWAITA_ICONS" ];then
find "$ADWAITA_ICONS" -path '*/places/start-here-symbolic.svg' -print0 2>/dev/null|while IFS= read -r -d '' _svg;do
_dir=$(dirname "$_svg")
_size=$(basename "$(dirname "$_dir")")
_px="${_size%%x*}"
case "$_px" in
''|*[!0-9]*)_px=256
esac
magick "$LAUNCHER_MASTER" -filter Lanczos -resize "${_px}x$_px" \
"$_dir/start-here-symbolic.png"
rm -f "$_svg"
done
gtk-update-icon-cache -f "$ADWAITA_ICONS" 2>/dev/null||true
fi
rm -f "$LAUNCHER_MASTER"
echo "=== Taskbar launcher icon: KibaOS boot-logo badge installed ==="
mkdir -p /usr/share/themes/KibaOS/gtk-3.0
mkdir -p /usr/share/themes/KibaOS/gtk-4.0
mkdir -p /etc/gtk-3.0
cat >/etc/gtk-3.0/settings.ini <<'GTK3RC'
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
cat >/etc/gtk-4.0/settings.ini <<'GTK4RC'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Cutefish
GTK4RC
mkdir -p /usr/share/Kvantum/KibaOS/config
mkdir -p /usr/share/Kvantum/KibaOS/Translations
chmod -R 755 /usr/share/Kvantum/KibaOS
echo "[General]
Theme=KibaOS" >/etc/xdg/kvantum.kvconfig
cat >/etc/gtk-3.0/gtk.css <<'GTK3PANEL'
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
cat >/etc/gtk-4.0/gtk.css <<'GTK4CSS'
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
glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null||true
mkdir -p /etc/greetd
: <<'DEAD_SDDM_THEME_BLOCK'
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
SKEL="/etc/skel"
mkdir -p "$SKEL/.config/autostart"
cat >/usr/local/bin/kibaos-greetd-config <<'GREETDCFGSCRIPT'
#!/bin/bash
set -e
_user="${1:-}"
mkdir -p /etc/greetd
_tmp="$(mktemp /etc/greetd/.aurade.toml.XXXXXX)"
{
printf '[terminal]\nvt = 1\n\n'
printf '[default_session]\n'
printf 'command = "/usr/lib/aurade-greeter/aurade-greeter-session"\n'
printf 'user = "greeter"\n'
if [ -n "$_user" ];then
_cmd=/usr/bin/aurade-session-supervisor
printf '\n[initial_session]\ncommand = "%s"\nuser = "%s"\n' "$_cmd" "$_user"
fi
} >"$_tmp"
chmod 644 "$_tmp"
mv -f "$_tmp" /etc/greetd/aurade.toml
GREETDCFGSCRIPT
chmod 755 /usr/local/bin/kibaos-greetd-config
/usr/local/bin/kibaos-greetd-config
mkdir -p /var/lib/AccountsService/users
cat >/var/lib/AccountsService/users/liveuser <<'LIVEUSERACCOUNTS'
[User]
Session=aurade
XSession=aurade
SystemAccount=false
LIVEUSERACCOUNTS
chmod 600 /var/lib/AccountsService/users/liveuser
chown root:root /var/lib/AccountsService/users/liveuser
grep -qx '/bin/bash' /etc/shells||echo '/bin/bash' >>/etc/shells
if [ -f /etc/pam.d/greetd ]&&[ -e /usr/lib/security/pam_gnome_keyring.so ]&&! grep -q pam_gnome_keyring /etc/pam.d/greetd;then
echo 'auth       optional     pam_gnome_keyring.so' >>/etc/pam.d/greetd
echo 'session    optional     pam_gnome_keyring.so auto_start' >>/etc/pam.d/greetd
fi
passwd -u liveuser 2>/dev/null||true
chage -I -1 -m 0 -M 99999 -E -1 liveuser 2>/dev/null||true
cat >/usr/local/bin/kibaos-live-autologin <<'LIVEAUTOLOGIN'
#!/bin/bash
[ -d /run/archiso ]||exit 0
id liveuser >/dev/null 2>&1||exit 0
if ! grep -qs '^user = "liveuser"' /etc/greetd/aurade.toml;then
/usr/local/bin/kibaos-greetd-config liveuser
logger -t kibaos-live-autologin "greetd config was missing autologin; rewrote it"
fi
rm -f /run/greetd.run
mkdir -p /var/lib/AccountsService/users
if ! grep -qs '^Session=aurade' /var/lib/AccountsService/users/liveuser;then
printf '[User]\nSession=aurade\nXSession=aurade\nSystemAccount=false\n' >/var/lib/AccountsService/users/liveuser
chmod 600 /var/lib/AccountsService/users/liveuser
fi
passwd -u liveuser >/dev/null 2>&1||true
exit 0
LIVEAUTOLOGIN
chmod +x /usr/local/bin/kibaos-live-autologin
cat >/etc/systemd/system/kibaos-live-autologin.service <<'LIVEAUTOLOGINSVC'
[Unit]
Description=Ensure greetd autologin for the KibaOS live user
Before=aurade-greetd.service display-manager.service
After=local-fs.target systemd-sysusers.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-live-autologin

[Install]
WantedBy=graphical.target
LIVEAUTOLOGINSVC
systemctl enable kibaos-live-autologin.service
cat >/usr/local/bin/kibaos-wait-drm <<'WAITDRM'
#!/bin/bash
for _ in $(seq 1 40);do
for c in /sys/class/drm/card[0-9]*;do
[ -e "$c/device/driver" ]||continue
drv="$(basename "$(readlink -f "$c/device/driver")")"
case "$drv" in
simpledrm|simple-framebuffer|simplefb|efifb|vesafb);;
*)exit 0
esac
done
sleep 0.5
done
logger -t kibaos-wait-drm "no non-simpledrm GPU driver after 20s, starting greetd anyway"
exit 0
WAITDRM
chmod +x /usr/local/bin/kibaos-wait-drm
mkdir -p /etc/systemd/system/aurade-greetd.service.d
cat >/etc/systemd/system/aurade-greetd.service.d/10-kibaos-wait-drm.conf <<'GDMWAITDRM'
[Service]
ExecStartPre=/usr/local/bin/kibaos-wait-drm
TimeoutStartSec=90
GDMWAITDRM
cat >/usr/local/bin/kibaos-gpu-select <<'GPUSELECT'
#!/bin/bash
for d in /sys/bus/pci/devices/*;do
[ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ]||continue
case "$(cat "$d/class" 2>/dev/null)" in 0x0300*|0x0302*);;*)continue;esac
id=$(($(cat "$d/device")))
if [ "$id" -lt $((0x1e00)) ];then
logger -t kibaos-gpu-select "pre-Turing NVIDIA GPU $(cat "$d/device"): using nouveau"
modprobe nouveau||true
exit 0
fi
done
exit 0
GPUSELECT
chmod +x /usr/local/bin/kibaos-gpu-select
cat >/etc/systemd/system/kibaos-gpu-select.service <<'GPUSELECTSVC'
[Unit]
Description=Use nouveau for NVIDIA GPUs the open kernel modules do not support
After=systemd-udev-trigger.service
Before=aurade-greetd.service display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kibaos-gpu-select

[Install]
WantedBy=graphical.target
GPUSELECTSVC
systemctl enable kibaos-gpu-select.service
for _f in /usr/share/wayland-sessions/aurade.desktop /usr/bin/aurade-session-supervisor /usr/lib/systemd/system/aurade-greetd.service /usr/lib/aurade-greeter/aurade-greeter-session /usr/bin/aurade-greeter /usr/bin/weston;do
[ -e "$_f" ]||{
echo "ERROR: autologin prerequisite missing: $_f" >&2
exit 1
}
done
id greeter >/dev/null 2>&1||echo "WARNING: greeter user missing at build time (created by sysusers at boot)" >&2
if [ ! -f /etc/pam.d/greetd ];then
printf '#%PAM-1.0\nauth       required     pam_securetty.so\nauth       requisite    pam_nologin.so\nauth       include      system-local-login\naccount    include      system-local-login\nsession    include      system-local-login\n' >/etc/pam.d/greetd
fi
mkdir -p /var/lib/aurade-greeter /var/cache/aurade-greeter
chown greeter:greeter /var/lib/aurade-greeter /var/cache/aurade-greeter 2>/dev/null||true
cat >/usr/local/bin/kibaos-screenshot <<'SCREENSHOT'
#!/bin/bash
set -euo pipefail
OUT_DIR="$HOME/Pictures/Screenshots"
mkdir -p "$OUT_DIR"
FILE="$OUT_DIR/Screenshot from $(date '+%Y-%m-%d %H-%M-%S').png"
if [ "${1:-}" = "region" ];then
GEOM=$(slurp)||exit 0
grim -g "$GEOM" "$FILE"
else
grim "$FILE"
fi
wl-copy <"$FILE"
notify-send -i "$FILE" "Screenshot saved" "Copied to clipboard · $(basename "$FILE")"
SCREENSHOT
chmod +x /usr/local/bin/kibaos-screenshot
cat >/usr/local/bin/kibaos-screenshot-ocr <<'SCREENSHOTOCR'
#!/bin/bash
set -euo pipefail
GEOM=$(slurp)||exit 0
TMP=$(mktemp --suffix=.png -t kibaos-ocr.XXXXXX)
trap 'rm -f "$TMP"' EXIT
grim -g "$GEOM" "$TMP"
TEXT=$(tesseract "$TMP" - 2>/dev/null|sed -e '$ { /^$/d }')
if [ -z "$TEXT" ];then
notify-send "Screenshot OCR" "No text found in that selection."
exit 0
fi
printf '%s' "$TEXT"|wl-copy
PREVIEW=$(printf '%s' "$TEXT"|head -c 120)
notify-send "Text copied to clipboard" "$PREVIEW$([ ${#TEXT} -gt 120 ]&&echo …)"
SCREENSHOTOCR
chmod +x /usr/local/bin/kibaos-screenshot-ocr
cat >/usr/local/bin/kibaos-apply-output-scale <<'OUTPUTSCALE'
#!/bin/bash
for _ in 1 2 3 4 5;do
wlr-randr >/tmp/.kiba-outputs 2>/dev/null&&[ -s /tmp/.kiba-outputs ]&&break
sleep 1
done
[ -s /tmp/.kiba-outputs ]||exit 0
current_name=""
current_w=""
current_h=""
current_mm_w=""
current_mm_h=""
apply_scale(){
[ -n "$current_name" ]||return
scale=1
if [ -n "$current_mm_w" ]&&[ "$current_mm_w" -gt 0 ] 2>/dev/null;then
dpi=$((current_w*254/(current_mm_w * 10)))
if [ "$dpi" -ge 168 ];then
scale=2
fi
elif [ -n "$current_w" ]&&[ "$current_w" -ge 3000 ] 2>/dev/null;then
scale=2
fi
wlr-randr --output "$current_name" --scale "$scale" >/dev/null 2>&1
}
while IFS= read -r line;do
case "$line" in
[A-Za-z]*)apply_scale
current_name=$(printf '%s' "$line"|awk '{print $1}')
current_w=""
current_h=""
current_mm_w=""
current_mm_h=""
;;
*"Physical size:"*)dims=$(printf '%s' "$line"|grep -oE '[0-9]+x[0-9]+')
current_mm_w=${dims%x*}
current_mm_h=${dims#*x}
;;
*"current"*)dims=$(printf '%s' "$line"|grep -oE '^[[:space:]]*[0-9]+x[0-9]+'|tr -d ' ')
current_w=${dims%x*}
current_h=${dims#*x}
esac
done </tmp/.kiba-outputs
apply_scale
rm -f /tmp/.kiba-outputs
OUTPUTSCALE
chmod +x /usr/local/bin/kibaos-apply-output-scale
OTA_PUBKEY_URL="https://raw.githubusercontent.com/WolfTech-Innovations/Kiba/main/ota/ota-public.asc"
OTA_BASE="https://sourceforge.net/projects/kibaos/files/ota"
OTA_KEYRING="/etc/kibaos/ota-keyring.gpg"
mkdir -p /etc/kibaos /var/lib/kibaos-ota /var/log/kibaos
curl -fsSL --retry 3 "$OTA_PUBKEY_URL" -o /tmp/ota-public.asc 2>/dev/null&&gpg --no-default-keyring --keyring "$OTA_KEYRING" \
--import /tmp/ota-public.asc 2>/dev/null||true
rm -f /tmp/ota-public.asc
echo "0" >/etc/kibaos/patch-level
cat >/usr/local/bin/kibaos-ota <<'OTASCRIPT'
#!/usr/bin/env bash
set -euo pipefail
OTA_BASE="https://sourceforge.net/projects/kibaos/files/ota"
OTA_KEYRING="/etc/kibaos/ota-keyring.gpg"
PATCH_LEVEL_FILE="/etc/kibaos/patch-level"
OTA_WORKDIR="/var/lib/kibaos-ota"
OTA_LOG="/var/log/kibaos/ota.log"
FREEZE_PID_FILE="/tmp/kibaos-fb-freeze.pid"
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$OTA_LOG";}
fb_freeze(){
log "Freezing display with framebuffer snapshot..."
SNAP="/tmp/kibaos-ota-snap.png"
SNAP_RAW="/tmp/kibaos-ota-snap.raw"
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
XDG_RUNTIME_DIR="/run/user/1000"
runuser -u liveuser -- env \
WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
grim "$SNAP" 2>/dev/null||true
if [ -f "$SNAP" ];then
FB_WIDTH=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null|cut -d',' -f1||echo 1920)
FB_HEIGHT=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null|cut -d',' -f2||echo 1080)
magick "$SNAP" -resize "${FB_WIDTH}x$FB_HEIGHT!" \
-depth 8 bgr:"$SNAP_RAW" 2>/dev/null||true
if [ -f "$SNAP_RAW" ]&&[ -w /dev/fb0 ];then
cat "$SNAP_RAW" >/dev/fb0 2>/dev/null||true
fi
fi
python3 - <<'UINPUT_WIGGLE'&
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
echo $! >"$FREEZE_PID_FILE"
log "Framebuffer freeze active (PID $(cat $FREEZE_PID_FILE))."
}
fb_unfreeze(){
if [ -f "$FREEZE_PID_FILE" ];then
kill "$(cat $FREEZE_PID_FILE)" 2>/dev/null||true
rm -f "$FREEZE_PID_FILE"
fi
rm -f /tmp/kibaos-ota-snap.png /tmp/kibaos-ota-snap.raw
log "Framebuffer freeze released."
}
apply_patch(){
log "Applying patch $LATEST..."
ROLLBACK_DIR="$OTA_WORKDIR/rollback-$CURRENT"
mkdir -p "$ROLLBACK_DIR"
while IFS= read -r line;do
FILEPATH=$(echo "$line"|awk '{print $2}'|sed 's|^\./||')
SRC="$EXTRACT_DIR/$FILEPATH"
DST="/$FILEPATH"
[ -f "$SRC" ]||continue
if [ -f "$DST" ];then
BACKUP_PATH="$ROLLBACK_DIR/$FILEPATH"
mkdir -p "$(dirname $BACKUP_PATH)"
cp -a "$DST" "$BACKUP_PATH"
fi
mkdir -p "$(dirname $DST)"
cp -a "$SRC" "$DST.ota-tmp"
mv "$DST.ota-tmp" "$DST"
log "  Patched: $DST"
done <"$MANIFEST"
log "Patch applied."
}
rollback_patch(){
ROLLBACK_DIR="$OTA_WORKDIR/rollback-$CURRENT"
log "ROLLING BACK to patch level $CURRENT..."
if [ -d "$ROLLBACK_DIR" ];then
find "$ROLLBACK_DIR" -type f|while read -r BACKUP;do
FILEPATH="${BACKUP#$ROLLBACK_DIR/}"
DST="/$FILEPATH"
mkdir -p "$(dirname $DST)"
cp -a "$BACKUP" "$DST"
done
log "Rollback complete."
else
log "No rollback data found. Cannot roll back."
fi
}
restart_compositor(){
log "Restarting session..."
{
[ -d /run/archiso ]&&rm -f /run/greetd.run
systemctl restart aurade-greetd 2>/dev/null
}||pkill -TERM weston 2>/dev/null||true
sleep 1
log "Session restarted."
}
restart_display_manager(){
log "Restarting greetd..."
[ -d /run/archiso ]&&rm -f /run/greetd.run
systemctl restart aurade-greetd
for i in $(seq 1 20);do
[ -S "/run/user/1000/${WAYLAND_DISPLAY:-wayland-0}" ]&&break
sleep 0.5
done
log "greetd restarted."
}
run_post_hooks(){
log "Running post-patch hooks..."
grep -q 'usr/share/icons' "$MANIFEST"&&gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null||true
grep -q 'usr/share/glib-2.0/schemas' "$MANIFEST"&&glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null||true
grep -q 'usr/share/mime' "$MANIFEST"&&update-mime-database /usr/share/mime 2>/dev/null||true
grep -q 'usr/lib/systemd' "$MANIFEST"&&systemctl daemon-reload 2>/dev/null||true
log "Post-patch hooks complete."
}
if [ "${1:-}" = "rollback" ];then
shift||true
REASON="cli:unspecified"
while [ $# -gt 0 ];do
case "${1:-}" in
--reason)REASON="${2:-$REASON}"
shift 2||break
;;
*)shift
esac
done
CURRENT=$(cat "$PATCH_LEVEL_FILE" 2>/dev/null||echo 0)
log "Manual rollback requested (reason: $REASON)"
if [ -d "$OTA_WORKDIR/rollback-$CURRENT" ];then
fb_freeze
rollback_patch
restart_compositor
restart_display_manager
fb_unfreeze
log "Manual rollback finished."
exit 0
else
log "No rollback data available for patch level $CURRENT. Nothing to roll back."
exit 1
fi
fi
CURRENT=$(cat "$PATCH_LEVEL_FILE" 2>/dev/null||echo 0)
log "Current patch level: $CURRENT"
LATEST=$(curl -fsSL --retry 3 --max-time 10 \
"$OTA_BASE/latest-patch-level" 2>/dev/null|tr -d '[:space:]')||{
log "Could not reach OTA server. Skipping."
exit 0
}
if ! [[ $LATEST =~ ^[0-9]+$ ]];then
log "Invalid patch level received: '$LATEST'. Skipping."
exit 0
fi
if [ "$LATEST" -le "$CURRENT" ];then
log "Already up to date (patch level $CURRENT)."
exit 0
fi
log "New patch available: $CURRENT → $LATEST"
DEV_ARCH="$(uname -m)"
PATCH_TAR="$OTA_WORKDIR/kibaos-ota-$LATEST-$DEV_ARCH.tar.gz"
PATCH_SIG="$PATCH_TAR.asc"
MANIFEST="$OTA_WORKDIR/manifest-$LATEST-$DEV_ARCH.txt"
mkdir -p "$OTA_WORKDIR"
log "Downloading patch $LATEST ($DEV_ARCH)..."
curl -fsSL --retry 3 --max-time 120 \
"$OTA_BASE/kibaos-ota-$LATEST-$DEV_ARCH.tar.gz" -o "$PATCH_TAR"||{
log "Download failed. Skipping."
exit 0
}
curl -fsSL --retry 3 --max-time 30 \
"$OTA_BASE/kibaos-ota-$LATEST-$DEV_ARCH.tar.gz.asc" -o "$PATCH_SIG"||{
log "Signature download failed. Aborting for safety."
rm -f "$PATCH_TAR"
exit 1
}
curl -fsSL --retry 3 --max-time 30 \
"$OTA_BASE/kibaos-ota-$LATEST-$DEV_ARCH-manifest.txt" -o "$MANIFEST"||{
log "Manifest download failed. Aborting."
rm -f "$PATCH_TAR" "$PATCH_SIG"
exit 1
}
log "Verifying signature..."
if ! gpg --no-default-keyring --keyring "$OTA_KEYRING" \
--verify "$PATCH_SIG" "$PATCH_TAR" 2>/dev/null;then
log "SIGNATURE VERIFICATION FAILED. Patch rejected. Possible tampering."
rm -f "$PATCH_TAR" "$PATCH_SIG" "$MANIFEST"
exit 1
fi
log "Signature verified."
log "Verifying checksums..."
EXTRACT_DIR="$OTA_WORKDIR/patch-$LATEST"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar xzf "$PATCH_TAR" -C "$EXTRACT_DIR"
while IFS= read -r line;do
EXPECTED_HASH=$(echo "$line"|awk '{print $1}')
FILEPATH=$(echo "$line"|awk '{print $2}'|sed 's|^\./||')
ACTUAL_HASH=$(sha256sum "$EXTRACT_DIR/$FILEPATH" 2>/dev/null|awk '{print $1}')
if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ];then
log "CHECKSUM MISMATCH for $FILEPATH. Aborting."
rm -rf "$EXTRACT_DIR" "$PATCH_TAR" "$PATCH_SIG" "$MANIFEST"
exit 1
fi
done <"$MANIFEST"
log "All checksums verified."
NEEDS_DISPLAY_RESTART=false
NEEDS_COMPOSITOR_RESTART=false
while IFS= read -r line;do
FILEPATH=$(echo "$line"|awk '{print $2}'|sed 's|^\./||')
case "$FILEPATH" in
etc/greetd*|usr/bin/greetd*|usr/bin/aurade-greeter*|usr/lib/aurade-greeter*)NEEDS_DISPLAY_RESTART=true
;;
usr/bin/weston*)NEEDS_COMPOSITOR_RESTART=true
esac
done <"$MANIFEST"
_active_user_info(){
loginctl list-sessions --no-legend 2>/dev/null|while read -r _sid _uid _user _rest;do
[ "$_user" = "greeter" ]&&continue
[ "$(loginctl show-session "$_sid" -p Class --value 2>/dev/null)" = "user" ]||continue
[ "$(loginctl show-session "$_sid" -p Active --value 2>/dev/null)" = "yes" ]||continue
echo "$_uid $_user"
break
done||true
}
as_desktop_user(){
local uid="" user="" sock=""
read -r uid user <<<"$(_active_user_info)"||true
[ -n "$uid" ]||return 1
sock=$(ls "/run/user/$uid"/wayland-* 2>/dev/null|grep -v '\.lock$'|head -n1||true)
runuser -u "$user" -- env \
XDG_RUNTIME_DIR="/run/user/$uid" \
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
WAYLAND_DISPLAY="$(basename "${sock:-wayland-0}")" \
GDK_BACKEND=wayland \
"$@"
}
ui_updating(){
as_desktop_user zenity --info --no-wrap --timeout=20 \
--title="KibaOS is updating" \
--text=$'<b>KibaOS is installing a small update.</b>\n\nYou can keep working \xe2\x80\x94 this won\'t interrupt anything.\nWe\'ll only ask you to restart if it\'s really needed.' > \
/dev/null 2>&1&
return 0
}
ui_notify(){
as_desktop_user notify-send -a "KibaOS" -i software-update-available "$1" "$2" >/dev/null 2>&1||true
}
ui_ask_restart(){
as_desktop_user zenity --question --no-wrap --timeout=300 \
--title="One quick restart needed" \
--ok-label="Restart now" --cancel-label="Later" \
--text=$'<b>This update needs the screen to restart to finish.</b>\n\nIt only takes a few seconds, but open apps will close,\nso please save your work first.\n\nChoose \xe2\x80\x9cLater\xe2\x80\x9d and nothing changes \xe2\x80\x94 the update will\nfinish by itself the next time you sign in.' > \
/dev/null 2>&1
}
do_session_restart(){
fb_freeze
if $NEEDS_COMPOSITOR_RESTART;then
restart_compositor
fi
if $NEEDS_DISPLAY_RESTART;then
restart_display_manager
fi
fb_unfreeze
}
ui_updating||true
if ! apply_patch;then
log "Patch application failed. Initiating rollback."
rollback_patch
fb_unfreeze
ui_notify "KibaOS update couldn't be installed" "Nothing was changed — your system is exactly as it was. We'll try again later."
exit 1
fi
if ! run_post_hooks;then
log "Post-patch hooks failed. Initiating rollback."
rollback_patch
fb_unfreeze
ui_notify "KibaOS update couldn't be installed" "Nothing was changed — your system is exactly as it was. We'll try again later."
exit 1
fi
echo "$LATEST" >"$PATCH_LEVEL_FILE"
if $NEEDS_DISPLAY_RESTART||$NEEDS_COMPOSITOR_RESTART;then
if [ -n "$(_active_user_info)" ];then
if ui_ask_restart;then
log "User chose to restart now."
do_session_restart
else
log "User chose Later (or didn't answer) -- deferring session restart."
mkdir -p "$OTA_WORKDIR"
touch "$OTA_WORKDIR/restart-deferred"
ui_notify "KibaOS update installed" "It'll finish by itself the next time you sign in. Nothing else to do."
fi
else
log "Nobody is signed in -- restarting the session now."
do_session_restart
fi
else
ui_notify "KibaOS is up to date" "The update finished. Nothing else to do."
fi
log "Successfully updated to patch level $LATEST."
rm -rf "$EXTRACT_DIR" "$PATCH_TAR" "$PATCH_SIG" "$MANIFEST"
log "Done."
OTASCRIPT
chmod +x /usr/local/bin/kibaos-ota
cat >/etc/systemd/system/kibaos-ota.service <<'OTASVC'
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
cat >/etc/systemd/system/kibaos-ota.timer <<'OTATIMER'
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
cat >/usr/local/bin/kibaos-firstboot-groups <<'FIRSTBOOTGROUPS'
#!/usr/bin/env bash
set -euo pipefail
MARKER="/etc/kibaos/pending-user-groups"
[ -f "$MARKER" ]||exit 0
while IFS=: read -r username groups;do
[ -n "$username" ]||continue
IFS=',' read -ra group_arr <<<"$groups"
add_groups=()
for g in "${group_arr[@]}";do
if getent group "$g" >/dev/null 2>&1;then
add_groups+=("$g")
else
echo "kibaos-firstboot-groups: '$g' still doesn't exist, leaving pending" >&2
fi
done
if [ "${#add_groups[@]}" -gt 0 ];then
joined=$(IFS=,
echo "${add_groups[*]}")
usermod -aG "$joined" "$username"&&echo "kibaos-firstboot-groups: added $username to $joined"||echo "kibaos-firstboot-groups: usermod failed for $username" >&2
fi
done <"$MARKER"
if ! grep -qE ':.*[a-zA-Z]' "$MARKER" 2>/dev/null||! awk -F: '{print $2}' "$MARKER"|tr ',' '\n'|while read -r g;do
[ -n "$g" ]&&! getent group "$g" >/dev/null 2>&1&&exit 1
done;then
:
else
rm -f "$MARKER"
fi
FIRSTBOOTGROUPS
chmod +x /usr/local/bin/kibaos-firstboot-groups
cat >/etc/systemd/system/kibaos-firstboot-groups.service <<'FIRSTBOOTSVC'
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
"$SKEL/.config/gtk-3.0" \
"$SKEL/.config/gtk-4.0" \
"$SKEL/.config/autostart" \
"$SKEL/.config/fastfetch"
cat >/usr/local/bin/kibaos-desktop-icons <<'DESKTOPICONSWRAP'
#!/bin/sh
pcmanfm-qt --desktop&
PID=$!
sleep 2
pcmanfm-qt --wallpaper-mode=stretch -w /usr/share/kibaos/wallpaper.jpg
wait "$PID"
DESKTOPICONSWRAP
chmod +x /usr/local/bin/kibaos-desktop-icons
cat >"$SKEL/.config/autostart/pcmanfm-qt-desktop.desktop" <<'DESKTOPVIEW'
[Desktop Entry]
Type=Application
Name=PCManFM-Qt Desktop
Exec=/usr/local/bin/kibaos-desktop-icons
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-AutoRestart=true
DESKTOPVIEW
cat >"$SKEL/.config/gtk-3.0/settings.ini" <<'GTK3SKEL'
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
cp /etc/gtk-3.0/gtk.css "$SKEL/.config/gtk-3.0/gtk.css"
cp /etc/gtk-4.0/gtk.css "$SKEL/.config/gtk-4.0/gtk.css"
glib-compile-schemas /usr/share/glib-2.0/schemas/
cat >/usr/local/bin/kibaos-first-login <<'FIRSTLOGIN'
#!/usr/bin/env bash
STAMP="$HOME/.config/.kibaos-configured"
[ -f "$STAMP" ]&&exit 0
gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
gsettings set org.gnome.desktop.interface icon-theme 'Cutefish'
gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita'
gsettings set org.gnome.desktop.interface cursor-size 24
gsettings set org.gnome.desktop.interface font-name 'Nunito 11'
gsettings set org.gnome.desktop.interface document-font-name 'Nunito 11'
gsettings set org.gnome.desktop.interface monospace-font-name 'Noto Sans Mono 11'
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.interface enable-animations true
gsettings set org.gnome.desktop.interface text-scaling-factor 1.0
gsettings set org.gnome.desktop.background picture-uri 'file:///usr/share/kibaos/wallpaper.jpg'
gsettings set org.gnome.desktop.background picture-uri-dark 'file:///usr/share/kibaos/wallpaper.jpg'
gsettings set org.gnome.desktop.background picture-options 'zoom'
gsettings set org.gnome.desktop.background primary-color '#0d1b2a'
gsettings set org.gnome.desktop.wm.preferences button-layout 'close,minimize,maximize:'
gsettings set org.gnome.desktop.wm.preferences titlebar-font 'Nunito SemiBold 10'
gsettings set org.gnome.desktop.wm.preferences action-double-click-titlebar 'toggle-maximize'
gsettings set org.gnome.desktop.wm.preferences num-workspaces 4
gsettings set org.gnome.desktop.wm.preferences focus-mode 'click'
gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
gsettings set org.gnome.desktop.peripherals.touchpad natural-scroll true
gsettings set org.gnome.desktop.peripherals.touchpad two-finger-scrolling-enabled true
gsettings set org.gnome.desktop.peripherals.mouse natural-scroll false
gsettings set org.gnome.desktop.peripherals.mouse accel-profile 'adaptive'
gsettings set org.nemo.preferences show-hidden-files false
gsettings set org.nemo.preferences default-folder-viewer 'icon-view'
gsettings set org.nemo.icon-view default-zoom-level 'standard'
gsettings set org.nemo.preferences show-location-entry false
touch "$STAMP"
FIRSTLOGIN
chmod +x /usr/local/bin/kibaos-first-login
cat >"$SKEL/.config/autostart/kibaos-configure.desktop" <<'AUTOCFG'
[Desktop Entry]
Type=Application
Name=KibaOS First Login Setup
Exec=/usr/local/bin/kibaos-first-login
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTOCFG
cat >"$SKEL/.config/autostart/kibaos-oem-finish.desktop" <<'OEMAUTOCFG'
[Desktop Entry]
Type=Application
Name=Finish Setting Up KibaOS
Exec=sh -c 'test -f /etc/kibaos/oem-pending && exec /usr/bin/io.kibaos.oobe'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
OEMAUTOCFG
cat >"$SKEL/.config/autostart/kibaos-install-launch.desktop" <<'LIVELAUNCH'
[Desktop Entry]
Type=Application
Name=KibaOS Installer
Exec=sh -c '[ "$(whoami)" = "liveuser" ] && exec /usr/bin/io.kibaos.oobe'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
LIVELAUNCH
mkdir -p /etc/systemd/zram-generator.conf.d
cat >/etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM
mkdir -p "$SKEL/.config"
mkdir -p "$SKEL/.config/fontconfig"
cat >"$SKEL/.config/fontconfig/fonts.conf" <<'FONTCONF'
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
cat >"$SKEL/.config/electron-flags.conf" <<'ELECTRONFLAGS'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
--enable-wayland-ime
ELECTRONFLAGS
cat >"$SKEL/.config/chrome-flags.conf" <<'CHROMEFLAGS'
--enable-features=UseOzonePlatform
--ozone-platform=wayland
CHROMEFLAGS
cat >"$SKEL/.config/autostart/polkit-agent.desktop" <<'POLKIT'
[Desktop Entry]
Type=Application
Name=Polkit Authentication Agent
Exec=/usr/lib/polkit-kde-authentication-agent-1
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
POLKIT
cat >"$SKEL/.bashrc" <<'BASHRC'
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
mkdir -p "$SKEL/.config/fastfetch"
cat >"$SKEL/.config/fastfetch/config.jsonc" <<'FFCONF'
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
cat >"$SKEL/.config/autostart/lost-island.desktop" <<'LIAUTO'
[Desktop Entry]
Type=Application
Name=Lost Island
Exec=lost-island
TryExec=lost-island
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
NoDisplay=true
LIAUTO
cp -aT "$SKEL/" /home/liveuser/
chown -R 1000:1000 /home/liveuser
chmod 750 /home/liveuser
mkdir -p /usr/local/bin
mkdir -p /usr/share/kibaos-welcome
(set -e
JOPLIN_TAG=$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/laurent22/joplin/releases/latest)
JOPLIN_TAG="${JOPLIN_TAG##*/}"
JOPLIN_URL="https://github.com/laurent22/joplin/releases/download/$JOPLIN_TAG/Joplin-${JOPLIN_TAG#v}.AppImage"
[ -n "$JOPLIN_URL" ]
JOPLIN_TMP="/tmp/joplin-appimage"
rm -rf "$JOPLIN_TMP"&&mkdir -p "$JOPLIN_TMP"&&cd "$JOPLIN_TMP"
curl -fL --retry 3 -o Joplin.AppImage "$JOPLIN_URL"
chmod +x Joplin.AppImage
./Joplin.AppImage --appimage-extract >/dev/null
rm -rf /opt/joplin&&mv squashfs-root /opt/joplin
chmod -R a+rX /opt/joplin
for _sz in 512 256 128 64 48;do
_ic="/opt/joplin/usr/share/icons/hicolor/${_sz}x$_sz/apps/joplin.png"
[ -f "$_ic" ]&&install -Dm644 "$_ic" "/usr/share/icons/hicolor/${_sz}x$_sz/apps/joplin.png"
done
cat >/usr/bin/joplin-desktop <<'JOPLINLAUNCH'
#!/bin/sh
exec /opt/joplin/AppRun --no-sandbox "$@"
JOPLINLAUNCH
chmod 755 /usr/bin/joplin-desktop
cat >/usr/share/applications/joplin.desktop <<'JOPLINDESKTOP'
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
rm -rf "$JOPLIN_TMP")&&echo "=== Joplin installed ==="||echo "!! Joplin install failed -- continuing without it" >&2
sed -i 's/GTK_THEME=Adwaita-dark/GTK_THEME=KibaOS/' /etc/environment
mkdir -p /usr/share/applications /etc/skel/Desktop /etc/skel/Documents \
/etc/skel/Downloads /etc/skel/Pictures /etc/skel/Music /etc/skel/Videos
cat >/etc/skel/.config/user-dirs.dirs <<'USERDIRS'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_MUSIC_DIR="$HOME/Music"
XDG_VIDEOS_DIR="$HOME/Videos"
USERDIRS
cat >/usr/local/bin/kibaos-files <<'FILESWRAP'
#!/bin/bash
exec nemo "$HOME"
FILESWRAP
chmod +x /usr/local/bin/kibaos-files
cat >/usr/share/applications/kibaos-files.desktop <<'FILESDESK'
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
cat >/usr/local/bin/kibaos-first-login-setup <<'FIRSTLOGIN'
#!/bin/bash
MARKER="$HOME/.config/.kibaos-first-login-done"
[ -f "$MARKER" ]&&exit 0
mkdir -p "$HOME/.config/gtk-3.0"
cat >"$HOME/.config/gtk-3.0/bookmarks" <<BOOKMARKS
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
cat >/etc/skel/.config/autostart/kibaos-first-login-setup.desktop <<'FIRSTLOGINDESK'
[Desktop Entry]
Type=Application
Name=KibaOS First Login Setup
Exec=/usr/local/bin/kibaos-first-login-setup
NoDisplay=true
X-GNOME-Autostart-Phase=Initialization
FIRSTLOGINDESK
mkdir -p /usr/share/kibapkg
cat >/usr/share/kibapkg/kibapkg.py <<'KIBAPKG'
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
if [ -f /usr/bin/pacman ]&&[ ! -f /usr/lib/kibaos/pacman-real ];then
mv /usr/bin/pacman /usr/lib/kibaos/pacman-real
fi
cat >/usr/bin/pacman <<'PACMANSHIM'
#!/usr/bin/env bash
REAL=/usr/lib/kibaos/pacman-real
if [ -n "${KIBAOS_REAL_PACMAN:-}" ]||[ ! -t 1 ];then
exec "$REAL" "$@"
fi
rest=("$@")
rest=("${rest[@]:1}")
for a in "${rest[@]}";do
case "$a" in -*)exec "$REAL" "$@";esac
done
case "$1" in
-S|--sync)[ "${#rest[@]}" -ge 1 ]||exec "$REAL" "$@"
exec kiba install "${rest[@]}"
;;
-R|--remove)[ "${#rest[@]}" -ge 1 ]||exec "$REAL" "$@"
exec kiba remove "${rest[@]}"
;;
-Syu|-Syyu)[ "${#rest[@]}" -eq 0 ]||exec "$REAL" "$@"
exec kiba update
;;
-Ss|--search)[ "${#rest[@]}" -ge 1 ]||exec "$REAL" "$@"
exec kiba search "${rest[@]}"
;;
-Qi)[ "${#rest[@]}" -eq 1 ]||exec "$REAL" "$@"
exec kiba info "${rest[0]}"
;;
-Q|--query)[ "${#rest[@]}" -eq 0 ]||exec "$REAL" "$@"
exec kiba list
;;
*)exec "$REAL" "$@"
esac
PACMANSHIM
chmod +x /usr/bin/pacman
echo "=== pacman shim installed ==="
cat >/usr/share/applications/kibaos-install.desktop <<'INSTDESK'
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
cat >/usr/share/applications/kibaos-about.desktop <<'ABOUTDESK'
[Desktop Entry]
Name=About KibaOS
Comment=Learn more about KibaOS
Exec=xdg-open https://github.com/WolfTech-Innovations/Kiba
Icon=kibaos
Terminal=false
Type=Application
Categories=System;
ABOUTDESK
for _avahi_desk in avahi-discover bssh bvnc;do
if [ -f "/usr/share/applications/$_avahi_desk.desktop" ];then
cp "/usr/share/applications/$_avahi_desk.desktop" \
"/usr/share/applications/$_avahi_desk.desktop.bak" 2>/dev/null||true
printf '[Desktop Entry]\nNoDisplay=true\n' >> \
"/usr/share/applications/$_avahi_desk.desktop"
fi
done
if [ -f "/usr/share/applications/org.gnome.Terminal.desktop" ];then
sed -i 's/^NoDisplay=.*/NoDisplay=true/' \
"/usr/share/applications/org.gnome.Terminal.desktop"||true
grep -q '^NoDisplay=' "/usr/share/applications/org.gnome.Terminal.desktop"||echo 'NoDisplay=true' >>"/usr/share/applications/org.gnome.Terminal.desktop"
fi
for _bcc_desk in budgie-control-center.desktop \
org.buddiesofbudgie.BudgieControlCenter.desktop \
budgie-desktop-settings.desktop \
org.buddiesofbudgie.BudgieDesktopSettings.desktop;do
if [ -f "/usr/share/applications/$_bcc_desk" ];then
sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/$_bcc_desk"||true
grep -q '^NoDisplay=' "/usr/share/applications/$_bcc_desk"||echo 'NoDisplay=true' >>"/usr/share/applications/$_bcc_desk"
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
hwloc.desktop;do
if [ -f "/usr/share/applications/$_hidden_desk" ];then
sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/$_hidden_desk"||true
grep -q '^NoDisplay=' "/usr/share/applications/$_hidden_desk"||echo 'NoDisplay=true' >>"/usr/share/applications/$_hidden_desk"
fi
done
for _gcc_desk in gnome-control-center.desktop \
org.gnome.Settings.desktop;do
if [ -f "/usr/share/applications/$_gcc_desk" ];then
sed -i 's/^Name=.*/Name=Settings/' "/usr/share/applications/$_gcc_desk"||true
sed -i '/^Name\[/d' "/usr/share/applications/$_gcc_desk"||true
fi
done
for _panel_desk in gnome-multitasking-panel.desktop \
gnome-search-panel.desktop \
gnome-wwan-panel.desktop \
gnome-online-accounts-panel.desktop;do
if [ -f "/usr/share/applications/$_panel_desk" ];then
sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/$_panel_desk"||true
grep -q '^NoDisplay=' "/usr/share/applications/$_panel_desk"||echo 'NoDisplay=true' >>"/usr/share/applications/$_panel_desk"
fi
done
for _sw_desk in org.gnome.Software.desktop;do
if [ -f "/usr/share/applications/$_sw_desk" ];then
sed -i 's/^Name=.*/Name=App Store/' "/usr/share/applications/$_sw_desk"||true
sed -i '/^Name\[/d' "/usr/share/applications/$_sw_desk"||true
fi
done
if [ -f "/usr/share/applications/nm-connection-editor.desktop" ];then
sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/nm-connection-editor.desktop"||true
grep -q '^NoDisplay=' "/usr/share/applications/nm-connection-editor.desktop"||echo 'NoDisplay=true' >>"/usr/share/applications/nm-connection-editor.desktop"
fi
if [ -f "/usr/share/applications/cmake-gui.desktop" ];then
sed -i 's/^NoDisplay=.*/NoDisplay=true/' "/usr/share/applications/cmake-gui.desktop"||true
grep -q '^NoDisplay=' "/usr/share/applications/cmake-gui.desktop"||echo 'NoDisplay=true' >>"/usr/share/applications/cmake-gui.desktop"
fi
echo 'kernel.sysrq = 0' >/etc/sysctl.d/50-kibaos-disable-sysrq.conf
grep -q '^NAutoVTs' /etc/systemd/logind.conf&&sed -i 's/^NAutoVTs=.*/NAutoVTs=1/' /etc/systemd/logind.conf||echo 'NAutoVTs=1' >>/etc/systemd/logind.conf
systemctl mask getty@tty2.service getty@tty3.service getty@tty4.service \
getty@tty5.service getty@tty6.service
for _chromium_desk in chromium.desktop;do
if [ -f "/usr/share/applications/$_chromium_desk" ];then
sed -i 's/^Name=.*/Name=Browser/' "/usr/share/applications/$_chromium_desk"||true
sed -i '/^Name\[/d' "/usr/share/applications/$_chromium_desk"||true
sed -i 's/^Icon=.*/Icon=kibaos-browser/' "/usr/share/applications/$_chromium_desk"||true
fi
done
mkdir -p /home/liveuser/Desktop
for src_desktop in kibaos-install kibaos-about;do
cp "/usr/share/applications/$src_desktop.desktop" \
"/home/liveuser/Desktop/$src_desktop.desktop" 2>/dev/null||true
chmod +x "/home/liveuser/Desktop/$src_desktop.desktop" 2>/dev/null||true
done
cat >/etc/environment <<'ENV'
XDG_SESSION_TYPE=wayland
KWIN_FORCE_SW_CURSOR=1
MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
CLUTTER_BACKEND=wayland
SDL_VIDEODRIVER=wayland
KIBAOS_VERSION=rolling
KIBAOS_VENDOR="Kiba Labs, LLC"
ENV
cat >/etc/issue <<'ISSUE'

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
cat >/etc/motd <<'MOTD'
Welcome to KibaOS
MOTD
mkdir -p /etc/systemd/
cat >/etc/systemd/timesyncd.conf <<'TIMESYNCD'
[Time]
NTP=0.arch.pool.ntp.org 1.arch.pool.ntp.org 2.arch.pool.ntp.org 3.arch.pool.ntp.org
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org time.cloudflare.com time.google.com
RootDistanceMaxSec=5
PollIntervalMinSec=32
PollIntervalMaxSec=1024
TIMESYNCD
timedatectl set-local-rtc 0 2>/dev/null||true
systemctl enable systemd-timesyncd
systemctl enable aurade-greetd
systemctl enable NetworkManager
mkdir -p /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/dns.conf <<'NMDNS'
[main]
dns=none
NMDNS
cat >/usr/local/bin/kibaos-boot-dns <<'BOOTDNS'
#!/bin/bash
echo "nameserver 1.1.1.1" >/etc/resolv.conf
BOOTDNS
chmod +x /usr/local/bin/kibaos-boot-dns
cat >/etc/systemd/system/kibaos-boot-dns.service <<'BOOTDNSSVC'
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
cat >/usr/lib/kibaos/src/kiba_tcpmask.c <<'TCPMASKC'
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
$(pkg-config --libs libnetfilter_queue)||{
echo "FATAL: kiba_tcpmask.c failed to compile" >&2
exit 1
}
mkdir -p /etc/nftables-kiba
cat >/etc/nftables-kiba/tcpmask.conf <<'TCPMASKNFT'
table inet kiba_tcpmask {
  chain output {
    type filter hook output priority mangle; policy accept;
    tcp flags syn queue num 100 bypass
  }
}
TCPMASKNFT
cat >/etc/systemd/system/kiba-tcpmask.service <<'TCPMASKSVC'
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
echo "balanced" >/etc/tuned/active_profile
systemctl enable tuned
mkdir -p /var/lib/extensions /etc/extensions
systemctl enable systemd-sysext
systemctl enable fstrim.timer
cat >/etc/tmpfiles.d/kibaos.conf <<'TMPFILES'
e /tmp/kibaos-ocr.* - - - 1d
TMPFILES
systemctl enable systemd-tmpfiles-clean.timer
echo "=== Re-applying KibaOS boot animation ==="
KIBA_PLY_DIR="/usr/share/plymouth/themes/kibaos"
if [ -d /tmp/kiba-plymouth-snapshot ];then
rm -rf "$KIBA_PLY_DIR"
mkdir -p "$KIBA_PLY_DIR"
cp -a /tmp/kiba-plymouth-snapshot/. "$KIBA_PLY_DIR/"
fi
for _f in kibaos.plymouth kibaos.script splash.png wave-0.png wave-149.png wave-gradient.png wave-cover.png;do
[ -s "$KIBA_PLY_DIR/$_f" ]||{
echo "ERROR: boot animation asset $_f is missing -- cannot re-apply KibaOS boot animation" >&2
exit 1
}
done
mkdir -p /etc/plymouth
cat >/etc/plymouth/plymouthd.conf <<'PLYMOUTHD_FINAL'
[Daemon]
Theme=kibaos
ShowDelay=0
DeviceTimeout=8
PLYMOUTHD_FINAL
plymouth-set-default-theme -R kibaos||echo "!! plymouth-set-default-theme -R failed" >&2
cp "$KIBA_PLY_DIR/splash.png" /usr/share/plymouth/arch-logo.png
for _theme_dir in bgrt spinner;do
if [ -d "/usr/share/plymouth/themes/$_theme_dir" ];then
cp "$KIBA_PLY_DIR/splash.png" "/usr/share/plymouth/themes/$_theme_dir/watermark.png"
fi
done
[ "$(plymouth-set-default-theme)" = "kibaos" ]||{
echo "ERROR: default Plymouth theme is not kibaos after re-apply" >&2
exit 1
}
echo "=== Boot animation: kibaos theme re-applied ==="
rm -rf /var/cache/pacman/pkg/*
rm -rf /usr/share/man/* /usr/share/info/* /usr/share/doc/*
find /usr/lib/firmware -mindepth 1 -maxdepth 1 \
! -name 'i915' ! -name 'amdgpu' ! -name 'radeon' \
! -name 'nouveau' ! -name 'nvidia' ! -name 'iwlwifi*' ! -name 'ath*' \
! -name 'ath10k' ! -name 'ath11k' ! -name 'rtl_nic' \
! -name 'rtlwifi' ! -name 'rtw88' ! -name 'rtw89' \
! -name 'sof' ! -name 'sof-tplg' ! -name 'intel' \
-exec rm -rf {} + 2>/dev/null||true
find /usr/share/locale -mindepth 1 -maxdepth 1 \
! -name 'en_US' ! -name 'en_GB' ! -name 'locale.alias' \
-exec rm -rf {} + 2>/dev/null||true
find /usr -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null||true
find /usr -name '*.pyc' -delete 2>/dev/null||true
find /usr/lib -name '*.a' -delete 2>/dev/null||true
rm -rf /usr/include/* 2>/dev/null||true
find /usr/share/icons -name 'icon-theme.cache' -delete 2>/dev/null||true
rm -rf /var/lib/pacman/sync/* /tmp/* /var/tmp/* 2>/dev/null||true
chown -R 1000:1000 /home/liveuser
mkdir -p /home/liveuser/.config/autostart
install -d -m 755 -o 1000 -g 1000 /home/liveuser/.config/dconf
chown -R 1000:1000 /home/liveuser/.config
for _icon in /home/liveuser/Desktop/*.desktop;do
[ -f "$_icon" ]||continue
chmod 755 "$_icon" 2>/dev/null||true
chown 1000:1000 "$_icon" 2>/dev/null||true
runuser -u liveuser -- gio set "$_icon" metadata::trusted true 2>/dev/null||true
done
cat >/usr/local/bin/kibaos-trust-desktop-icons <<'TRUSTICONS'
#!/bin/sh
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null||echo "$HOME/Desktop")"
[ -d "$DESKTOP_DIR" ]||exit 0
for f in "$DESKTOP_DIR"/*.desktop;do
[ -f "$f" ]||continue
chmod +x "$f" 2>/dev/null||true
gio set "$f" metadata::trusted true 2>/dev/null||true
done
TRUSTICONS
chmod 755 /usr/local/bin/kibaos-trust-desktop-icons
cat >/home/liveuser/.config/autostart/kibaos-trust-desktop-icons.desktop <<'TRUSTAUTO'
[Desktop Entry]
Type=Application
Name=Trust Desktop Icons
Exec=/usr/local/bin/kibaos-trust-desktop-icons
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
TRUSTAUTO
chown 1000:1000 /home/liveuser/.config/autostart/kibaos-trust-desktop-icons.desktop
cat >/etc/resolv.conf <<'RESOLVCONF'
nameserver 1.1.1.1
nameserver 1.0.0.1
RESOLVCONF
if [ "$(uname -m)" = "aarch64" ];then
_kver="$(ls -1 /usr/lib/modules|head -n1)"
if [ -z "$_kver" ];then
echo "ERROR: no kernel module directory found under /usr/lib/modules" >&2
exit 1
fi
mkinitcpio -k "$_kver" -c /etc/mkinitcpio.conf.d/archiso.conf -g /boot/initramfs-linux.img
fi
pkill -x gvfsd-fuse 2>/dev/null||true
pkill -x gvfsd 2>/dev/null||true
pkill -x dbus-daemon 2>/dev/null||true
sleep 1
awk '$3 ~ /^fuse/ {print $2}' /proc/mounts|while read -r _m;do
fusermount3 -uz "$_m" 2>/dev/null||fusermount -uz "$_m" 2>/dev/null||umount -l "$_m" 2>/dev/null||true
done
rm -rf /root/.gvfs /home/*/.gvfs 2>/dev/null||true
rmdir /run/user/*/gvfs 2>/dev/null||true
echo "=== remaining fuse mounts (should be none): ==="
grep -E 'gvfs|fuse' /proc/mounts||true
rm -f /etc/machine-id
touch /etc/machine-id
echo "=== customize_airootfs.sh complete ==="
CUSTOMIZE
chmod +x "$AIROOTFS/root/customize_airootfs.sh"
cd "$WORKDIR"
rm -rf "$WORKDIR/work"
if [ "$KIBA_ARCH" = "aarch64" ];then
mkdir -p "$WORKDIR/work/pacman-gnupg"
pacman-key --gpgdir "$WORKDIR/work/pacman-gnupg" --init
pacman-key --gpgdir "$WORKDIR/work/pacman-gnupg" --populate archlinux
pacman-key --gpgdir "$WORKDIR/work/pacman-gnupg" --recv-keys \
68B3537F39A313B3E574D06777193F152BDBE6A6 \
--keyserver keyserver.ubuntu.com
pacman-key --gpgdir "$WORKDIR/work/pacman-gnupg" --lsign-key \
68B3537F39A313B3E574D06777193F152BDBE6A6
fi
mkarchiso -v -w work -o out "$PROFILE/"
cd "$WORKDIR"
rm -rf iso_root kibaos.iso
mv work/iso iso_root
rm -f out/*.iso
for _f in iso_root/EFI/BOOT/BOOTx64.EFI \
work/efiboot.img;do
[ -f "$_f" ]||{
echo "ERROR: $_f is missing -- cannot build the UEFI ISO" >&2
exit 1
}
done
cp -f work/efiboot.img iso_root/EFI/BOOT/efiboot.img
xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid KIBAOS \
-e EFI/BOOT/efiboot.img -no-emul-boot \
-efi-boot-part --efi-boot-image \
-o kibaos.iso iso_root/
if [ -f kibaos.iso ];then
mv kibaos.iso "$ISO.iso"
xorriso -indev "$ISO.iso" -report_el_torito plain -report_system_area plain 2>&1|tail -n 60||true
sha256sum "$ISO.iso" >"$ISO.iso.sha256"
echo "╔══════════════════════════════════════╗"
echo "║  KibaOS build complete!       ║"
echo "║  $ISO.iso            ║"
echo "╚══════════════════════════════════════╝"
else
echo "ERROR: kibaos.iso not found after xorriso!"
exit 1
fi