# Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `git clone` plus `./install.sh` turns a plain Linux laptop into an unmanaged harness host with this repo's shell built and Claude Code in it.

**Architecture:** One POSIX-sh script at the repo root does preflight, the Determinate Nix installer, `nix profile` installs of devenv and direnv from this flake, two rc lines, two config files shared with the home module, then `direnv allow` and a shell build with a self-check. The devenv module grows an opt-in that puts claude-code and tmux in the project shell and an export that lets `ccmux` work from a clone outside ~/code/git. The repo itself becomes a devenv project so the clone is the template.

**Tech Stack:** POSIX sh for the script (bash is not there before Nix), bash test scripts with stubbed commands as flake checks, Nix flake packages, devenv 2.4 module.

**Spec:** docs/superpowers/specs/2026-10-19-bootstrap-design.md

## Global Constraints

- The script is `/bin/sh` compatible until Nix is installed; `set -eu`, no bashisms before that point.
- Privileged steps are announced and declinable; a declined step prints the command for later and the script continues.
- Never a second direnv hook line, never a second tmux source line, never overwrite an existing `~/.config/direnv/direnv.toml`.
- devenv and direnv come from this flake (`packages.devenv`, `packages.direnv`); nix.conf is never edited.
- `harness.claudeCode.enable` defaults to false; this repo sets it true.
- `.envrc` of this repo: `eval "$(devenv direnvrc)"`, `use devenv`, `require_allowed devenv.nix devenv.yaml devenv.lock`.
- Work on branch `bootstrap`; commits as each task says.

## Review Focus

- Script run from outside the repo directory (`sh harness/install.sh`): it must cd to its own directory and target it, or the given argument (Task 5 test).
- Nix already installed by another installer, no `/nix/nix-installer`: the summary must not print an uninstall line that does not exist (Task 5 test).
- `~/.zshrc` absent and `~/.bashrc` absent: the script creates `~/.bashrc` with the hook and says so, rather than silently skipping both (Task 5 test).
- A clone under `~/code/git/<x>/<y>`: `HARNESS_PROJECT` keeps its `<x>/<y>` form, not `local/<name>` (Task 2 test).
- A re-run after the sysctl was declined: the restriction is reported again, not remembered as fixed (Task 5 test).

---

### Task 1: Shared direnv and tmux settings

**Files:**
- Create: `pkgs/direnv.toml`, `pkgs/tmux.conf`
- Modify: `home/default.nix:48-56` (direnv global config) and `:60-79` (tmux extraConfig)
- Test: `tests/host-config-test.sh`

**Interfaces:**
- Produces: `pkgs/direnv.toml` with `[global]` holding `strict_env = true`, `warn_timeout = "2m"`, `load_dotenv = false`; `pkgs/tmux.conf` with the home module's current extraConfig text. Task 5 installs both files; the home module reads them.

- [ ] **Step 1: Write the failing test**

`tests/host-config-test.sh <direnv.toml> <tmux.conf>`, `check` helper as in the other tests:

```bash
check "strict env"          'grep -q "^strict_env = true" "$toml"'
check "no dotenv"           'grep -q "^load_dotenv = false" "$toml"'
check "warn timeout"        'grep -q "^warn_timeout = \"2m\"" "$toml"'
check "no whitelist"        '! grep -q "whitelist" "$toml"'
check "direnv vars dropped" 'grep -q "set-environment -gu DIRENV_DIR" "$tmux"'
check "extended keys"       'grep -q "set -g extended-keys on" "$tmux"'
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/host-config-test.sh pkgs/direnv.toml pkgs/tmux.conf`
Expected: FAIL lines, files missing.

- [ ] **Step 3: Write the two files and point the home module at them**

`programs.direnv.config.global = (builtins.fromTOML (builtins.readFile ../pkgs/direnv.toml)).global;` and `programs.tmux.extraConfig = builtins.readFile ../pkgs/tmux.conf;`. Keep the comments that explain the settings in the files themselves.

- [ ] **Step 4: Run the test and the flake check**

Run: `bash tests/host-config-test.sh pkgs/direnv.toml pkgs/tmux.conf` then add `checks.host-config-test` via the flake's `test` helper and run `nix flake check`.
Expected: `fail=0`; all checks passed.

