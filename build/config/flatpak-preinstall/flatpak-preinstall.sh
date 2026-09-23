#!/usr/bin/bash
###############################################################################
# flatpak-preinstall
###############################################################################
# Installs the Flatpaks staged by the image build in
# /usr/share/flatpak/preinstall.d/. Stock-flatpak stand-in for the
# `flatpak preinstall` subcommand, which only exists in uBlue's patched
# flatpak; layering that COPR build here would freeze flatpak at one EVR
# until the base image's own updates overtake it. Runs from
# flatpak-preinstall.service on every boot; installing an app that is
# already installed is a no-op, so re-runs converge.
#
# File format (see custom/flatpaks/README.md): INI groups
#   [Flatpak Preinstall org.example.App]
#   Branch=stable
#   Install=false
# Honored keys: Branch (passed as --branch; omitted = remote default),
# Install (skips the group when false). `#` and `;` start comments.

set -euo pipefail

PREINSTALL_DIR="/usr/share/flatpak/preinstall.d"
FLATHUB_REPO="https://flathub.org/repo/flathub.flatpakrepo"

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "${s}"
}

shopt -s nullglob
preinstall_files=("${PREINSTALL_DIR}"/*.preinstall)
shopt -u nullglob

if [[ ${#preinstall_files[@]} -eq 0 ]]; then
    echo "flatpak-preinstall: nothing staged in ${PREINSTALL_DIR}"
    exit 0
fi

# Collect "appid|branch" per group; empty branch = let flatpak resolve the
# remote's default branch.
entries=()
appid=""
branch=""
want=true

flush() {
    if [[ -n "${appid}" && "${want}" == true ]]; then
        entries+=("${appid}|${branch}")
    fi
    appid=""
    branch=""
    want=true
}

for file in "${preinstall_files[@]}"; do
    while IFS= read -r raw || [[ -n "${raw}" ]]; do
        line="$(trim "${raw}")"
        [[ -z "${line}" ]] && continue
        case "${line:0:1}" in
            '#' | ';') continue ;;
        esac
        if [[ "${line}" =~ ^\[Flatpak[[:space:]]+Preinstall[[:space:]]+([^]]+)\]$ ]]; then
            flush
            appid="$(trim "${BASH_REMATCH[1]}")"
        elif [[ -n "${appid}" && "${line}" == *=* ]]; then
            key="$(trim "${line%%=*}")"
            value="$(trim "${line#*=}")"
            case "${key}" in
                Branch) branch="${value}" ;;
                Install) [[ "${value,,}" =~ ^(false|no|0)$ ]] && want=false ;;
            esac
        fi
    done <"${file}"
    flush
done

if [[ ${#entries[@]} -eq 0 ]]; then
    echo "flatpak-preinstall: no enabled entries in ${PREINSTALL_DIR}"
    exit 0
fi

flatpak remote-add --if-not-exists flathub "${FLATHUB_REPO}"

failed=0
for entry in "${entries[@]}"; do
    appid="${entry%%|*}"
    branch="${entry##*|}"
    echo "flatpak-preinstall: installing ${appid}"
    if [[ -n "${branch}" ]]; then
        flatpak install -y flathub "${appid}" --branch="${branch}" \
            || { echo "flatpak-preinstall: failed to install ${appid}" >&2; failed=1; }
    else
        flatpak install -y flathub "${appid}" \
            || { echo "flatpak-preinstall: failed to install ${appid}" >&2; failed=1; }
fi
done

exit "${failed}"
