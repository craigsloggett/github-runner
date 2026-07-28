#!/bin/sh
#
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED. Runs synchronously after the last step.
#
# Best-effort, and always exits 0: the job's result is already decided, and a
# failure here would add noise without adding information. Everything
# load-bearing lives in job-started.sh, which is the hook guaranteed to run.
#
# Purpose is to give the disk back promptly and leave behind no credential and
# no mounted image. Explicitly not: anything the next job depends on.

set -uf

provisioning_dir="$(cd -P "$(dirname "$0")/.." && pwd)"

# shellcheck source=SCRIPTDIR/../config.sh
. "${provisioning_dir}/config.sh"

workspace="${GITHUB_WORKSPACE:-}"

# discard_build_outputs frees the products of this job while keeping the caches
# that make the next one fast. SourcePackages and ModuleCache.noindex stay.
#
# The wildcard removals go through find because this script runs under `set -f`,
# where a shell glob would not expand and would silently match nothing.
discard_build_outputs() {
  [ -n "${workspace}" ] || return 0

  if [ -d "${workspace}/build" ]; then
    rm -rf \
      "${workspace}/build/Build" \
      "${workspace}/build/Export" \
      "${workspace}/build/Logs" 2>/dev/null || :
    find "${workspace}/build" -mindepth 1 -maxdepth 1 -name '*.xcarchive' \
      -exec rm -rf {} + 2>/dev/null || :
  fi

  find "${workspace}" -mindepth 1 -maxdepth 1 -name '*.dmg' \
    -exec rm -f {} + 2>/dev/null || :
}

# scrub_checkout_credential removes any job token actions/checkout persisted
# into the local git config, so it does not sit on disk between jobs.
scrub_checkout_credential() {
  [ -n "${workspace}" ] || return 0
  [ -d "${workspace}/.git" ] || return 0
  git -C "${workspace}" config --local --remove-section 'http.https://github.com/' 2>/dev/null || :
}

# detach_stale_images unmounts anything a release job left attached.
detach_stale_images() {
  [ -d "${RUNNER_ROOT}/tmp" ] || return 0

  hdiutil info 2>/dev/null | grep -o "${RUNNER_ROOT}/tmp/[^[:space:]]*" | sort -u |
    while read -r mount_point; do
      hdiutil detach "${mount_point}" -force -quiet 2>/dev/null || :
    done
}

discard_build_outputs
scrub_checkout_credential
detach_stale_images

exit 0