- [ ] **Step 5: Commit**

```bash
git checkout -b bootstrap
git add pkgs/direnv.toml pkgs/tmux.conf home/default.nix tests/host-config-test.sh flake.nix
git commit -m "host settings for direnv and tmux as files shared by the home module and the installer"
```

---

### Task 2: ccmux from a clone outside the code root

**Files:**
- Modify: `pkgs/ccmux.nix:43-52`
- Modify: `devenv/devenv.nix:135-143` (the HARNESS_PROJECT export)
- Test: `tests/ccmux-test.sh`

**Interfaces:**
- Produces: `ccmux` honours `HARNESS_PROJECT_DIR`: when set, `repo="$HARNESS_PROJECT_DIR"` and the session name is `HARNESS_PROJECT` with `/` replaced by `-`. The devenv module exports `HARNESS_PROJECT=local/<config.name>` and `HARNESS_PROJECT_DIR=$DEVENV_ROOT` when `DEVENV_ROOT` is not under the code root; under the root nothing changes.

- [ ] **Step 1: Add the failing cases**

```bash
# A clone outside the root: the devenv shell exports project and dir.
mkdir -p "$tmp/elsewhere/harness"
HARNESS_PROJECT=local/harness HARNESS_PROJECT_DIR="$tmp/elsewhere/harness" ok "session=local-harness repo=$tmp/elsewhere/harness" "$tmp/elsewhere/harness"
HARNESS_PROJECT=local/harness HARNESS_PROJECT_DIR="$tmp/elsewhere/harness" ok "session=local-harness repo=$tmp/elsewhere/harness args=-p hi" "$tmp" -p hi
# An explicit project still wins over the exported one.
HARNESS_PROJECT=local/harness HARNESS_PROJECT_DIR="$tmp/elsewhere/harness" ok "session=acme-app repo=$root/acme/app" "$tmp" acme/app
```

- [ ] **Step 2: Run to see them fail**

Run: `nix build .#checks.x86_64-linux.ccmux-test --no-link`
Expected: FAIL, `no such repo: $root/local/harness`.

- [ ] **Step 3: Implement in ccmux.nix and the module**

In `ccmux.nix`, after `project` is chosen: `if [ -n "${HARNESS_PROJECT_DIR:-}" ] && [ "$project" = "${HARNESS_PROJECT:-}" ]; then repo="$HARNESS_PROJECT_DIR"; else repo="$root/$project"; fi`. In the module's enterShell, an `else` branch on the existing `if [[ "$DEVENV_ROOT" == "$_harness_root/"*/* ]]` exporting the two variables with `${config.name}` (`projectName`).

- [ ] **Step 4: Run the checks**

Run: `nix flake check`
Expected: all checks passed (ccmux-test and ccode-test both include the new cases).

- [ ] **Step 5: Commit**

```bash
git add pkgs/ccmux.nix devenv/devenv.nix tests/ccmux-test.sh
git commit -m "ccmux: resolve a clone outside the code root through the devenv shell's exports"
```

---

### Task 3: Claude Code in the project shell, and this repo as a project

**Files:**
- Modify: `devenv/devenv.nix` (new option `harness.claudeCode.enable`, packages)
- Create: `devenv.yaml`, `devenv.nix`, `.envrc`, `.worktreeinclude`
- Create (generated by devenv, committed): `devenv.lock`
- Modify: `.gitignore` (add `.claude/worktrees/` is covered by `.claude/`; nothing else)
- Modify: `flake.nix` (`packages.devenv = pkgs.devenv`, `packages.direnv = direnvPackage`)

**Interfaces:**
- Produces: option `harness.claudeCode.enable` (bool, default false): adds `pkgs.claude-code` and `pkgs.tmux` to `packages`. Flake outputs `packages.<system>.devenv` and `packages.<system>.direnv` for Task 5.

- [ ] **Step 1: Write the project files**

`devenv.yaml`: `inputs.nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable`, `imports: [ ./devenv ]`, `allow_unfree: true`. `devenv.nix`: `{ name = "claude-nix-harness"; harness.claudeCode.enable = true; }`. `.envrc` per Global Constraints. `.worktreeinclude`: `.claude/settings.json`.

