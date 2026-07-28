#!/bin/sh
#
# Machine-specific values for a self-hosted macOS runner. Sourced by every
# other script here and by the Makefile. This is the only file that should need
# editing to point the provisioning at a different host, repo, or signing team.

# Every assignment below is read by a sourcing script, never by this file, so
# each one looks unused to the linter. Disabling SC2034 file-wide is the trade:
# the alternative is exporting values that have no business in a job's
# environment.
# shellcheck disable=SC2034

# Where config.sh unpacked the runner. Everything else is derived from it.
RUNNER_ROOT="${RUNNER_ROOT:-${HOME}/.local/share/github-runner}"

# Where `make sync` installs this repo's files, kept in a subdirectory so it
# cannot collide with the runner's own bin/ and externals/ symlinks.
PROVISIONING_DIR="${RUNNER_ROOT}/provisioning"

# The repository the runner is registered against.
RUNNER_REPO="craigsloggett/hark"

# launchd label. svc.sh derives this same string from the repo and runner name;
# it must match or `make status` will not find the service.
SVC_NAME="actions.runner.craigsloggett-hark.macOS-arm64"

# Signing. The Developer ID identity and the notarytool credential both live in
# the login keychain, which is why the runner stays a LaunchAgent owned by the
# logged-in user rather than a daemon or a separate service account.
TEAM_ID="5HNVP484ZA"
NOTARY_PROFILE="hark-notary"

# Pinned toolchain. Jobs must not depend on whatever xcode-select points at.
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

# Housekeeping windows, in days.
DIAG_RETENTION_DAYS=14
ACTIONS_RETENTION_DAYS=30

# A Runner.Worker alive longer than this with an idle listener is wedged rather
# than busy. Keep it above the longest job timeout in the workflows, currently
# 60 minutes for the release build.
WORKER_REAP_MINUTES=90

# Free space below this many GiB fails the job in preflight instead of part-way
# through an Xcode build.
MIN_FREE_GIB=20
