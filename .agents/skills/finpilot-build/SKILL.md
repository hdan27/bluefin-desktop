---
name: finpilot-build
description: >-
  Containerfile multi-stage build, image digest pinning in FROM lines,
  Justfile local build recipes, and build script conventions.
  Use when changing Containerfile, Justfile, or build/*.sh.
---

# finpilot Build System

## When to Use

- Editing `Containerfile` (ARGs, stages, base image, RUN directives)
- Editing `Justfile` (build recipe, tag strategy, version computation)
- Adding or modifying `build/*.sh` scripts
- Debugging why a local build fails differently from CI

## When NOT to Use

- CI workflow changes (`.github/workflows/`) — use `finpilot-ci`
- Runtime customizations (`custom/`) — use `finpilot-custom`

## Core Process

1. **Identify which `FROM` line or ARG drives your change**
2. **All image digests** are pinned directly in `Containerfile` `FROM` lines; Renovate updates them
3. **Run `just build`** locally before opening a PR; `just lint` to shellcheck
4. **Add `00-` prefix** for metadata scripts, `10-` for main packages, `20+` for extras

## Image Pinning Pattern

All OCI images are pinned directly in `Containerfile` `FROM` lines. Renovate's
built-in `dockerfile` manager updates every digest.

```dockerfile
# OCI context images
FROM ghcr.io/projectbluefin/common:latest@sha256:<current> AS common
FROM ghcr.io/ublue-os/brew:latest@sha256:<current> AS brew

# Base image
ARG FEDORA_MAJOR_VERSION="44"
FROM quay.io/fedora-ostree-desktops/silverblue:44@sha256:<current>
```

**Never update digests manually.** Let Renovate open PRs for digest bumps.

To change an image or tag, edit its `FROM` line. To bump the Fedora major
release, update both the `FEDORA_MAJOR_VERSION` ARG and the base image tag.

## Build Script Conventions

### Numbering

| Prefix             | Purpose                                                                               |
| ------------------ | ------------------------------------------------------------------------------------- |
| `00-image-info.sh` | Metadata only: writes `image-info.json`, customises `os-release`                      |
| `10-build.sh`      | Main script: copies custom files, `dnf5 install`                                      |
| `20-*.sh`          | Optional extras: third-party repos, COPR packages                                     |
| `30-*.sh`          | Optional desktop swaps                                                                |
| `clean-stage.sh`   | Always runs last: reverts `keepcache`, disables fedora flatpak repo, clears artefacts |

### Template build script rules

- **Default packages**: build scripts in the template must have **no extra packages installed by default** — only commented examples. Users add their own.
- **Exception**: `dnf5 install -y tmux gum mc` in `build/10-build.sh` is intentional: tmux smoke-tests that the DNF cache is warm, gum is required by the ujust recipes' interactive prompts, mc is this fork's console file manager. Do not remove.
- Always use `dnf5` — never `dnf`, `yum`, or `rpm-ostree`
- Always use `dnf5 install -y` (non-interactive)
- COPR: enable → install → `copr_install_isolated` (auto-disables); never leave a repo enabled

### NVIDIA GPU support

NVIDIA support is a build-time option activated by renaming the example script and adding its explicit Containerfile `RUN` block:

```bash
mv build/40-nvidia.sh.example build/40-nvidia.sh
# Add the standard RUN block for /ctx/build/40-nvidia.sh after 10-build.sh.
# See build/README.md.
just build
```

All NVIDIA logic is self-contained in `40-nvidia.sh`. When both the script and its explicit Containerfile `RUN` block are activated, it provisions the NVIDIA driver, CDI container toolkit, Mutter kms-modifiers, and bootc kernel args directly into the base image — no separate image variant, no `IMAGE_NAME` gating.

Deactivate by removing its Containerfile `RUN` block and renaming the script back to `.example`. See `build/40-nvidia.sh.example` for the full implementation.

### Desktop swap: niri + DankMaterialShell

`build/30-niri-desktop.sh` (active, with its explicit Containerfile `RUN` block) replaces the Silverblue GNOME session with niri + DankMaterialShell (DMS). Durable gotchas learned wiring it:

- **Package names**: `niri`, `quickshell`, `xwayland-satellite`, `matugen`, `dgop`, `cava` are all in Fedora proper. DMS itself is COPR-only: `avengemedia/dms` → `dms`; `avengemedia/danklinux` → `dms-greeter` and `danksearch` (the Fedora name — `dsearch` is the Arch/AUR name and does not resolve).
- **GNOME removal**: `dnf5 remove -y gnome-shell gnome-session gnome-session-wayland-session gdm` kills the session only; base apps (Ptyxis, Files, Software, Settings) have no dependency on those and keep working under niri. Fedora 44 has no `gnome-session-xsession` — don't list it. The F44 Silverblue terminal is **ptyxis**, not gnome-console/kgx — bind `spawn "ptyxis"`.
- **xwayland-satellite needs no config**: niri ≥ 25.08 spawns it on demand. Do not add `spawn-at-startup xwayland-satellite`.
- **Login swap**: write `/etc/greetd/config.toml` (`user = "greeter"`, `command = "/usr/bin/dms-greeter --command niri"`), `rm -f /etc/systemd/system/display-manager.service` (stale gdm alias), then `systemctl enable greetd.service` — greetd's unit declares `Alias=display-manager.service` and takes over the alias.
- **GNOME removal**: `dnf5 remove -y gnome-shell gnome-session gnome-session-wayland-session gdm` kills the session only; GNOME apps (Console, Files, Software, Settings) have no dependency on those and keep working under niri. Fedora 44 has no `gnome-session-xsession` — don't list it.
- **Default compositor config**: `install -Dm644 build/config/niri/config.kdl /etc/xdg/niri/config.kdl`; niri uses it for any user without `~/.config/niri/config.kdl`. Validate edits with `niri validate -c build/config/niri/config.kdl` (e.g. `podman run --rm -v "$PWD:/repo:Z" fedora:44` with `dnf5 install niri`).

Deactivate by removing the Containerfile `RUN` block for `30-niri-desktop.sh` and deleting the script and `build/config/niri/` (it is a fork customization, not a template example).

### 00-image-info.sh branding

The comment in the `os-release` append block must use `${IMAGE_NAME}`:

```bash
cat >> "${OS_RELEASE}" << EOF

# ${IMAGE_NAME} image identity   ← use variable, not literal "finpilot"
VARIANT_ID="${IMAGE_FLAVOR}"
...
EOF
```

## Base Image

Default: `quay.io/fedora-ostree-desktops/silverblue:44`

The major version is controlled by the `FEDORA_MAJOR_VERSION` ARG and the `FROM` line in `Containerfile`. To bump Fedora releases:

1. Update `FEDORA_MAJOR_VERSION` and the `FROM` line in `Containerfile`
2. Update the Renovate rule that blocks major updates for the base image
3. Test with `just build` — expect `bootc container lint --fatal-warnings` to catch regressions

## Common Rationalizations

| Rationalization                                                      | Reality                                                                                                |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| "I'll skip the digest pin and use a floating tag."                   | Non-reproducible builds and breaks supply-chain traceability. The `FROM` line should always be pinned. |
| "Renovate won't notice a manually pinned digest in `Containerfile`." | Renovate's dockerfile manager tracks `FROM image:tag@sha256:...` in `Containerfile` automatically.     |
| "I'll add `dnf` as a fallback since dnf5 might not be installed."    | Never. `dnf5` is the canonical tool. Using `dnf` or `rpm-ostree` diverges from Bluefin.                |

## Red Flags

- Floating tags (`FROM image:latest` without `@sha256:...`)
- `FROM ${FOO}@${BAR}` where `BAR` could be empty
- `dnf`, `yum`, or `rpm-ostree` in any build script
- COPR left enabled after package install (missing `dnf5 copr disable`)
- `# finpilot image identity` hardcoded instead of `# ${IMAGE_NAME} image identity`

## Verification

- [ ] Are all `FROM` lines pinned with `@sha256:...`?
- [ ] Does `build/00-image-info.sh` use `${IMAGE_NAME}` in the os-release comment?
- [ ] Does `just build` succeed locally?
- [ ] Does `just lint` pass clean (shellcheck)?
- [ ] Does `bootc container lint --fatal-warnings` pass in CI?