- [ ] **Step 2: See the option missing**

Run: `devenv shell -- true 2>&1 | tail -3`
Expected: error, `harness.claudeCode` does not exist.

- [ ] **Step 3: Add the option and the flake packages**

Option under `options.harness`, description "claude-code and tmux in the project shell, for hosts where no home module installs them; needs `allow_unfree: true` in devenv.yaml". `packages = [ ccmux ] ++ lib.optionals cfg.claudeCode.enable [ pkgs.claude-code pkgs.tmux ];`.

- [ ] **Step 4: Build the shell and check**

Run: `devenv shell -- sh -c 'command -v claude; command -v tmux; command -v ccmux; echo $HARNESS_PROJECT; jq .permissions.disableBypassPermissionsMode .claude/settings.json'`
Expected: three store paths, `raul/claude-nix-harness` (this checkout is under ~/code/git; the `local/<name>` form is covered by Task 2's test), and `"disable"`. `nix build .#devenv .#direnv --no-link` succeeds.

- [ ] **Step 5: Commit**

```bash
git add devenv/devenv.nix devenv.yaml devenv.nix devenv.lock .envrc .worktreeinclude flake.nix
git commit -m "devenv: claude-code and tmux in the shell on request; the repo is its own harnessed project"
```

---

### Task 4: install.sh

**Files:**
- Create: `install.sh` (executable)
- Test: `tests/install-test.sh`
- Modify: `flake.nix` (`checks.install-test`)

**Interfaces:**
- Consumes: `packages.devenv`, `packages.direnv` (Task 3), `pkgs/direnv.toml`, `pkgs/tmux.conf` (Task 1).
- Produces: `install.sh [<project-dir>]`; default target is the script's own directory.

- [ ] **Step 1: Write the failing test**

`tests/install-test.sh <install.sh>`: a fake `HOME`, a fake `PATH` with stubs for `curl`, `sudo`, `nix`, `direnv`, `devenv`, `sysctl`, `jq` that log argv to `$tmp/calls` and succeed; `nix` absent from PATH in the first run. A `check` helper over the calls log, plus file assertions:

```bash
# Fresh host: installer fetched, profile installs, hook lines, config files, allow, build, self-check.
run_fresh
check "nix installer run"        '^curl .*artifacts.nixos.org/nix-installer'
check "sh install"               '^sh -s -- install'
check "devenv from this flake"   '^nix profile (install|add) .*#devenv'
check "direnv from this flake"   '^nix profile (install|add) .*#direnv'
check "direnv allow in target"   '^direnv allow'
check "shell built"              '^devenv shell -- true'
file_has "$HOME/.bashrc" 'eval "$(direnv hook bash)"'
file_is  "$HOME/.config/direnv/direnv.toml" pkgs/direnv.toml
file_has "$HOME/.tmux.conf" 'source-file .*tmux.conf'
# Re-run with nix on PATH and everything in place: nothing repeated.
run_again
check_absent "no second installer" '^curl'
count_is "$HOME/.bashrc" 'direnv hook bash' 1
count_is "$HOME/.tmux.conf" 'source-file' 1
# Existing direnv.toml is left alone.
# Ubuntu restriction detected, sudo declined (stdin "n"): restriction reported, no sudo, exit 0, reported again on re-run.
# Run from outside the repo targets the script's directory.
# Nix present without /nix/nix-installer: summary has no uninstall line.
# No ~/.bashrc and no ~/.zshrc: ~/.bashrc is created with the hook.
```

Each commented case is a block in the same style; the sysctl stub returns `1` for `kernel.apparmor_restrict_unprivileged_userns` when `$tmp/restricted` exists.

- [ ] **Step 2: Run to see it fail**

Run: `bash tests/install-test.sh install.sh`
Expected: FAIL, file not found.

- [ ] **Step 3: Write install.sh**

POSIX sh, `set -eu`. Sections in this order, each a function: `preflight` (curl, git; sudo noted if absent; distro from /etc/os-release; `sysctl -n kernel.apparmor_restrict_unprivileged_userns` and `kernel.unprivileged_userns_clone` when the keys exist, then `offer_sysctl`), `install_nix` (skip if `command -v nix`; else `curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install`, then source `/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`), `install_tools` (`nix profile add` if `nix profile add --help` works else `install`, of `"$repo#devenv"` and `"$repo#direnv"` where `$repo` is `path:<script dir>`), `shell_hooks` (append `eval "$(direnv hook bash)"` to `~/.bashrc`, creating it when neither rc exists; `eval "$(direnv hook zsh)"` to `~/.zshrc` only if it exists; skip when the line is present), `host_config` (copy `pkgs/direnv.toml` to `~/.config/direnv/direnv.toml` unless present; copy `pkgs/tmux.conf` to `~/.config/tmux/harness.conf` and append `source-file ~/.config/tmux/harness.conf` to `~/.tmux.conf` unless present), `build_project` (`cd "$target"`, `direnv allow`, `devenv shell -- true`), `self_check` (`.claude/settings.json` exists, `jq -e '.permissions.disableBypassPermissionsMode == "disable"'`, run the hook it names with an empty JSON on stdin and expect exit 0), `summary`. `offer_sysctl` prints the sysctl and the drop-in `/etc/sysctl.d/99-claude-nix-harness.conf` it would write, reads `y/N`, runs with sudo on y. `sysctl` and `jq` are looked up on PATH so the test can stub them; `jq` comes from the devenv shell in the self-check (`devenv shell -- jq ...`).

- [ ] **Step 4: Run the test, then as a flake check**

Run: `bash tests/install-test.sh install.sh` then `checks.install-test = test "install-test" ./tests/install-test.sh "${./install.sh}"` and `nix flake check`.
Expected: `fail=0`; all checks passed.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install-test.sh flake.nix
git commit -m "install.sh: Nix, devenv, direnv, host settings and the repo shell on any Linux"
```

---

### Task 5: Docs

**Files:**
- Modify: `README.md` (host table row, new section "Any Linux: the install script", onboarding note for `harness.claudeCode.enable`, tests listing)
- Modify: `docs/runbook.md` section 3 (onboarding: `harness.claudeCode.enable` and `allow_unfree`) and section 5 (verification list for the script)
- Modify: `docs/roadmap.md` (item 0 moves to Done with the date; verification open)

- [ ] **Step 1: README**

Table row status: "script and tests ready, unverified on a real distro". Section: the four commands (`git clone`, `cd`, `./install.sh`, `ccmux`), what the script installs and where (Nix under /nix, two profile entries, two rc lines, two config files, one optional sysctl drop-in), the user-namespace note for Ubuntu, that the script is one-off and `devenv update` and `nix profile upgrade` take over, the uninstall line, and the managed tree as the next step for who wants machine-wide rules (link to the NixOS module section).

- [ ] **Step 2: Runbook and roadmap**

Onboarding step 2 gains `harness.claudeCode.enable = true` with `allow_unfree: true` for hosts without the home module. Section 5 gains the spec's five verification steps as "On a fresh distro". Roadmap: item 0 to Done, "verified: no".

- [ ] **Step 3: Commit**

```bash
git add README.md docs/runbook.md docs/roadmap.md
git commit -m "docs: the install route"
```

---

### Task 6: Verification on a fresh distro (Raul)

Commands for Raul on a throwaway Ubuntu 24.04 VM or LXD container with a sudo user; the session cannot run them.

- [ ] **Step 1:** `git clone <repo> harness && cd harness && ./install.sh`. Expected: user-namespace restriction reported and fixed on `y`, Nix installed, two profile installs, shell built, self-check lines pass, summary printed.
- [ ] **Step 2:** new terminal, `cd harness`, `ccmux`: tmux opens with Claude. In a second window `claude -p 'run: git commit -m x'` is refused and `claude -p 'run: grep -i nonewprivs /proc/self/status'` prints `NoNewPrivs: 1`.
- [ ] **Step 3:** VS Code with the direnv extension: the integrated terminal has `claude` and `ccmux`.
- [ ] **Step 4:** `./install.sh` again: no installer, no duplicate lines, same summary minus "installed".
- [ ] **Step 5:** `/nix/nix-installer uninstall`: apt untouched, repo intact.
- [ ] **Step 6:** Commit any change the run demanded, with the test that pins it.
