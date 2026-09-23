#!/usr/bin/bash

set -euo pipefail

###############################################################################
# Main Build Script
###############################################################################
# This script follows the @ublue-os/bluefin pattern for build scripts.
# It uses set -euo pipefail for strict error handling.
###############################################################################

# Source helper functions
# shellcheck source=/dev/null
source /ctx/build/copr-helpers.sh

# Enable nullglob for all glob operations to prevent failures on empty matches
shopt -s nullglob

echo "::group:: Overlay Brew Integration Files"

# Brew integration files from @ublue-os/brew OCI (tarball, systemd services, shell integration)
rsync -rvK /ctx/oci/brew/ /

echo "::endgroup::"

echo "::group:: Install ujust from @projectbluefin/common"

# The vanilla Silverblue base ships no ujust. The common OCI's shared layer
# carries the ujust wrapper, shell completions, and the entry justfile
# (00-entry.just) whose optional imports pick up 60-custom.just, consolidated
# below, plus the upstream Brewfiles those recipes reference.
# Deliberately NOT copied from shared/: etc/ (containers signature policy,
# profile.d), systemd units + presets (uupd timers, flatpak-preinstall — that
# subcommand exists only in uBlue's patched flatpak), and udev rules. Those are
# Bluefin runtime choices this base has not opted into.
rsync -rvK /ctx/oci/common/shared/usr/bin/ujust /usr/bin/
rsync -rvK /ctx/oci/common/shared/usr/share/ublue-os/ /usr/share/ublue-os/
rsync -rvK /ctx/oci/common/shared/usr/share/bash-completion/ /usr/share/bash-completion/
rsync -rvK /ctx/oci/common/shared/usr/share/fish/ /usr/share/fish/
rsync -rvK /ctx/oci/common/shared/usr/share/zsh/ /usr/share/zsh/

echo "::endgroup::"

echo "::group:: Copy Custom Files"

# Copy Brewfiles to standard location
mkdir -p /usr/share/ublue-os/homebrew/
cp /ctx/custom/brew/*.Brewfile /usr/share/ublue-os/homebrew/

# Consolidate Just Files
mkdir -p /usr/share/ublue-os/just/
find /ctx/custom/ujust -iname '*.just' -exec printf "\n\n" \; -exec cat {} \; >>/usr/share/ublue-os/just/60-custom.just

# Copy Flatpak preinstall files
mkdir -p /usr/share/flatpak/preinstall.d/
cp /ctx/custom/flatpaks/*.preinstall /usr/share/flatpak/preinstall.d/

# First-boot consumer for the preinstall files: a stock-flatpak runner that
# replaces uBlue's patched `flatpak preinstall` subcommand (see script header).
install -Dpm0755 /ctx/build/config/flatpak-preinstall/flatpak-preinstall.sh /usr/libexec/flatpak-preinstall
install -Dpm0644 /ctx/build/config/flatpak-preinstall/flatpak-preinstall.service /usr/lib/systemd/system/flatpak-preinstall.service

echo "::endgroup::"

echo "::group:: Install Packages"

# Install the default packages and verify the DNF cache is working.
# gum is required by the default ujust recipes for interactive prompts.
# just is the runner the ujust wrapper execs; fzf backs `ujust --choose`
# The C/C++ toolchain lets user-installed Rust link: gcc/gcc-c++ provide the
# cc/c++ linkers rustc invokes, glibc-devel the crt objects and headers,
# make/pkgconf-pkg-config/openssl-devel the common -sys crate dependencies
# (so `cargo install just` and friends build out of the box).
dnf5 install -y tmux gum mc gcc gcc-c++ glibc-devel make pkgconf-pkg-config openssl-devel pcsc-lite pcsc-lite-libs pcsc-lite-devel fuse-libs just fzf

# Example using COPR with isolated pattern:
# copr_install_isolated "ublue-os/staging" package-name

echo "::endgroup::"

echo "::group:: System Configuration"

# Enable/disable systemd services
systemctl enable podman.socket
systemctl enable brew-setup.service
systemctl enable brew-update.timer
systemctl enable brew-upgrade.timer
systemctl enable pcscd.socket pcscd.service
systemctl enable flatpak-preinstall.service
# Example: systemctl mask unwanted-service

echo "::endgroup::"

# Restore default glob behavior
shopt -u nullglob

echo "Custom build complete!"
