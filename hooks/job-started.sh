#!/bin/sh
#
# ACTIONS_RUNNER_HOOK_JOB_STARTED. Runs synchronously after a job is assigned
# and before its first step. A non-zero exit fails the job before any step runs,
# which is the point: a mis-provisioned runner should fail in two seconds with a
# named reason rather than twenty-five minutes into `make notarize`.
#
# The destructive workspace reset lives here rather than in job-completed.sh
# because the hark workflows set concurrency.cancel-in-progress, so cancellation
# is the normal outcome for a superseded push, and a killed worker never runs
# the completed hook. This is the only hook guaranteed to run before work
# happens.

set -euf

# Capture what the job actually inherited before config.sh overwrites the
# expected values with its own.
inherited_developer_dir="${DEVELOPER_DIR:-}"

provisioning_dir="$(cd -P "$(dirname "$0")/.." && pwd)"

# shellcheck source=SCRIPTDIR/../config.sh
. "${provisioning_dir}/config.sh"

workspace="${GITHUB_WORKSPACE:-}"

# Directories under the Xcode derived data path that survive a reset. Everything
# else there is a build output. ModuleCache.noindex in particular is the
# difference between a warm and a cold Swift build, so it is worth keeping even
# though it is regenerable. spm-cache is where hark's `make ios-check` puts the
# SwiftPM cache it would otherwise share with interactive Xcode.
KEEP_IN_BUILD_DIR="SourcePackages ModuleCache.noindex SDKStatCaches.noindex CompilationCache.noindex spm-cache"

# Variables that must not survive into a job. Each one is either a live
# credential channel or interactive-shell state that would make a build
# non-reproducible.
SCRUBBED_VARIABLES="
  SSH_AUTH_SOCK GNUPGHOME GPG_TTY PASSWORD_STORE_DIR ZDOTDIR
  BASH_ENV ENV VIMINIT GOPATH NODE_OPTIONS GH_TOKEN AWS_ACCESS_KEY_ID
"

# die reports a preflight failure as a workflow annotation and aborts the job.
die() {
  printf '::error title=Runner preflight::%s\n' "$1"
  exit 1
}

# warn reports a non-fatal preflight observation as a workflow annotation.
warn() {
  printf '::warning title=Runner preflight::%s\n' "$1"
}

