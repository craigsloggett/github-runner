# github-runner

Provisioning for a self-hosted macOS GitHub Actions runner. This one builds, tests, signs, and notarizes [hark](https://github.com/craigsloggett/hark); `config.sh` is the only file that ties it to a particular repository.

The runner tree itself is not in this repo. This repo holds the launchd service definition, the environment the runner hands to every job, the job hooks, and the housekeeping that keeps a long-lived runner from drifting.

## Why This Exists

A runner left running for months on a personal Mac fails in three ways that nothing upstream addresses.

It stops. Run from a terminal, it dies with the terminal, the logout, or the reboot. `runner-service.sh` plus a LaunchAgent makes it survive all three.

It leaks. A runner started from an interactive shell hands that shell's environment to every job: the SSH agent, the GPG agent, the password store, and a global gitconfig that signs commits. `runner-service.sh` constructs the job environment deliberately instead of inheriting one.

It accumulates. Build outputs, diagnostic logs, superseded runner versions, and staged self-updates all grow without bound. `hooks/` bounds the per-job state and `maintenance.sh` bounds the per-host state.

## Layout

| Path                     | Role                                                                 |
| ------------------------ | -------------------------------------------------------------------- |
| `config.sh`              | Machine-specific values. The only file to edit for a different host.  |
| `runner-service.sh`      | launchd entry point. Owns every environment decision.                |
| `hooks/job-started.sh`   | Preflight assertions and workspace reset. Failure fails the job.     |
| `hooks/job-completed.sh` | Best-effort disk reclaim. Always exits 0.                            |
| `maintenance.sh`         | Daily host housekeeping. Refuses to run during a job.                |
| `probe-keychain.sh`      | Decides `SessionCreate` before the service is installed.             |
| `bootstrap.sh`           | New-machine path: download, verify, register.                        |
| `etc/path`               | The job `PATH`, installed as the runner's `.path`.                   |
| `etc/gitconfig`          | The job gitconfig, selected via `GIT_CONFIG_GLOBAL`.                 |
| `etc/tool-versions`      | Homebrew drift manifest. Warns, never fails.                         |
| `launchd/`               | plist templates for the runner and maintenance agents.               |

`make sync` copies the runtime files into `<runner root>/provisioning/`, kept in a subdirectory so nothing can collide with the runner's own `bin/` and `externals/` symlinks. It copies rather than symlinks, so a `git pull` here cannot change a running service mid-job.

It then code-signs the installed scripts with the Developer ID certificate, which is what stops System Settings listing the launchd agents under Login Items as coming from an unidentified developer. Signing the installed copies rather than the ones in the repo means editing a script can never leave a stale signature behind. It is best effort: a missing certificate warns and provisioning continues.

## Provisioning A New Machine

Install Xcode and accept its license, install Homebrew and the formulae in `etc/tool-versions`, then put the signing material in the login keychain:

```sh
# Developer ID Application certificate, imported via Keychain Access, then:
xcrun notarytool store-credentials "hark-notary" \
  --apple-id <id> --team-id <team> --password <app-specific-password>
```

Then:

```sh
gh auth login
./bootstrap.sh
make sync && make install
make probe-keychain   # see below before starting
make start
sudo pmset -c sleep 0 disksleep 0
```

`bootstrap.sh` passes no `--labels`. On this runner version the defaults are already `self-hosted`, `macOS`, and `ARM64`, which is exactly what the hark workflows target.

## The SessionCreate Question

`launchd/actions.runner.plist.template` sets `SessionCreate` to `false`, against upstream's default. Run `make probe-keychain` before trusting either value on a new OS version.

Upstream set it to `true` in [actions/runner#847](https://github.com/actions/runner/issues/847) because that was what made the login keychain reachable on macOS 11. On macOS 15 and 26 the reported behaviour is the opposite ([actions/runner#3407](https://github.com/actions/runner/issues/3407)). Getting it wrong breaks release signing, and because hark's test bundle is app-hosted, it can break `make test` too.

`probe-keychain.sh` runs the same measurements three ways: as a throwaway LaunchAgent with `SessionCreate` true, the same with false, and directly from your shell as a known-good control. It checks identity lookup, a real `codesign`, `notarytool` (a generic-password item, a different ACL path from the signing key), and WindowServer reachability. Pick the value whose output matches the control.

## Operating Constraints

These are properties of a laptop runner, not bugs to fix later.

A LaunchAgent only exists while a GUI session is logged in. An unattended reboot resumes into a session because FileVault is on, so `RunAtLoad` works. A deliberate logout takes CI down and nothing here can help.

Closed-lid sleep is not idle sleep and is not governed by `pmset sleep 0`. Without external power and display, closing the lid stops the runner.

Never run the runner's own `env.sh`. It does `echo $PATH > .path`, capturing whatever shell invoked it, which is how Ghostty and other interactive entries reached the job `PATH` originally. `make sync` installs `etc/path` instead.

The runner's own `config.sh` sources `env.sh`, so re-registering clobbers `.path` too, even for `./config.sh --help`. Always `make sync` after touching the registration, and `make check` will tell you if it drifted.

Never leave `./run.sh` running in a terminal while the service is loaded. Two listeners on one registration is exit code 5, Session Conflict.

## Runner Version

The runner self-updates. Two open regressions affect macOS on 2.336.0, [#4570](https://github.com/actions/runner/issues/4570) and [#4575](https://github.com/actions/runner/issues/4575), where `Runner.Worker` wedges at 100% CPU while the listener stays healthy. Neither `KeepAlive` nor the job hooks help, which is why `maintenance.sh` reaps workers that outlive `WORKER_REAP_MINUTES`.

`maintenance.sh` keeps the most recently superseded `bin.*` and `externals.*` pair as the rollback for a bad self-update, and never touches the downloaded release tarball, which is the other way back to a known version. `config.sh --disableupdate` pins the version, but treat it as a temporary escape hatch: GitHub stops assigning jobs to runners that fall too far behind.

To roll back, stop the service, extract the tarball for the target version over the runner root, repoint the `bin` and `externals` symlinks at the resulting directories, and start again. The registration is unaffected.

## Everyday Use

| Command                | Effect                                                     |
| ---------------------- | ---------------------------------------------------------- |
| `make status`          | Service state, pid, and last exit code.                    |
| `make check`           | Diff the installed provisioning against this repo.         |
| `make sync`            | Push changes from this repo to the runner. Restart after.  |
| `make lint`            | `shellcheck -x` and `shfmt --diff`.                        |
| `make record-versions` | Refresh `etc/tool-versions` after a deliberate upgrade.    |
| `make reclaim`         | Report reclaimable disk under the runner root.             |

To roll back to a foreground runner at any point, `make uninstall` and then `./run.sh` from the runner root. The registration is never touched by anything here.
