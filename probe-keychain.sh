#!/bin/sh
#
# Decides the SessionCreate value for the runner's LaunchAgent, before the
# runner is migrated to one.
#
# The question this answers: does a LaunchAgent spawned into its own security
# audit session (SessionCreate=true, which is what upstream's template ships)
# still reach the login keychain on this macOS version? Upstream added true to
# fix keychain access on macOS 11 (actions/runner#847); macOS 15 and 26 reports
# say it now breaks it (actions/runner#3407). Getting this wrong breaks release
# signing, so it is measured rather than assumed.
#
# Runs the same probe three ways and diffs them: under a throwaway LaunchAgent
# with SessionCreate true, the same with false, and directly from the invoking
# shell as a known-good control.
#
# Touches nothing belonging to the runner.

set -euf

provisioning_dir="$(cd -P "$(dirname "$0")" && pwd)"

# shellcheck source=config.sh
. "${provisioning_dir}/config.sh"

PROBE_LABEL="local.github-runner.keychain-probe"
PROBE_DIR="${TMPDIR:-/tmp}/github-runner-keychain-probe"

# run_probe performs the actual measurements. Invoked both by launchd (via the
# throwaway plist) and directly for the control run.
run_probe() {
  printf 'user=%s(%s)\n' "$(id -un)" "$(id -u)"
  printf 'keychain-search-list=%s\n' "$(/usr/bin/security list-keychains -d user 2>&1 | tr -d ' \n')"

  printf 'find-identity: '
  if /usr/bin/security find-identity -v -p codesigning 2>&1 | grep -q "${TEAM_ID}"; then
    printf 'OK (%s present)\n' "${TEAM_ID}"
  else
    printf 'FAIL\n%s\n' "$(/usr/bin/security find-identity -v -p codesigning 2>&1)"
  fi

  printf 'codesign: '
  probe_bin="$(mktemp -d)/probe"
  cp /bin/echo "${probe_bin}"
  if /usr/bin/codesign --force --timestamp=none --options runtime \
    --sign "Developer ID Application: Douglas Craig Sloggett (${TEAM_ID})" \
    "${probe_bin}" >/dev/null 2>&1; then
    printf 'OK\n'
  else
    printf 'FAIL rc=%s\n' "$?"
    /usr/bin/codesign --force --timestamp=none --options runtime \
      --sign "Developer ID Application: Douglas Craig Sloggett (${TEAM_ID})" \
      "${probe_bin}" 2>&1 | sed 's/^/  /'
  fi
  rm -rf "$(dirname "${probe_bin}")"

  # The notary credential is a generic-password item, a different ACL path from
  # the private key codesign uses. Testing only codesign would miss a break here.
  printf 'notarytool: '
  if /usr/bin/xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
    printf 'OK\n'
  else
    printf 'FAIL\n%s\n' "$(/usr/bin/xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" 2>&1 | sed 's/^/  /')"
  fi

  # hark's test bundle is app-hosted, so `make test` launches a real
  # NSApplication and needs a WindowServer connection, not just a keychain.
  printf 'windowserver: '
  if /usr/bin/osascript -e 'tell application "System Events" to count processes' >/dev/null 2>&1; then
    printf 'OK\n'
  else
    printf 'FAIL\n'
  fi
}

# write_probe_plist emits a throwaway LaunchAgent mirroring the real one's
# session-relevant keys, with SessionCreate set to the given value.
write_probe_plist() (
  session_create="${1:?session_create is required}"
  destination="${2:?destination is required}"

  cat >"${destination}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>${PROBE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
      <string>${provisioning_dir}/probe-keychain.sh</string>
      <string>--probe</string>
    </array>
    <key>WorkingDirectory</key><string>${provisioning_dir}</string>
    <key>ProcessType</key><string>Interactive</string>
    <key>SessionCreate</key><${session_create}/>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>${PROBE_DIR}/${session_create}.log</string>
    <key>StandardErrorPath</key><string>${PROBE_DIR}/${session_create}.log</string>
  </dict>
</plist>
PLIST
)

# probe_under_launchd loads the throwaway agent, waits for it to finish, and
# prints what it measured.
probe_under_launchd() (
  session_create="${1:?session_create is required}"
  plist="${PROBE_DIR}/${PROBE_LABEL}.plist"
  log="${PROBE_DIR}/${session_create}.log"

  rm -f "${log}"
  write_probe_plist "${session_create}" "${plist}"

  launchctl bootout "gui/$(id -u)/${PROBE_LABEL}" 2>/dev/null || :
  launchctl bootstrap "gui/$(id -u)" "${plist}" ||
    die "could not bootstrap the probe agent"

  waited=0
  while [ ! -s "${log}" ] && [ "${waited}" -lt 60 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  sleep 2

  launchctl bootout "gui/$(id -u)/${PROBE_LABEL}" 2>/dev/null || :

  printf '\n===== SessionCreate=%s (LaunchAgent) =====\n' "${session_create}"
  if [ -s "${log}" ]; then
    cat "${log}"
  else
    printf 'no output after %ss; the agent did not run\n' "${waited}"
  fi
)

# die reports a fatal error and aborts.
die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# cleanup removes the throwaway agent and its scratch directory.
cleanup() {
  launchctl bootout "gui/$(id -u)/${PROBE_LABEL}" 2>/dev/null || :
  rm -rf "${PROBE_DIR}"
}

main() {
  trap cleanup EXIT INT TERM HUP
  mkdir -p "${PROBE_DIR}"

  printf '===== control (this shell) =====\n'
  run_probe

  probe_under_launchd true
  probe_under_launchd false

  printf '\nCompare the three blocks. Set SessionCreate in\n'
  printf 'launchd/actions.runner.plist.template to whichever value matches the control.\n'
}

case "${1:-}" in
  --probe) run_probe ;;
  *) main "$@" ;;
esac
