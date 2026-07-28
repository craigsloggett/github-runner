#!/bin/sh
#
# Provisions a self-hosted macOS runner on a fresh machine: downloads the pinned
# runner release, verifies it, and registers it against the repository.
#
# Not used when migrating an already-registered runner; `make sync && make
# install` is enough there, and re-running config.sh would churn the
# registration for no reason.
#
# Prerequisites this script checks but cannot install:
#   - Xcode installed, with its license accepted
#   - the Developer ID Application certificate in the login keychain
#   - `xcrun notarytool store-credentials` already run once for NOTARY_PROFILE
#
# After this succeeds, run `make sync && make install && make start`.

set -euf

provisioning_dir="$(cd -P "$(dirname "$0")" && pwd)"

# shellcheck source=config.sh
. "${provisioning_dir}/config.sh"

# Pinned so a fresh machine gets a known artifact rather than whatever "latest"
# resolves to. The runner self-updates on first contact regardless, so this
# pins the starting point, not the running version.
RUNNER_VERSION="2.336.0"
RUNNER_ARCH="osx-arm64"
RUNNER_SHA256="8e8839c49b7060b6b2154f4931f815df330c27f167d53ef2239ee3dfce28b079"

RUNNER_TARBALL="actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"

# die reports a fatal error and aborts.
die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# log prints a progress line.
log() {
  printf '==> %s\n' "$1"
}

# check_requirements asserts the tools and signing material this runner needs.
check_requirements() {
  [ "$(uname -s)" = "Darwin" ] || die "this provisions a macOS runner"
  [ "$(uname -m)" = "arm64" ] || die "RUNNER_ARCH is pinned to ${RUNNER_ARCH}"

  for tool in curl shasum tar gh xcrun security; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is required"
  done

  gh auth status >/dev/null 2>&1 || die "run 'gh auth login' first"

  xcrun --find xcodebuild >/dev/null 2>&1 ||
    die "Xcode is not installed or its license has not been accepted"

  security find-identity -v -p codesigning 2>/dev/null | grep -q "${TEAM_ID}" ||
    die "no Developer ID identity for team ${TEAM_ID} in the login keychain"

  xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 ||
    die "notary profile '${NOTARY_PROFILE}' is missing; run 'xcrun notarytool store-credentials'"
}

# download_runner fetches the pinned release into the runner root and verifies
# it before unpacking. A corrupt or substituted archive must not reach tar.
download_runner() {
  mkdir -p "${RUNNER_ROOT}"

  if [ -x "${RUNNER_ROOT}/config.sh" ]; then
    log "runner already unpacked at ${RUNNER_ROOT}"
    return 0
  fi

  log "downloading ${RUNNER_TARBALL}"
  curl -fsSL -o "${RUNNER_ROOT}/${RUNNER_TARBALL}" "${RUNNER_URL}" ||
    die "download failed"

  log "verifying checksum"
  printf '%s  %s\n' "${RUNNER_SHA256}" "${RUNNER_ROOT}/${RUNNER_TARBALL}" |
    shasum -a 256 -c - >/dev/null || die "checksum mismatch for ${RUNNER_TARBALL}"

  log "unpacking"
  tar xzf "${RUNNER_ROOT}/${RUNNER_TARBALL}" -C "${RUNNER_ROOT}"
  rm -f "${RUNNER_ROOT}/${RUNNER_TARBALL}"
}

# register_runner configures the runner against the repository.
#
# No --labels flag: on this runner version the defaults are already
# self-hosted, macOS and ARM64, which is exactly what the hark workflows target.
# Adding custom labels would duplicate them.
#
# The runner's config.sh sources its env.sh, which does `echo $PATH > .path`,
# so registering leaves the invoking shell's PATH as the job PATH. `make sync`
# must run after this, never before.
register_runner() {
  if [ -f "${RUNNER_ROOT}/.runner" ]; then
    log "already registered; skipping config.sh"
    return 0
  fi

  log "requesting a registration token for ${RUNNER_REPO}"
  token="$(gh api -X POST "repos/${RUNNER_REPO}/actions/runners/registration-token" \
    --jq '.token')" || die "could not get a registration token"

  log "registering"
  (
    cd "${RUNNER_ROOT}" || exit 1
    ./config.sh \
      --unattended \
      --url "https://github.com/${RUNNER_REPO}" \
      --token "${token}" \
      --name "$(hostname -s)" \
      --replace
  ) || die "config.sh failed"
}

main() {
  check_requirements
  download_runner
  register_runner

  log "done. next: make sync && make install && make start"
  printf '\nAlso set the power policy, which is not the runner'\''s to own:\n'
  printf '  sudo pmset -c sleep 0 disksleep 0\n'
}

main "$@"