# assert_environment_scrubbed confirms runner-service.sh removed the ambient
# credentials and interactive-shell state that would otherwise reach the job.
assert_environment_scrubbed() {
  for name in ${SCRUBBED_VARIABLES}; do
    eval "value=\${${name}:-}"
    if [ -n "${value}" ]; then
      die "${name} is set in the job environment; runner-service.sh did not scrub it"
    fi
  done

  case ":${PATH}:" in
    *Ghostty* | */pkg/env/* | */.cache/go/*)
      die "PATH carries interactive-shell entries; fix ${RUNNER_ROOT}/.path: ${PATH}"
      ;;
  esac
}

# assert_toolchain confirms the job will build against the pinned Xcode and a
# git configuration that cannot reach the user's signing key.
assert_toolchain() {
  if [ "${inherited_developer_dir}" != "${DEVELOPER_DIR}" ]; then
    die "DEVELOPER_DIR is ${inherited_developer_dir:-unset}, expected ${DEVELOPER_DIR}"
  fi

  # --bool normalises the value, and the default matters: etc/gitconfig sets
  # commit.gpgSign explicitly to false, so testing for presence rather than
  # truth would fail every job.
  if [ "$(git config --bool --get commit.gpgsign 2>/dev/null || printf 'false')" = "true" ]; then
    die "commit.gpgsign is true; the user gitconfig is leaking past GIT_CONFIG_GLOBAL"
  fi
}

# count_processes reports how many processes match a full-command-line pattern.
#
# ps rather than pgrep: pgrep -f reads each process's argument vector, and from
# inside a job that read comes back empty, so it matches nothing and reports
# zero even for the listener that spawned this hook. `ps -Ao command=` is not
# affected. grep -c also avoids BSD pgrep's missing -c.
count_processes() (
  pattern="${1:?pattern is required}"
  # SC2009 recommends pgrep, which is exactly what does not work here.
  # shellcheck disable=SC2009
  ps -Ao command= | grep -c "${pattern}" || :
)

# assert_single_runner warns about a second listener racing this one, which
# would corrupt the shared build tree.
#
# A count of zero means the process table could not be read, not that the
# listener running this very hook has vanished, so it warns rather than fails:
# a preflight that cannot observe its precondition must not take CI down over
# it. Only a genuine second listener is worth failing for.
assert_single_runner() {
  listeners="$(count_processes 'Runner\.Listener run')"

  if [ "${listeners}" -eq 0 ]; then
    warn "could not observe the runner process table; skipping the single-runner check"
  elif [ "${listeners}" -gt 1 ]; then
    die "${listeners} Runner.Listener processes are running; a second runner would corrupt the shared build tree"
  fi

  workers="$(count_processes 'Runner\.Worker')"
  if [ "${workers}" -gt 1 ]; then
    warn "${workers} Runner.Worker processes are alive; check for wedged workers (actions/runner#4575)"
  fi
}

# assert_signing_available confirms the private key behind the Developer ID
# identity is actually usable from this launchd session.
#
# It signs a throwaway binary rather than just listing identities, because
# `security find-identity` succeeds even when the keychain is unreachable:
# measured on macOS 26.6, a LaunchAgent with SessionCreate=true lists the
# identity happily and then fails codesign with errSecInternalComponent and
# notarytool with keychainLocked. Listing is not a reachability test. Signing is,
# it costs about fifty milliseconds, and it needs no network.
#
# Absence of the identity only warns: that is certificate expiry rather than a
# broken runner, it does not affect test jobs, and `make notarize` reports it
# far more precisely.
assert_signing_available() {
  # Sign by certificate hash, not by team ID: the Developer ID Application and
  # Apple Distribution certificates share a team ID, so `--sign <team>` is an
  # ambiguous match and fails for a reason that has nothing to do with the
  # keychain.
  identity_hash="$(security find-identity -v -p codesigning 2>/dev/null |
    grep 'Developer ID Application' | grep "${TEAM_ID}" | head -1 |
    awk '{ print $2 }')"

  if [ -z "${identity_hash}" ]; then
    warn "no Developer ID Application identity for team ${TEAM_ID}; release jobs will fail to sign"
    return 0
  fi

  probe_dir="$(mktemp -d)"
  cp /bin/echo "${probe_dir}/probe"
  codesign --force --timestamp=none --options runtime \
    --sign "${identity_hash}" "${probe_dir}/probe" >/dev/null 2>&1
  signed=$?
  rm -rf "${probe_dir}"

  if [ "${signed}" -ne 0 ]; then
    die "the login keychain is unreachable from this session: codesign failed with an identity that is present. Check SessionCreate in the LaunchAgent plist (actions/runner#3407)"
  fi
}

# assert_disk_space fails early rather than part-way through a build.
assert_disk_space() {
  available="$(df -g "${workspace:-${RUNNER_ROOT}}" | awk 'NR == 2 { print $4 }')"
  if [ "${available:-0}" -lt "${MIN_FREE_GIB}" ]; then
    die "only ${available:-0}GiB free on the work volume, ${MIN_FREE_GIB}GiB required"
  fi
}

# warn_toolchain_drift compares Homebrew formulae against the recorded manifest.
# This warns rather than fails: drift is worth knowing about, but a formula bump
# should not take CI down on its own.
warn_toolchain_drift() {
  manifest="${provisioning_dir}/etc/tool-versions"
  [ -f "${manifest}" ] || return 0
  command -v brew >/dev/null 2>&1 || return 0

  while read -r formula pinned; do
    case "${formula}" in
      '' | '#'*) continue ;;
    esac
    actual="$(brew list --versions "${formula}" 2>/dev/null | cut -d' ' -f2 || :)"
    if [ "${actual}" != "${pinned}" ]; then
      warn "${formula} is ${actual:-absent}, manifest pins ${pinned}"
    fi
  done <"${manifest}"
}

# detach_stale_images unmounts disk images left behind by a killed release job.
# hark's Scripts/dmg.sh traps EXIT, but a SIGKILLed worker never runs the trap.
detach_stale_images() {
  [ -d "${RUNNER_ROOT}/tmp" ] || return 0

  hdiutil info 2>/dev/null | grep -o "${RUNNER_ROOT}/tmp/[^[:space:]]*" | sort -u |
    while read -r mount_point; do
      hdiutil detach "${mount_point}" -force -quiet 2>/dev/null || :
    done

  find "${RUNNER_ROOT}/tmp" -maxdepth 1 -mindepth 1 -mtime +0 -exec rm -rf {} + 2>/dev/null || :
}

# reset_workspace clears the previous job's build outputs by keep-list.
#
# Deliberately not `git clean -xdf`: that would delete
# build/SourcePackages/{artifacts,repositories,workspace-state.json}, which is
# exactly the state being kept, while skipping build/SourcePackages/checkouts/*
# because those are nested git repositories. A keep-list also survives a future
# Xcode adding an output directory.
# Enumerated with find rather than a glob: this script runs under `set -f`, so
# shell globs do not expand and a `build/*` loop would silently do nothing.
reset_workspace() {
  [ -n "${workspace}" ] || return 0
  [ -d "${workspace}/build" ] || return 0

  find "${workspace}/build" -mindepth 1 -maxdepth 1 |
    while read -r entry; do
      if ! is_kept "${entry##*/}"; then
        rm -rf "${entry}"
      fi
    done
}

# is_kept reports whether a derived data entry survives reset_workspace.
is_kept() (
  candidate="${1:?entry name is required}"
  for keeper in ${KEEP_IN_BUILD_DIR}; do
    if [ "${candidate}" = "${keeper}" ]; then
      return 0
    fi
  done
  return 1
)

# scrub_checkout_credential removes any job token actions/checkout persisted
# into the local git config. Its post step normally removes this, but a
# cancelled job skips post steps, and the next job must not build on top of a
# previous job's credential.
scrub_checkout_credential() {
  [ -n "${workspace}" ] || return 0
  [ -d "${workspace}/.git" ] || return 0
  git -C "${workspace}" config --local --remove-section 'http.https://github.com/' 2>/dev/null || :
}

main() {
  assert_environment_scrubbed
  assert_toolchain
  assert_single_runner
  assert_signing_available
  assert_disk_space
  warn_toolchain_drift

  detach_stale_images
  reset_workspace
  scrub_checkout_credential
}

main "$@"
