#!/bin/sh
#
# launchd entry point for the GitHub Actions runner. Owns every environment
# decision for the runner and, by inheritance, for every job step.
#
# Why this file exists instead of edits to runsvc.sh: the runner rewrites its
# own runsvc.sh on each self-update (_work/_update.sh does
# `cat "${rootfolder}/bin/runsvc.sh" > "${rootfolder}/runsvc.sh"`), and
# `svc.sh install` re-copies it from bin/. Anything written into runsvc.sh is
# destroyed on the next update; see actions/runner#4177. Nothing upstream
# touches this file.
#
# Why the final exec uses an absolute path: that same _update.sh locates the
# service's process group with
#   ps x -o pgid,command | grep "${rootfolder}/runsvc.sh"
# to apply the macOS node-relaunch fix (actions/runner#743). exec replaces this
# shell, so the surviving command line must contain the absolute path or that
# branch silently no-ops.

set -euf

provisioning_dir="$(cd -P "$(dirname "$0")" && pwd)"

# shellcheck source=config.sh
. "${provisioning_dir}/config.sh"

cd "${RUNNER_ROOT}" || exit 1

# Scrub what the surrounding session would otherwise hand to every job.
#
# SSH_AUTH_SOCK is the only variable launchd actually injects here; it is the
# sole entry in `launchctl print gui/<uid>`, published by com.openssh.ssh-agent
# as a domain-wide secure key. A plist EnvironmentVariables dict can overwrite a
# variable but not unset one, so it has to happen in a wrapper.
#
# The rest of the list is insurance against this ever being launched from an
# interactive shell again, where GNUPGHOME, PASSWORD_STORE_DIR and the terminal
# variables do arrive. hooks/job-started.sh asserts the result, so the list is a
# checked invariant rather than a hope.
leaked_variables="
  SSH_AUTH_SOCK SSH_AGENT_PID
  GNUPGHOME GPG_TTY GPG_AGENT_INFO
  PASSWORD_STORE_DIR PASSWORD_STORE_GPG_OPTS
  ZDOTDIR ENV BASH_ENV
  VIMINIT MYVIMRC EDITOR VISUAL PAGER RPROMPT
  GOPATH GOROOT GOBIN GEM_HOME GEM_PATH RUBYOPT
  NODE_OPTIONS NPM_CONFIG_PREFIX NPM_CONFIG_USERCONFIG PYTHONPATH PYTHONHOME
  XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
  TERMINFO TERMINFO_DIRS TERM_PROGRAM TERM_PROGRAM_VERSION
  GHOSTTY_BIN_DIR GHOSTTY_RESOURCES_DIR GHOSTTY_SHELL_FEATURES
  GH_TOKEN GITHUB_TOKEN AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE TF_CLI_CONFIG_FILE
"
for leaked in ${leaked_variables}; do
  unset "${leaked}" || :
done

export LANG=en_CA.UTF-8

# Set rather than unset: tput, less and ncurses misbehave with TERM absent.
export TERM=dumb

# xcode-select is global mutable state a job could change under a later job.
export DEVELOPER_DIR

# GIT_CONFIG_GLOBAL replaces both ~/.gitconfig and ~/.config/git/config. The
# real config on this host is the XDG one, a symlink into a live dotfiles
# checkout, and it sets commit.gpgSign and user.signingKey; without this every
# `git commit` in a job would try to reach the GPG agent. NOSYSTEM covers
# /etc/gitconfig and /opt/homebrew/etc/gitconfig.
GIT_CONFIG_GLOBAL="${provisioning_dir}/etc/gitconfig"
export GIT_CONFIG_GLOBAL
export GIT_CONFIG_NOSYSTEM=1

# No job may upgrade the toolchain out from under a later job.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1

# Keep transient build state off the shared per-user /var/folders temp, which
# the desktop session also uses and which nothing here may prune. hark's
# Scripts/dmg.sh mktemp -d's into TMPDIR and its EXIT trap does not survive
# SIGKILL, so a cancelled release leaves a mounted image behind.
TMPDIR="${RUNNER_ROOT}/tmp"
export TMPDIR
mkdir -p "${TMPDIR}"
chmod 700 "${TMPDIR}"

# Hook paths live here rather than in .env so that one version-controlled file
# holds every environment decision, with no runner-restart semantics involved.
ACTIONS_RUNNER_HOOK_JOB_STARTED="${provisioning_dir}/hooks/job-started.sh"
ACTIONS_RUNNER_HOOK_JOB_COMPLETED="${provisioning_dir}/hooks/job-completed.sh"
export ACTIONS_RUNNER_HOOK_JOB_STARTED
export ACTIONS_RUNNER_HOOK_JOB_COMPLETED

exec "${RUNNER_ROOT}/runsvc.sh"
