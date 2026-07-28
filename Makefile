# Provisioning for a self-hosted macOS GitHub Actions runner.
#
# The runner tree itself is not in this repo. `sync` copies this repo's files
# into <runner root>/provisioning/, and `install` points a LaunchAgent at them.

SHELL := /bin/sh

# Read the machine-specific values from the single source rather than repeating
# them here.
RUNNER_ROOT      := $(shell . ./config.sh && printf '%s' "$${RUNNER_ROOT}")
PROVISIONING_DIR := $(shell . ./config.sh && printf '%s' "$${PROVISIONING_DIR}")
SVC_NAME         := $(shell . ./config.sh && printf '%s' "$${SVC_NAME}")
RUNNER_REPO      := $(shell . ./config.sh && printf '%s' "$${RUNNER_REPO}")
TEAM_ID          := $(shell . ./config.sh && printf '%s' "$${TEAM_ID}")

LAUNCH_AGENTS  := $(HOME)/Library/LaunchAgents
SERVICE_PLIST  := $(LAUNCH_AGENTS)/$(SVC_NAME).plist
MAINT_LABEL    := $(SVC_NAME).maintenance
MAINT_PLIST    := $(LAUNCH_AGENTS)/$(MAINT_LABEL).plist

# Files copied into the runner root. Deliberately excludes the Makefile, README
# and launchd templates, which are authoring-time only.
SYNCED := config.sh runner-service.sh maintenance.sh probe-keychain.sh hooks etc

SCRIPTS := config.sh runner-service.sh maintenance.sh probe-keychain.sh \
           hooks/job-started.sh hooks/job-completed.sh

# Signed in place after sync. Only the executables: signing is what stops
# System Settings listing the launchd agents as coming from an unidentified
# developer, and signing the installed copies rather than the repo means an
# edit here can never leave a stale signature behind.
INSTALLED_SCRIPTS := $(PROVISIONING_DIR)/runner-service.sh \
                     $(PROVISIONING_DIR)/maintenance.sh \
                     $(PROVISIONING_DIR)/probe-keychain.sh \
                     $(PROVISIONING_DIR)/hooks/job-started.sh \
                     $(PROVISIONING_DIR)/hooks/job-completed.sh

.DEFAULT_GOAL := help
.PHONY: help lint format sync sign check install uninstall start stop status \
        probe-keychain record-versions reclaim

help:
	@printf 'Targets:\n'
	@printf '  lint            shellcheck and shfmt --diff every script\n'
	@printf '  format          shfmt -w every script\n'
	@printf '  sync            copy provisioning files into the runner root\n'
	@printf '  check           diff installed provisioning against this repo\n'
	@printf '  probe-keychain  decide SessionCreate before installing (run first)\n'
	@printf '  install         install the runner and maintenance LaunchAgents\n'
	@printf '  start / stop    load and unload the runner service\n'
	@printf '  status          service state and recent exit code\n'
	@printf '  uninstall       remove both LaunchAgents, leaving registration intact\n'
	@printf '  record-versions refresh etc/tool-versions from Homebrew\n'
	@printf '  reclaim         report reclaimable disk under the runner root\n'

# Quality

lint:
	shellcheck -x $(SCRIPTS)
	shfmt -i 2 -ci -s --diff $(SCRIPTS)

format:
	shfmt -i 2 -ci -s -w $(SCRIPTS)

# Installation

sync:
	@test -d "$(RUNNER_ROOT)" || { printf 'runner root %s does not exist\n' "$(RUNNER_ROOT)" >&2; exit 1; }
	mkdir -p "$(PROVISIONING_DIR)"
	# Copy rather than symlink: this repo is a live checkout, and a `git pull`
	# must not be able to change a running service mid-job.
	cp -R $(SYNCED) "$(PROVISIONING_DIR)/"
	chmod +x "$(PROVISIONING_DIR)/runner-service.sh" \
	         "$(PROVISIONING_DIR)/maintenance.sh" \
	         "$(PROVISIONING_DIR)/probe-keychain.sh" \
	         "$(PROVISIONING_DIR)/hooks/job-started.sh" \
	         "$(PROVISIONING_DIR)/hooks/job-completed.sh"
	# runsvc.sh reads .path at every service start, so this is the job PATH.
	# Never regenerate it with the runner's env.sh, which captures whatever
	# interactive shell it was run from.
	cp etc/path "$(RUNNER_ROOT)/.path"
	@printf 'synced to %s\n' "$(PROVISIONING_DIR)"
	@$(MAKE) --no-print-directory sign
	@$(MAKE) --no-print-directory check

