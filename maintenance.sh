#!/bin/sh
#
# Machine-scoped housekeeping for the runner, run daily by a LaunchAgent.
#
# Separate from the job hooks because hooks only run when jobs run, which is the
# wrong cadence for disk: an idle runner never prunes and a busy one prunes
# dozens of times a day. Anything job-scoped belongs in hooks/, anything
# host-scoped belongs here.
#
# Refuses to run while a job is in flight so it can never race a build.

set -euf

provisioning_dir="$(cd -P "$(dirname "$0")" && pwd)"

# shellcheck source=config.sh
. "${provisioning_dir}/config.sh"

SERVICE_LOG_DIR="${HOME}/Library/Logs/${SVC_NAME}"

# Rotate the service log once it passes this many bytes. The runner writes every
# listener line to stdout forever; becoming a service creates this growth and
# nothing upstream rotates it.
SERVICE_LOG_MAX_BYTES=10485760

# log prints a timestamped progress line.
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1"
}

# runner_is_busy reports whether a job is currently executing.
runner_is_busy() (
  count="$(pgrep -f 'Runner\.Worker' | wc -l | tr -d ' ')"
  [ "${count}" -gt 0 ]
)

# prune_diagnostic_logs trims the runner's own _diag directory. The runner has
# no retention setting, so this is the only thing bounding it. Files still open
# for writing have current mtimes and are never in range.
prune_diagnostic_logs() {
  [ -d "${RUNNER_ROOT}/_diag" ] || return 0
  log "pruning _diag older than ${DIAG_RETENTION_DAYS} days"
  find "${RUNNER_ROOT}/_diag" -type f -name '*.log' \
    -mtime "+${DIAG_RETENTION_DAYS}" -delete 2>/dev/null || :
  find "${RUNNER_ROOT}/_diag" -type f -name '*.log.succeed' \
    -mtime "+${DIAG_RETENTION_DAYS}" -delete 2>/dev/null || :
}

# rotate_service_logs truncates the LaunchAgent's stdout and stderr once they
# grow past the cap, keeping one previous generation.
rotate_service_logs() {
  [ -d "${SERVICE_LOG_DIR}" ] || return 0

  for stream in stdout stderr; do
    log_file="${SERVICE_LOG_DIR}/${stream}.log"
    [ -f "${log_file}" ] || continue

    size="$(wc -c <"${log_file}" | tr -d ' ')"
    if [ "${size}" -gt "${SERVICE_LOG_MAX_BYTES}" ]; then
      log "rotating ${stream}.log (${size} bytes)"
      mv -f "${log_file}" "${log_file}.1"
      # Truncate in place rather than recreating: launchd holds the descriptor
      # it opened at load time, so a new inode would silently receive nothing.
      : >"${log_file}"
    fi
  done
}

# prune_superseded_runner_versions removes old bin.<version> and
# externals.<version> trees, keeping the live one and the most recent previous
# one. That previous version is the documented rollback for a bad self-update,
# so it is deliberately not reclaimed.
prune_superseded_runner_versions() {
  for prefix in bin externals; do
    # readlink returns an absolute path on macOS while find -name matches only
    # the basename, so the target must be reduced before it can exclude
    # anything. Passing the full path silently excludes nothing, which puts the
    # live version into the candidate list and deletes the rollback instead.
    link_target="$(readlink "${RUNNER_ROOT}/${prefix}" 2>/dev/null || :)"
    current="${link_target##*/}"

    if [ -z "${current}" ]; then
      log "cannot resolve the ${prefix} symlink; skipping version prune"
      continue
    fi

    # Newest first by mtime, excluding the live one, then skip the most recent
    # survivor: that is the rollback. Everything below it is dead weight.
    find "${RUNNER_ROOT}" -maxdepth 1 -type d -name "${prefix}.*" \
      ! -name "${current}" -exec stat -f '%m %N' {} + 2>/dev/null |
      sort -rn |
      tail -n +2 |
      cut -d' ' -f2- |
      while read -r stale; do
        log "removing superseded ${stale##*/}"
        rm -rf "${stale}"
      done
  done
}

# prune_update_staging removes the staged copy left behind by a completed
# self-update. The runner recreates it on the next update.
prune_update_staging() {
  [ -d "${RUNNER_ROOT}/_work/_update" ] || return 0
  if [ -n "$(find "${RUNNER_ROOT}/_work/_update" -maxdepth 0 -mtime +1 2>/dev/null || :)" ]; then
    log "removing stale _work/_update staging"
    rm -rf "${RUNNER_ROOT}/_work/_update"
  fi
}

# prune_downloaded_actions trims cached action checkouts that have not been used
# in a long time. The runner re-downloads whatever a workflow still references.
prune_downloaded_actions() {
  [ -d "${RUNNER_ROOT}/_work/_actions" ] || return 0
  log "pruning _work/_actions older than ${ACTIONS_RETENTION_DAYS} days"
  find "${RUNNER_ROOT}/_work/_actions" -mindepth 3 -maxdepth 3 -type d \
    -mtime "+${ACTIONS_RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null || :
}

# prune_runner_temp clears the private temp directory runner-service.sh points
# jobs at, including disk images a killed release job left behind.
prune_runner_temp() {
  [ -d "${RUNNER_ROOT}/tmp" ] || return 0
  find "${RUNNER_ROOT}/tmp" -maxdepth 1 -mindepth 1 -mtime +1 \
    -exec rm -rf {} + 2>/dev/null || :
}

# reap_wedged_workers kills Runner.Worker processes that outlived any plausible
# job while the listener sits idle. This is the only mitigation available for
# actions/runner#4570 and #4575, where the worker wedges at 100% CPU and the
# listener stays healthy, so neither KeepAlive nor the job hooks ever fire.
reap_wedged_workers() {
  pgrep -f 'Runner\.Worker' |
    while read -r pid; do
      elapsed_minutes="$(ps -o etime= -p "${pid}" 2>/dev/null | tr -d ' ' | to_minutes)"
      [ -n "${elapsed_minutes}" ] || continue
      if [ "${elapsed_minutes}" -gt "${WORKER_REAP_MINUTES}" ]; then
        log "reaping wedged Runner.Worker pid ${pid} (${elapsed_minutes}m old)"
        kill -9 "${pid}" 2>/dev/null || :
      fi
    done
}

# to_minutes converts a ps etime value on stdin to whole minutes. etime is
# [[dd-]hh:]mm:ss, so the fields are parsed from the right.
to_minutes() {
  awk -F'[-:]' '
    {
      if (NF == 2)      { minutes = $1 }
      else if (NF == 3) { minutes = $1 * 60 + $2 }
      else if (NF == 4) { minutes = $1 * 1440 + $2 * 60 + $3 }
      else              { minutes = 0 }
      print int(minutes)
    }
  '
}

main() {
  if runner_is_busy; then
    log "a job is running; skipping maintenance"
    return 0
  fi

  prune_diagnostic_logs
  rotate_service_logs
  prune_superseded_runner_versions
  prune_update_staging
  prune_downloaded_actions
  prune_runner_temp
  reap_wedged_workers

  log "maintenance complete"
}

main "$@"
