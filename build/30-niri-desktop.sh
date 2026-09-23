#!/usr/bin/bash

set -euo pipefail

###############################################################################
# Niri + DankMaterialShell Desktop
###############################################################################
# Replaces the GNOME session from the Silverblue base image:
#   - niri (Fedora package): scrollable-tiling Wayland compositor. Ships
#     /usr/share/wayland-sessions/niri.desktop (Exec=niri-session) and the
#     niri.service systemd user unit.
#   - DankMaterialShell (COPR avengemedia/dms): the desktop shell, started as
#     the dms.service user unit bound to niri.service (image-wide equivalent
#     of the documented `systemctl --user add-wants niri.service dms`).
#   - dms-greeter + greetd (COPR avengemedia/danklinux / Fedora): login screen
#     replacing GDM. greetd.service aliases display-manager.service.
#   - xwayland-satellite: X11 apps; niri >= 25.08 starts it on demand with no
#     extra configuration.
#
# Docs:
#   https://niri-wm.github.io/niri/Getting-Started.html
#   https://danklinux.com/docs/dankmaterialshell/installation
#   https://danklinux.com/docs/dankmaterialshell/compositors (niri section)
#
# GNOME apps from the base image (Ptyxis, Files, Software, Settings...) have
# no dependency on the removed session packages and keep working under niri.

# Source helper functions
# shellcheck source=/dev/null
source /ctx/build/copr-helpers.sh

echo "::group:: Install niri and session support packages"

# niri session stack, all from Fedora repositories except quickshell (see
# the danklinux COPR install below):
#   niri / xwayland-satellite   compositor + X11 compatibility
#   xdg-desktop-portal-gnome    ScreenCast portal backend used by niri
#   xdg-desktop-portal-gtk      file chooser and other portal frontends
#   matugen, dgop, cava         DMS companions: theming, metrics, visualizer
#   qt6-qtmultimedia            DMS system sound feedback
#   wl-clipboard, cliphist      DMS clipboard history
#   i2c-tools                   DDC monitor backlight control for DMS
#   accountsservice             user list/faces for DMS and the greeter
#
# NOT here: quickshell. Fedora's quickshell (0.2.x) is too old for the DMS
# shells — dms and dms-greeter QML open with `//@ pragma AppId <id>` comment
# directives, supported from quickshell 0.3.0. With Fedora's build the greeter
# UI dies at QML parse ("Unrecognized pragma"), niri quits, greetd hits its
# start limit and the boot ends on niri's frozen startup spinner. See the
# quickshell note in the COPR block below for the ordering constraint.
dnf5 install -y \
  niri \
  xwayland-satellite \
  xdg-desktop-portal-gnome \
  xdg-desktop-portal-gtk \
  matugen \
  dgop \
  cava \
  qt6-qtmultimedia \
  wl-clipboard \
  cliphist \
  i2c-tools \
  accountsservice

echo "niri session stack installed"
echo "::endgroup::"

echo "::group:: Install DankMaterialShell from COPR"

# Order matters: quickshell MUST land before dms. Both dms and dms-greeter
# only carry a rich `(quickshell or quickshell-git)` dependency, so if
# quickshell is not yet installed when dms resolves, dnf satisfies it from
# Fedora (avengemedia/dms ships no quickshell of its own) — Fedora's 0.2.x
# then silently wins and the greeter crash-loops at boot. Installing the
# danklinux set first puts the COPR's 0.3.x quickshell in place so the later
# dms transaction finds the dependency already satisfied.

# quickshell:  QML framework for dms and dms-greeter. Must come from this
#              COPR (0.3.x build with the `//@ pragma` directives the DMS
#              shells use), not from Fedora — see the notes above and below.
# dms-greeter: greetd login screen in the DMS style (runs as the "greeter"
#              user created by the package's sysusers drop-in).
# danksearch:  DMS filesystem search backend (called "dsearch" on Arch).
copr_install_isolated "avengemedia/danklinux" quickshell dms-greeter danksearch

# dms: DankMaterialShell (shell + `dms` CLI, ships dms.service user unit)
copr_install_isolated "avengemedia/dms" dms

copr_install_isolated "wezfurlong/wezterm-nightly" wezterm

copr_install_isolated "scottames/ghostty" ghostty

echo "::endgroup::"

echo "::group:: Remove the GNOME session"

# Remove the GNOME session stack. GNOME apps stay: they do not depend on
# these packages. dnf5 cascades the removal to installed dependents
# (e.g. gnome-shell-extension-*).
dnf5 remove -y \
  gnome-shell \
  gnome-session \
  gnome-session-wayland-session \
  gdm

echo "GNOME session removed"
echo "::endgroup::"

echo "::group:: Start DMS with the niri session"

# Image-wide equivalent of the documented per-user setup:
#   systemctl --user add-wants niri.service dms
# dms.service is PartOf=graphical-session.target, so binding it to
# niri.service.wants makes DMS start with niri and stop when it exits.
mkdir -p /usr/lib/systemd/user/niri.service.wants
ln -sfn /usr/lib/systemd/user/dms.service \
  /usr/lib/systemd/user/niri.service.wants/dms.service

echo "::endgroup::"

echo "::group:: Configure the greetd login screen"

# greetd replaces GDM. dms-greeter runs as the "greeter" system user under a
# niri greeter config it generates itself; this mirrors `dms-greeter enable`
# from the upstream docs:
# https://github.com/AvengeMedia/dank-greeter
mkdir -p /etc/greetd
cat >/etc/greetd/config.toml <<'GREETD'
[terminal]
vt = 1

[default_session]
user = "greeter"
command = "/usr/bin/dms-greeter --command niri"
GREETD

# Drop a stale display-manager alias left behind by the removed gdm, then
# enable greetd (its unit declares Alias=display-manager.service).
rm -f /etc/systemd/system/display-manager.service
systemctl enable greetd.service

echo "greetd configured"
echo "::endgroup::"

echo "::group:: Install the default niri configuration"

# System-wide niri config: used by every user without their own
# ~/.config/niri/config.kdl. Includes the DMS keybindings, window rules and
# environment documented by the DMS compositor guide.
install -Dm644 /ctx/build/config/niri/config.kdl /etc/xdg/niri/config.kdl

echo "::endgroup::"

echo "::group:: Verify quickshell parses the DMS pragma directives"

# Gate on the exact failure that breaks the greeter: the dms and dms-greeter
# shells open with `//@ pragma AppId <id>` comment directives, which only
# quickshell >= 0.3 parses. If Fedora's quickshell won the resolution race
# anywhere above, the greeter dies at QML parse under greetd, niri quits and
# the boot ends on a frozen spinner — so fail the BUILD here instead.
probe_dir="$(mktemp -d)"
cat >"${probe_dir}/shell.qml" <<'PROBE'
//@ pragma AppId org.bluefin-desktop.build-probe
import Quickshell
ShellRoot {}
PROBE
qs_log="$(XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-${probe_dir}}" qs -p "${probe_dir}" 2>&1 || true)"
rm -rf "${probe_dir}"
if grep -q 'Unrecognized pragma' <<<"${qs_log}"; then
  echo "ERROR: installed quickshell cannot parse the DMS shells:"
  echo "${qs_log}"
  rpm -q quickshell
  exit 1
fi
echo "quickshell pragma gate passed"
echo "::endgroup::"

echo "niri + DMS desktop installed!"
