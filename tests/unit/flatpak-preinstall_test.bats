#!/usr/bin/env bats
# Tests for build/config/flatpak-preinstall/flatpak-preinstall.sh, the
# stock-flatpak consumer for /usr/share/flatpak/preinstall.d/.
#
# The runner hardcodes /usr/share/flatpak/preinstall.d, so each test rewrites
# a throwaway copy to point at a sandbox dir and stubs `flatpak` on the PATH.
# Nothing runs against the host.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNNER_SRC="${REPO_ROOT}/build/config/flatpak-preinstall/flatpak-preinstall.sh"

setup() {
    TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/flatpak-preinstall.${BATS_TEST_NUMBER:-0}.$$"
    SANDBOX="${TEST_ROOT}/root"
    PREINSTALL_DIR="${SANDBOX}/usr/share/flatpak/preinstall.d"
    SCRIPT="${TEST_ROOT}/flatpak-preinstall"

    FLATPAK_LOG="${TEST_ROOT}/logs/flatpak.log"
    FAIL_INSTALL="${TEST_ROOT}/logs/fail-install.txt"

    mkdir -p "${PREINSTALL_DIR}" "${TEST_ROOT}/logs"

    sed -e "s#/usr/share/flatpak/preinstall.d#${PREINSTALL_DIR}#g" \
        "${RUNNER_SRC}" >"${SCRIPT}"
    chmod +x "${SCRIPT}"

    # flatpak stub: logs argv; installs listed in FAIL_INSTALL exit 1.
    mkdir -p "${TEST_ROOT}/stub-bin"
    cat >"${TEST_ROOT}/stub-bin/flatpak" <<STUB
#!/usr/bin/bash
printf '%s\n' "\$*" >> "${FLATPAK_LOG}"
if [[ "\$1" == "install" ]] && grep -qxF -- "\$4" "${FAIL_INSTALL}" 2>/dev/null; then
    exit 1
fi
exit 0
STUB
    chmod +x "${TEST_ROOT}/stub-bin/flatpak"
    : >"${FAIL_INSTALL}"
    : >"${FLATPAK_LOG}"
    export FLATPAK_LOG FAIL_INSTALL
    export PATH="${TEST_ROOT}/stub-bin:${PATH}"
}
teardown() {
    rm -rf "${TEST_ROOT}"
}

_log_line() {
    grep -nF -- "$1" "${FLATPAK_LOG}" | head -n1 | cut -d: -f1
}

@test "flatpak-preinstall: adds the flathub remote before installing anything" {
    printf '[Flatpak Preinstall org.mozilla.firefox]\nBranch=stable\n' \
        >"${PREINSTALL_DIR}/default.preinstall"

    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]

    remote_line="$(_log_line "remote-add --if-not-exists flathub")"
    install_line="$(_log_line "install -y flathub org.mozilla.firefox")"
    [ -n "${remote_line}" ]
    [ -n "${install_line}" ]
    [ "${remote_line}" -lt "${install_line}" ]
}

@test "flatpak-preinstall: installs every enabled entry with its branch" {
    cat >"${PREINSTALL_DIR}/default.preinstall" <<'EOF'
[Flatpak Preinstall org.mozilla.firefox]
Branch=stable

[Flatpak Preinstall com.danklinux.dankcalendar]
Branch=beta
EOF

    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]

    grep -qxF "install -y flathub org.mozilla.firefox --branch=stable" "${FLATPAK_LOG}"
    grep -qxF "install -y flathub com.danklinux.dankcalendar --branch=beta" "${FLATPAK_LOG}"
}

@test "flatpak-preinstall: uses flatpak's default branch when Branch is omitted" {
    printf '[Flatpak Preinstall org.example.App]\n' \
        >"${PREINSTALL_DIR}/default.preinstall"

    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]

    grep -qxF "install -y flathub org.example.App" "${FLATPAK_LOG}"
    # No branchless-key confusion: exactly one install call happened.
    [ "$(grep -cF "install -y" "${FLATPAK_LOG}")" -eq 1 ]
}

@test "flatpak-preinstall: skips commented groups and Install=false entries" {
    cat >"${PREINSTALL_DIR}/default.preinstall" <<'EOF'
# a comment
;[Flatpak Preinstall org.comment.Out]
;Branch=stable

[Flatpak Preinstall org.disabled.App]
Install=false

[Flatpak Preinstall org.enabled.App]
Branch=stable
EOF

    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]

    [ "$(grep -cF "install -y" "${FLATPAK_LOG}")" -eq 1 ]
    grep -qxF "install -y flathub org.enabled.App --branch=stable" "${FLATPAK_LOG}"
}

@test "flatpak-preinstall: exits cleanly without touching flatpak when nothing is staged" {
    # No .preinstall files at all.
    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"${FLATPAK_LOG}")" -eq 0 ]
    [[ "${output}" == *"nothing staged"* ]]
}

@test "flatpak-preinstall: a failed install does not abort the remaining entries" {
    cat >"${PREINSTALL_DIR}/default.preinstall" <<'EOF'
[Flatpak Preinstall org.mozilla.firefox]
Branch=stable

[Flatpak Preinstall com.danklinux.dankcalendar]
Branch=stable
EOF
    printf 'org.mozilla.firefox\n' >"${FAIL_INSTALL}"

    run bash "${SCRIPT}"
    [ "$status" -eq 1 ]
    [[ "${output}" == *"failed to install"* ]]

    grep -qxF "install -y flathub org.mozilla.firefox --branch=stable" "${FLATPAK_LOG}"
    grep -qxF "install -y flathub com.danklinux.dankcalendar --branch=stable" "${FLATPAK_LOG}"
}

@test "flatpak-preinstall: processes every .preinstall file in the directory" {
    printf '[Flatpak Preinstall org.first.App]\nBranch=stable\n' \
        >"${PREINSTALL_DIR}/default.preinstall"
    printf '[Flatpak Preinstall org.second.App]\nBranch=stable\n' \
        >"${PREINSTALL_DIR}/extra.preinstall"

    run bash "${SCRIPT}"
    [ "$status" -eq 0 ]

    grep -qxF "install -y flathub org.first.App --branch=stable" "${FLATPAK_LOG}"
    grep -qxF "install -y flathub org.second.App --branch=stable" "${FLATPAK_LOG}"
}