# Best effort by design: an expired or absent certificate should leave a
# cosmetic warning, not block a runner from being provisioned.
sign:
	@identity="$$(security find-identity -v -p codesigning 2>/dev/null \
	  | grep 'Developer ID Application' | grep '$(TEAM_ID)' | head -1 | awk '{ print $$2 }')"; \
	if [ -z "$${identity}" ]; then \
	  printf 'warning: no Developer ID identity for team %s; scripts left unsigned\n' '$(TEAM_ID)' >&2; \
	  exit 0; \
	fi; \
	for script in $(INSTALLED_SCRIPTS); do \
	  codesign --force --sign "$${identity}" --timestamp "$${script}" 2>/dev/null \
	    || printf 'warning: could not sign %s\n' "$${script}" >&2; \
	done; \
	printf 'signed the installed scripts\n'

# Non-zero on drift, and run as the last step of sync. A sync that reports
# success while leaving a stale hook in place is the worst failure mode here:
# every job would keep running old code with nothing to show for it.
check:
	@drift=0; \
	for item in $(SYNCED); do \
	  diff -r "$${item}" "$(PROVISIONING_DIR)/$${item}" >/dev/null 2>&1 \
	    || { printf 'DRIFT: %s\n' "$${item}" >&2; drift=1; }; \
	done; \
	diff etc/path "$(RUNNER_ROOT)/.path" >/dev/null 2>&1 \
	  || { printf 'DRIFT: .path\n' >&2; drift=1; }; \
	if [ "$${drift}" -ne 0 ]; then \
	  printf 'installed provisioning does not match this repo\n' >&2; \
	  exit 1; \
	fi; \
	printf 'installed provisioning matches this repo\n'

probe-keychain:
	./probe-keychain.sh

install: sync
	@test ! -f "$(SERVICE_PLIST)" || { printf 'already installed: %s\n' "$(SERVICE_PLIST)" >&2; exit 1; }
	cd "$(RUNNER_ROOT)" && \
	  GITHUB_ACTIONS_RUNNER_SERVICE_TEMPLATE="$(CURDIR)/launchd/actions.runner.plist.template" \
	  ./svc.sh install
	plutil -lint "$(SERVICE_PLIST)"
	mkdir -p "$(LAUNCH_AGENTS)"
	sed -e 's|{{SvcName}}|$(SVC_NAME)|g' \
	    -e 's|{{RunnerRoot}}|$(RUNNER_ROOT)|g' \
	    -e 's|{{UserHome}}|$(HOME)|g' \
	    launchd/maintenance.plist.template > "$(MAINT_PLIST)"
	plutil -lint "$(MAINT_PLIST)"
	launchctl bootout "gui/$(shell id -u)/$(MAINT_LABEL)" 2>/dev/null || true
	launchctl bootstrap "gui/$(shell id -u)" "$(MAINT_PLIST)"
	@printf 'installed. run `make start` to load the runner service.\n'

uninstall: stop
	cd "$(RUNNER_ROOT)" && ./svc.sh uninstall || true
	launchctl bootout "gui/$(shell id -u)/$(MAINT_LABEL)" 2>/dev/null || true
	rm -f "$(MAINT_PLIST)"
	@printf 'uninstalled. the runner registration is untouched.\n'

start:
	cd "$(RUNNER_ROOT)" && ./svc.sh start

stop:
	cd "$(RUNNER_ROOT)" && ./svc.sh stop || true

status:
	@launchctl print "gui/$(shell id -u)/$(SVC_NAME)" 2>/dev/null \
	  | grep -E 'state|pid|last exit code|program =' \
	  || printf 'service %s is not loaded\n' "$(SVC_NAME)"

# Housekeeping

record-versions:
	@{ \
	  sed -n '1,/^$$/p' etc/tool-versions; \
	  while read -r formula _; do \
	    case "$${formula}" in ''|\#*) continue ;; esac; \
	    printf '%s %s\n' "$${formula}" "$$(brew list --versions "$${formula}" | cut -d' ' -f2)"; \
	  done < etc/tool-versions; \
	} > etc/tool-versions.new && mv etc/tool-versions.new etc/tool-versions
	@printf 'etc/tool-versions refreshed\n'

reclaim:
	@printf 'Reclaimable under %s:\n' "$(RUNNER_ROOT)"
	@du -sh "$(RUNNER_ROOT)/_diag" 2>/dev/null || true
	@du -sh "$(RUNNER_ROOT)/_work/_update" 2>/dev/null || true
	@du -sh "$(RUNNER_ROOT)"/actions-runner-osx-*.tar.gz 2>/dev/null || true
	@du -sh "$(RUNNER_ROOT)"/bin.* "$(RUNNER_ROOT)"/externals.* 2>/dev/null || true
	@printf '\nKeep the most recent superseded bin./externals. pair as the\n'
	@printf 'rollback for a bad self-update. maintenance.sh enforces that.\n'
