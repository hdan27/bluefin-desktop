#!/usr/bin/env bats
# Unit tests for build/30-niri-desktop.sh.
#
# Same sandbox strategy as 10-build_test.bats: the script is rewritten to
# point /ctx, /etc and /usr/lib at a throwaway root, and dnf5/systemctl are
# stubbed with logging shims. The rewrite is asserted below so that a path
# drift in the script fails loudly instead of touching the host.
#
# Run with: bats tests/unit/30-niri-desktop_test.bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_SRC="${REPO_ROOT}/build/30-niri-desktop.sh"
CONFIG_SRC="${REPO_ROOT}/build/config/niri/config.kdl"

setup() {
    TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/30-niri.${BATS_TEST_NUMBER:-0}.$$"
    SANDBOX="${TEST_ROOT}/root"
    CTX="${SANDBOX}/ctx"
    STUB_BIN="${TEST_ROOT}/stub-bin"
    SCRIPT="${TEST_ROOT}/30-niri-desktop.sh"

    DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
    SYSTEMCTL_LOG="${TEST_ROOT}/logs/systemctl.log"

    GREETD_CONF="${SANDBOX}/etc/greetd/config.toml"
    NIRI_CONF="${SANDBOX}/etc/xdg/niri/config.kdl"
    DMS_WANTS_LINK="${SANDBOX}/usr/lib/systemd/user/niri.service.wants/dms.service"

    mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs"
    mkdir -p "${CTX}/build/config/niri"

    # The real helper library is sourced verbatim so a syntax break there
    # fails this suite too.
    cp "${REPO_ROOT}/build/copr-helpers.sh" "${CTX}/build/copr-helpers.sh"
    cp "${CONFIG_SRC}" "${CTX}/build/config/niri/config.kdl"

    sed \
        -e "s#/ctx/#${CTX}/#g" \
        -e "s#/etc/#${SANDBOX}/etc/#g" \
        -e "s#/usr/lib/#${SANDBOX}/usr/lib/#g" \
        "${BUILD_SRC}" >"${SCRIPT}"

    export PATH="${STUB_BIN}:${PATH}"
    export DNF5_LOG SYSTEMCTL_LOG

    for tool in dnf5 systemctl; do
        local log_var
        log_var="$(printf '%s' "${tool}" | tr '[:lower:]' '[:upper:]')_LOG"
        cat >"${STUB_BIN}/${tool}" <<EOF
#!/usr/bin/bash
printf '%s\n' "\$*" >> "\${${log_var}}"
exit 0
EOF
        chmod +x "${STUB_BIN}/${tool}"
    done
}

teardown() {
    rm -rf "${TEST_ROOT}"
}

@test "30-niri: sandbox rewrite left no writes to the host filesystem" {
    # Guards the rewrite above: if the script's paths change, the sed no longer
    # matches and every other test in this file would silently touch the host.
    run grep -nE '(^|[^-[:alnum:]])/ctx/|(^|[^-[:alnum:]])/etc/|[^-[:alnum:]]/usr/lib/' "${SCRIPT}"
    [ "$status" -ne 0 ]

    grep -q "source ${CTX}/build/copr-helpers.sh" "${SCRIPT}"
}

@test "30-niri: completes successfully" {
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"niri + DMS desktop installed!"* ]]
}

@test "30-niri: emits GitHub Actions group markers" {
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::group:: Install niri and session support packages"* ]]
    [[ "$output" == *"::group:: Install DankMaterialShell from COPR"* ]]
    [[ "$output" == *"::group:: Remove the GNOME session"* ]]
    [[ "$output" == *"::group:: Start DMS with the niri session"* ]]
    [[ "$output" == *"::group:: Configure the greetd login screen"* ]]
    [[ "$output" == *"::group:: Install the default niri configuration"* ]]
    [[ "$output" == *"::endgroup::"* ]]
}

@test "30-niri: installs the session stack, COPR packages, and removes GNOME in order" {
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]

    mapfile -t calls <"${DNF5_LOG}"
    [ "${#calls[@]}" -eq 8 ]

    # Fedora-native session packages (10-build.sh owns the rest).
    [ "${calls[0]}" = "install -y niri xwayland-satellite quickshell xdg-desktop-portal-gnome xdg-desktop-portal-gtk matugen dgop cava qt6-qtmultimedia wl-clipboard cliphist i2c-tools accountsservice" ]

    # DMS from its COPR, enabled and disabled around an isolated install.
    [ "${calls[1]}" = "-y copr enable avengemedia/dms" ]
    [ "${calls[2]}" = "-y copr disable avengemedia/dms" ]
    [ "${calls[3]}" = "-y install --enablerepo=copr:copr.fedorainfracloud.org:avengemedia:dms dms" ]

    # Greeter and search backend from the danklinux COPR, same isolation.
    [ "${calls[4]}" = "-y copr enable avengemedia/danklinux" ]
    [ "${calls[5]}" = "-y copr disable avengemedia/danklinux" ]
    [ "${calls[6]}" = "-y install --enablerepo=copr:copr.fedorainfracloud.org:avengemedia:danklinux dms-greeter danksearch" ]

    # GNOME session stack removal.
    [ "${calls[7]}" = "remove -y gnome-shell gnome-session gnome-session-wayland-session gdm" ]
}

@test "30-niri: enables greetd as the only display manager" {
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]

    mapfile -t calls <"${SYSTEMCTL_LOG}"
    [ "${#calls[@]}" -eq 1 ]
    [ "${calls[0]}" = "enable greetd.service" ]
}

@test "30-niri: configures greetd to run dms-greeter under niri" {
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]

    [ -f "${GREETD_CONF}" ]
    grep -q '^vt = 1$' "${GREETD_CONF}"
    grep -q '^user = "greeter"$' "${GREETD_CONF}"
    grep -q '^command = "/usr/bin/dms-greeter --command niri"$' "${GREETD_CONF}"
}

@test "30-niri: binds dms.service to the niri user session" {
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]

    [ -L "${DMS_WANTS_LINK}" ]
    [ "$(readlink "${DMS_WANTS_LINK}")" = "${SANDBOX}/usr/lib/systemd/user/dms.service" ]
}

@test "30-niri: installs the default niri config verbatim" {
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]

    [ -f "${NIRI_CONF}" ]
    [ "$(cat "${CONFIG_SRC}")" = "$(cat "${NIRI_CONF}")" ]
}

@test "30-niri: fails fast when copr-helpers.sh is missing from the context" {
    rm -f "${CTX}/build/copr-helpers.sh"
    run bash "${SCRIPT}"
    [ "$status" -ne 0 ]
    [ ! -e "${GREETD_CONF}" ]
    [ ! -e "${NIRI_CONF}" ]
}
