# Runbook: driving the harness

Day-to-day operation. The README explains what the layers are; this is what
you type and what you should see. Written for the person running it, not
for an agent.

## 1. Daily flow

1. Open the repo folder in VS Code. direnv (`mkhl.direnv`) loads the devenv
   shell; the first time, or after `devenv.nix`/`devenv.yaml`/`devenv.lock`
   change, it asks you to allow. Allow from a terminal:
   ```
   direnv allow
   ```
   The harness devenv module runs at that moment: it writes
   `.claude/settings.json` (store symlink: deny rules, hooks, sandbox,
   bypass mode off). On a host that carries the harness home module it also
   warns if `/etc/claude-code/managed-settings.json` is missing, which
   means the NixOS module is not enabled there; fix the host. An unmanaged
   host runs on the repo file alone and stays quiet.
2. Start a session in the project's tmux session. Inside the repo (any
   subdirectory or worktree) the project name is optional:
   ```
   ccmux                                # first window
   ccmux --worktree                     # a session that will edit files
   ccmux -p "explain the module layout"
   ccmux <customer>/<repo> --worktree   # from anywhere else; a path works too
   ```
   `ccmux` creates or attaches the tmux session named `<customer>-<repo>` and
   opens one window per call. From inside tmux it switches to it; from the
   VS Code terminal it attaches. It resolves the project from the argument,
   else from `HARNESS_PROJECT` (exported by the devenv shell at entry), else
   from the current directory under the code root. `ccmux -n ...` prints the
   resolution without starting anything. `ccmux` names the window after the
   shell's `HARNESS_ROLE` and sets it there: `center` in the harness
   checkout, `work` in a work repo. A window it opens in another repo, such
   as a work repo launched from the center, is named `claude` and starts
   without the variable; that repo's shell sets `work` before each Bash
   command. `ccmux -n` prints it on a second line (`role=center
   window=center`). `ccmux` takes `claude` from your PATH, else from the
   target repo's devenv shell (`direnv exec <repo> claude`), so on a host
   without a host-wide claude it works from any terminal for a repo with
   `harness.claudeCode.enable`; with neither it stops with a message
   naming that option. `ccmux -n` prints the source on a third line
   (`claude=<path> (PATH)` or `claude=<path> (direnv exec <repo>)`).
3. The command center. Start one session in the harness checkout (`ccmux`
   there). Its shell has the `center` role (2026-10-24): no sandbox, so
   every Bash command asks you first. Approve them knowing a script there
   can read your credentials and write anywhere you can
   (`docs/command-center.md`, section 5). Launch the others from it:
   `ccmux <customer>/<repo> --worktree` from its Bash tool (you approve
   the command) opens that repo's window under that repo's rules, leaves
   `HARNESS_ROLE` to that repo's shell, and switches your client to it
   (prefix + `L` comes back). Read a work repo's staged diff from there
   with `git -C ~/code/git/<customer>/<repo> diff --cached`. It may write
   the work repos' `devenv.nix`, `devenv.yaml`, `devenv.lock`, `.envrc`
   and `.claude/` skills and hooks, by the Edit tool or one shell command
   naming the absolute path; such a change takes effect only when you
   `direnv allow` that repo, so read `git -C ~/code/git/<customer>/<repo>
   diff` first. Commits and
   pushes stay yours, from your own terminal, in every repo. The center
   runs the harness revision its `devenv.lock` pins, not the working
   tree: after you push a harness change, run `devenv update harness` and
   `direnv allow` in the checkout, then restart its session.
4. Several objectives at once: one `ccmux` call each. Sessions that edit files
   get `--worktree`; the worktree lives under `.claude/worktrees/<name>`,
   has its own `.devenv/`, and its `.envrc` is auto-allowed only if it is
   byte-identical to the main checkout's (the env hook checks).
5. When a session waits for you, its tmux window turns orange. It clears on
   your next prompt. If you do not see it, the Notification hook is not
   firing; see troubleshooting.
6. You commit and push. Agents stage (`git add`), diff and branch; the
   commit is yours. `allowLocalCommits` flips that per host if you change
   your mind.

## 2. What a blocked call looks like

The agent sees one of these, in this order of precedence:

- `env-guard: git history/index write blocked` (or another `env-guard:`
  line): the hook denied it. Final, including against mods on a managed
  host.
- A permission denial naming a rule such as `Bash(git push *)`: the deny
  list. Also final.
- A sandbox error (`Operation not permitted`, a refused host): bubblewrap.
  With `allowUnsandboxedCommands = false` there is no retry outside.

All three are expected behaviour. The CLAUDE.md contract tells the agent to
propose a diff or ask you instead of working around it. If an agent keeps
hitting a block for something legitimate, the fix is a project allow rule
in `devenv.nix` (`harness.settings.permissions.allow`), never a looser
managed rule.

Note the scoping: project rules (git history, cloud writes, project config)
apply when the session's directory, the edited file, or the command text is
under an enforcement root. Universal rules (credentials, `sudo`, system
changes, plugin loading, your own `~/.claude` and `~/.config`) apply in
every session on the host, inside a harness repo or not.

## 3. Onboarding a repo

`harness init <customer>/<repo>` (a new directory under the code
root) or `harness init <path>` (an existing repo) does steps 1 to 5
and 7, then runs section 5's unit tests on the generated file; `--dry-run`
shows what it would write, existing files are left alone. Before the first
`direnv allow` it prints the files it did not write that the shell entry
runs or trusts (`devenv.yaml`, `devenv.nix`, `.envrc`, `devenv.local.*`,
and a `devenv.lock` already there, as the inputs it pins, nixpkgs
included) and waits for a `y`, or `--yes`; a re-run on a repo it set up
earlier asks about its own lock as well. The steps, for doing it by hand
or for reading what the script wrote:

1. `devenv.yaml`: add the `harness` input (`flake: false`) and
   `imports: - harness/devenv`. Use a git URL pinned by `devenv.lock`; the
   `path:` form is for developing the harness itself.
2. `devenv.nix`: project tools, and `harness.settings` for project allow
   rules (`docs/project-devenv.md` has every kind of change). On a host
   without a `claude` of its own (the plain WSL host: the VS Code extension
   brings its own binary), `harness init` sets `harness.claudeCode.enable =
   true` here and `allow_unfree: true` in devenv.yaml, which put Claude
   Code's CLI, tmux and jq in the shell for `ccmux`. With a host `claude`
   it leaves both commented out; the `claude` line of its report says which
   way it went.
3. `.envrc`:
   ```
   eval "$(devenv direnvrc)"
   use devenv
   require_allowed devenv.nix devenv.yaml devenv.lock
   ```
   Never `source_env`, `source_up`, or a `whitelist.prefix` in direnv.toml.
4. `.gitignore`: `.devenv/`, `.direnv/`, `.claude/settings.json`,
   `.claude/settings.local.json`, `.claude/worktrees/`.
   `.worktreeinclude`: `.claude/settings.json`, so a `--worktree` session
   starts with the repo's rules before devenv regenerates them there.
5. `CLAUDE.md`: the environment contract (copy the block from
   `azfn-rust-handler`, the repo the harness was verified against) plus
   project notes.
6. No `.claude/skills/<x>/.claude-plugin/plugin.json` anywhere. A directory
   with that manifest is a plugin.
7. `direnv allow`, twice in a new repo (the first load creates
   `devenv.lock`, the second approves it; troubleshooting has the detail).
   Then `ccmux <customer>/<repo> -p "list the tools on PATH"` as a smoke
   test.

## 4. Host configuration

| Host | Set |
|---|---|
| Managed host (NixOS, NixOS-WSL) | NixOS module `harness.enable = true;` and home module `harness.enable = true;`, nothing else; everything strict, everywhere |
| Unmanaged host | No harness modules (NixOS-WSL from `install-wsl.ps1` is this shape since 2026-10-24). Your own config provides direnv >= 2.38 (`pkgs/direnv.nix`), `devenv`, `programs.claude-code`; harness repos import `harness/devenv` and bring their own rules. Sessions outside them keep whatever your own settings allow. `scripts/install.sh` installs Nix where it is missing (Fedora 44 or newer: Fedora's `nix` and `nix-daemon` packages; any other distro: the nix-installer; NixOS: nothing, Nix is the system's) and hands over to `harness bootstrap`, which adds direnv, devenv, ccmux and `harness` from this flake (`nix profile add`), writes the home module's direnv, tmux and PATH configuration as plain files (the direnv hook for bash, and zsh where there is a `~/.zshrc`), plus the user-scope `strictAllowlist` and `syncClaudeAiSkills`/`syncClaudeAiPlugins = false` (account-synced skills and plugins off, the default since 2026-10-24; `--account-sync` leaves them on), and offers the bwrap AppArmor profile where AppArmor confines user namespaces (Ubuntu 23.10 and later) or the sysctl where an older Debian kernel does. On NixOS (2026-10-23) nothing under `/etc` is written: `nix.conf` is the system configuration's, so the `nix.settings` block is printed when it lacks flakes or the devenv cache, and a user file that is a store symlink (home-manager's) is left alone with the option that sets it printed; `root_write` refuses any store symlink on every host. It puts the devenv cache into the root-owned `nix.conf` rather than making you a trusted Nix user: a trusted user can hand the daemon any option, and agents run as you. `--trusted-user` opts in when a project needs per-repo caches. |
| Mixed host | NixOS module with `enforcementRoots`, `sandboxStrictAllowlist = false`, `allowManagedHooksOnly = false`, `extraKnownMarketplaces` for your own plugins, `allowMemoryEdits = true` if Claude Code should keep its auto-memory. Managed rules under the roots, your own settings elsewhere. |

See `nixos/default.nix` for every option. In a repo, `devenv.nix` sets the
same `harness.allowLocalCommits` and `harness.allowMemoryEdits` as the host
(the hook is built from the repo's values on an unmanaged host), plus
`harness.role` (`work`, the default; `center` is the harness checkout's
only), `harness.settings` for allow rules, `harness.extraAllowedDomains`,
`harness.extraDeny` and `harness.allowConnectors` (the claude.ai account's
connectors, off by default: they are MCP servers outside the sandbox).

`harness.enable = false;` in a repo's `devenv.nix` turns its guard rails
off: after `direnv allow` there is no `.claude/settings.json`, every shell
entry prints `harness: guard rails off for this repo`, and `harness init`
reports `off` and checks nothing; the managed layer is untouched. Deleting
the line turns them back on at the next shell entry; restart sessions
either way (`docs/project-devenv.md`).

`allowMemoryEdits` is off by default on purpose: memory under
`~/.claude/projects/<slug>/memory/` is text that every later session on the
machine reads as context, so on a managed host it is a persistence channel for
anything an agent picked up from a repo. With it on, only that directory
opens; the rest of `~/.claude` stays read-only.

Since 2026-10-24 the harness checkout runs as the command center,
`harness.role = "center"` in its own `devenv.nix`: the same deny rules and
hook as a work repo, no sandbox, Bash prompted, and `allowMemoryEdits` on
by default. Every work repo keeps `role = "work"`, the default, and memory
off (`docs/command-center.md`, sections 1 and 7). If the prompts are too
many, `harness.settings.permissions.allow = [ "Bash(*)" ];` in that
`devenv.nix` stops them; the deny rules and the hook still refuse what
they refuse, but they match command text, so with that line nothing else
stands between a command and your credential files or the network. The
role is not a host setting: on a managed host the managed sandbox stays
on in the center as well. The checkout's `devenv.yaml` imports the module
pinned by `devenv.lock`: a change to `hooks/` or `lib/` reaches the
center after you push it, then run `devenv update harness` and `direnv
allow` there.

Changing the host side is a rebuild: `nh os switch` or `boot` and reboot.
Changing a repo's `devenv.nix` is `direnv reload` in that repo, which
rewrites `.claude/settings.json`; on an unmanaged host that is the only
layer, so that is the whole change. Claude Code reloads settings files
live, but a running session is not the place to confirm a change: restart
it.

The home-manager side (`home/`) is the same on every managed host: direnv
config, tmux rules, `ccmux`, `programs.claude-code`. It never carries deny
rules.

Windows (2026-10-24): from a checkout of this repo on Windows 11,
`powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-wsl.ps1
-HostRepo <your nixos-config>` installs NixOS-WSL (the latest release,
checksum verified), puts your flake at `/etc/nixos` as a git checkout owned
by the default user and switches to `nixosConfigurations.<name>` (`-Output`,
default `nixos-wsl`). The host is plain: `examples/nixos-wsl-plain.nix` is
the host file, NixOS-WSL plus the four sandbox prerequisites
(`security.allowUserNamespaces`, bubblewrap and socat, flakes and the
devenv cache in `nix.settings`, `allowUnfree`) and no harness module. Then,
inside the distro, as yourself:
```
nix run github:bilibo/claude-nix-harness#harness -- bootstrap
# new terminal: PATH, HARNESS_CODE_ROOT and the direnv hook come from ~/.bashrc.d
harness doctor                        # every line ok or info
harness init <customer>/<repo>        # once per work repo
```
The host carries tmux but deliberately no `claude`: the VS Code extension
on Windows runs its bundled binary inside WSL over Remote-WSL (nix-ld runs
it), which is enough for interactive use, and for tmux and `ccmux`
sessions a work repo brings its own CLI `claude` (and tmux) through
`harness.claudeCode.enable`, which `harness init` writes when it finds no
host `claude`. `harness doctor` reports the absence as an `info` line, not
a failure; a missing tmux is a warning, since ccmux carries its own. Keep
home-manager off `~/.bashrc` on such a host: bootstrap skips a
store-symlinked rc file and only prints the option. Running the script
again is the update: `git pull --ff-only` and switch, never a commit on the
box, and a dirty `/etc/nixos` stops it. `-NoSwitch` builds and prints the
two activation commands for a host where you switch by hand. The
`.wslconfig` comes from the host repo's `windows/wslconfig` and applies on
the `wsl --shutdown` the script does; after any `wsl.*` option change, run
`wsl -t <distro>` from Windows. `scripts/wsl/verify.sh` prints what the
host should look like afterwards: on a plain host it skips the
managed-layer checks with one line, checks tmux, and reports direnv,
devenv, ccmux and claude without failing on them. Inside the distro the update is
`sudo sh <harness checkout>/scripts/wsl/update.sh <name>`. The managed
layer stays available: `harness reset` first, then import both harness
modules as well (`examples/nixos-wsl-host.nix`).

## 5. Verifying after a rebuild or a Claude Code upgrade

Host prerequisites on a host without the home module:
`harness doctor`, one line per item, exit 1 when
something the harness needs is missing. `claude doctor` is the Claude Code
side: install health and settings-file validation, without a session.

From zero on an unmanaged Fedora host, end to end, repeatable. `harness
reset` reverses what the receipt lists, the Fedora nix packages included
when install.sh put them there, so the sequence starts from a Fedora with
only VS Code, Claude Code and this checkout on it (a reinstall of Fedora is
the same list minus the first line). Without a receipt, reset leaves Nix
installed with its daemon socket off, and install.sh turns it back on. A
host set up before the `harness` CLI existed (by the old
`scripts/bootstrap-fedora.sh`) has no `harness` on PATH: run install.sh
once first, which adds it and writes the receipt. `<customer>/<repo>` is a
throwaway repo under the code root:
```
harness reset                                 # sudo; asks first; reads the receipt; leaves ~/code/git alone
rm -rf ~/code/git/<customer>/<repo>           # the throwaway repo, so init starts clean
scripts/install.sh                            # sudo: dnf, SELinux label, daemon socket; then harness bootstrap (nix.conf, profile, user files) and harness init on this checkout; the ref is this checkout
# new terminal: PATH and NIX_SSL_CERT_FILE come from profile.d and ~/.bashrc.d
harness doctor                                # every line ok or info
harness init <customer>/<repo>                # files, two allows, the settings checks, the hook cases
harness check ~/code/git/<customer>/<repo>    # fourteen -p sessions
cd ~/code/git/<customer>/<repo> && ccmux            # interactive: trust dialog once, orange window when it waits
```
In the command center (the harness checkout, `harness.role = "center"`)
`harness check` runs only the seven cases the hook and deny rules hold
(devenv-env, git-commit, cred-read, config-write, edit-envrc, nested-flags,
hooks-registered) and prints one `skip` line, `sandbox off (role center):
<why>`, for each case only the sandbox holds (sandbox, ssh-agent,
home-write, repo-write, env-deny, cred-sandbox, git-hookspath; read-fence
too in a fenced repo), ending `7 passed, 0 failed, 7 skipped`; there Claude
Code's permission prompt is all that stands in for those seven, so read
what you approve.

`harness check` runs the `claude` a terminal in the repo would get: the
repo shell's (`harness.claudeCode.enable`), else the host's. So it works
from any terminal, also on a host whose only Claude Code is the VS Code
extension's. The `claude:` line of its header, `--dry-run` included, says
which.

Log out and in once at the end so GUI-launched VS Code sees the nix profile.
The 2026-10-20 run of this list on the Fedora laptop, with
`raul/harness-test` as the repo, passed; the two host fixes it produced
(SELinux label, CA bundle path) are in the script.

Unit tests, no Claude Code needed, from a checkout of this repo:
```
nix flake check                                     # every suite under tests/, in the Nix sandbox
nix shell nixpkgs#jq -c tests/hook-test.sh /etc/claude-code/hooks/env-guard.sh   # the installed hook, managed host
nix shell nixpkgs#jq -c tests/hook-test.sh "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' <repo>/.claude/settings.json)"   # the repo's hook
tests/ccmux-test.sh "$(command -v ccmux)"           # inside a repo shell, or after home-manager switch
```
Inside a Claude Code session the sandbox masks shell startup files and
`.gitmodules` in the working directory with device nodes, so Nix cannot
read that directory as a git flake and a bare `nix flake check` there
fails. A session in the test repo can still run all of it against the
harness checkout by path (verified 2026-10-20):
`nix flake check path:<harness checkout>`, `nix build
path:<harness checkout>#project-settings` followed by the tests on the
result, and both unit tests against the repo's own hook and settings file.
Run the flake check from your own terminal before committing anyway; the
`path:` form checks the working tree, not what git tracks.

Live checks, inside a harness repo (the test repo), on any host.
`harness check <repo>` runs them as a script, judged on the
stream-json transcript and on the files afterwards rather than on the
model's prose, and keeps the transcripts for the exact refusal text. By
hand:

```
claude -p 'run: grep -i nonewprivs /proc/self/status'      # NoNewPrivs: 1 => sandboxed
claude -p 'run: git commit -m x'                            # env-guard block
claude -p 'run: cat ~/.azure/msal_token_cache.json'         # blocked
claude -p 'run: echo x > devenv.nix'                        # blocked
claude -p 'edit .envrc and add a comment'                   # blocked
claude -p 'run: claude --dangerously-skip-permissions -p hi' # blocked (nested session)
claude -p 'run: which cargo'                                # the devenv one, not system
claude -p hi --debug-file /tmp/d.txt; grep env-guard /tmp/d.txt   # repo hooks registered (debug goes to a file)
```

Managed hosts only:

```
claude --plugin-dir /tmp/x -p hi                            # rejected at startup
claude -p hi --debug-file /tmp/d.txt; grep -i allowManagedModsOnly /tmp/d.txt   # guard loaded
```

Outside the repo: on an unmanaged host everything your own settings allow;
on a mixed host `git commit` allowed, `sudo` still blocked.

On a fresh distro (a throwaway Ubuntu 24.04 VM with a sudo user), the
install route, never yet run there (the nix-installer route is tested with
every host command stubbed: `install-test`, `harness-bootstrap-test`):

1. `git clone <repo> harness && cd harness && scripts/install.sh`: the
   nix-installer runs and confirms on the terminal; bootstrap reports the
   user-namespace restriction and fixes it on `y`, adds the four profile
   packages and writes the user files; `harness init` builds this
   checkout's shell and its checks pass; the report ends with `0 missing`.
2. New terminal, `cd harness`, `ccmux` opens tmux with Claude; in a second
   window `claude -p 'run: git commit -m x'` is refused and
   `claude -p 'run: grep -i nonewprivs /proc/self/status'` prints
   `NoNewPrivs: 1`.
3. VS Code with the direnv extension: the integrated terminal has `claude`
   and `ccmux`.
4. `scripts/install.sh` again: no installer, no duplicate rc lines, the
   same report.
5. `harness reset`: Nix gone through `/nix/nix-installer uninstall`, the
   AppArmor profile `/etc/apparmor.d/bwrap` gone, apt untouched, the repo
   intact.

After a Claude Code upgrade also re-read the settings reference for the
keys in `lib/settings.nix`; the file header records the version they were
checked against. Keys that stop existing are silently ignored,
which is the dangerous direction.

## 6. Upgrades and pins

- Claude Code, managed host: from nixpkgs (`programs.claude-code`),
  auto-update disabled, `nix flake update nixpkgs` moves it. Unmanaged
  host: the native install; `claude update` moves it and `autoUpdates`
  stays off in `~/.claude.json` so an upgrade is a decision, followed by
  `harness check`. Minimum 2.1.295 for `onFailure: block`; the
  settings keys were last checked against 2.1.296 (`lib/settings.nix`
  header), the Fedora host runs 2.1.304.
- direnv: `pkgs/direnv.nix` overrides to 2.38.2 while nixpkgs is older. The
  locked nixpkgs (2026-10-14) ships 2.37.1, so the override is in use. At
  the next `nix flake update nixpkgs`, check `nix eval nixpkgs#direnv.version`;
  at 2.38 or newer delete the file and point the one remaining
  unconditional import (`lib/managed-tree.nix` default) at `pkgs.direnv`;
  the NixOS, home and devenv modules and the flake's packages already fall
  back on their own.
- Host tools on an unmanaged host: `harness upgrade`
  after a `nix flake update` or a move of the checkout re-adds direnv,
  devenv and ccmux from the current lock, then hands the user steps to the
  harness it just put in the profile (the running one is the old build;
  2026-10-22). `harness bootstrap` alone reruns the user steps with
  whatever harness is on PATH.
- devenv from nixpkgs (2.4.0 at the time of writing). Each repo pins its own
  devenv inputs in `devenv.lock`; `devenv update harness` bumps the harness
  input in one repo.

## 7. Troubleshooting

- **Agent's tools are the system ones, not the project's.** The env hook
  did not run or direnv is not allowed in that directory. Check
  `direnv status` in the repo, and `~/.claude/shell-snapshots/` is not the
  source of PATH any more: the preamble runs `direnv export bash` per
  command. Since 2026-10-23 the hook refuses the command instead when that
  export would fail (`env-guard: direnv export failed in <dir>: ...`), with
  the fix in the message; an edited `devenv.nix` that is not yet approved
  loads anyway (`require_allowed` only flags it).
- **"sandbox unavailable" at start.** `failIfUnavailable` is on, so the
  session refuses to start. bubblewrap needs user namespaces
  (`security.allowUserNamespaces`, asserted by the module) and works nested
  inside `vscode-fhs`. Inside a container it needs `/proc` unmasked.
- **Repo hooks do not fire on an unmanaged host.** Interactive sessions
  hold back every hook from settings files until you accept the workspace
  trust dialog for the folder; `-p` sessions treat it as trusted. Check
  with `claude -p hi --debug-file /tmp/d.txt; grep env-guard /tmp/d.txt` (the
  `Hooks: SessionStart:startup [...env-guard.sh]` line; `--debug` no longer
  writes to stderr). A dangling
  `.claude/settings.json` symlink (store path collected) has the same
  effect; `direnv reload` rewrites it.
- **Plugin or marketplace refused.** `strictKnownMarketplaces` is
  `extraKnownMarketplaces` and nothing else: empty by default, so no
  marketplace can be added. Add the source on that host, or accept that
  the plugin does not load there. A mod is refused whatever the list says:
  the harness ships none (2026-10-24) and the built-in guard lets no other
  through.
- **`harness: guard rails off for this repo` at every `cd`.** The repo's
  `devenv.nix` (or `devenv.local.nix`) sets `harness.enable = false`. If
  nobody meant to, `git log -p devenv.nix` says who did; delete the line
  and `direnv allow`.
- **Plugin hooks silent.** `allowManagedHooksOnly` is on. Expected on a
  managed host.
- **`.claude/settings.json` is a dangling symlink.** The store path was
  garbage collected; enter the shell again (`direnv reload`) and devenv
  rewrites it.
- **Worktree `.envrc` blocked.** It differs from the main checkout's. That
  is the point; make them identical or allow it yourself after reading it.
- **`git push` from a session fails with `Permission denied (publickey)`.**
  Expected in a harness repo: sessions there get no agent socket and no
  `~/.ssh`. You push from your own window (README, "Git over SSH"); sessions
  clone over HTTPS. Outside the roots the agent is available.
- **A push went through without asking.** The key is cached in an agent.
  `ssh-add -l` lists it; `ssh-add -d <key>` removes it, and the host block
  needs `IdentityAgent none` (README, "Git over SSH"). A passphrase asked on
  every push, or a touch for a hardware key, is the design.
- **`nix-daemon.socket` fails with `Failed to create listening socket ...
  Permission denied` on Fedora.** SELinux: `/nix` is `default_t` without a
  policy and systemd may not create a socket there; auditd has the AVC,
  the journal does not. Label the directory the way the Determinate
  installer's `nix.fc` does, which `scripts/install.sh` does itself:
  `sudo semanage fcontext -a -t var_run_t '/nix/var/nix/daemon-socket(/.*)?'`,
  `sudo restorecon -RF /nix/var/nix/daemon-socket`, then restart the socket.
- **devenv fails with `the SSL certificate is invalid` while fetching an
  input, on Fedora.** Nix-built tools look for the CA bundle at the NixOS and
  Debian path or where `NIX_SSL_CERT_FILE` points, and Fedora 44 keeps it
  only at `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`; Fedora's own
  `profile.d/nix-daemon.sh` checks the legacy paths and sets nothing. The
  bootstrap script exports the variable in `~/.bashrc.d`, `environment.d`
  and the mkhl.direnv settings; a terminal opened before it ran lacks it.
- **First `direnv allow` in a new repo ends with `devenv.nix and
  devenv.yaml and devenv.lock require approval`.** Expected: the first
  load created `devenv.lock`. `direnv allow` once more, in the same shell.
- **mkhl.direnv reports that direnv is not found.** VS Code started from the
  menu has the login session's PATH, which on an unmanaged host lacks the
  nix profile until the next login (`~/.config/environment.d`, written by
  the bootstrap script). The script also sets `direnv.path.executable` in
  the VS Code settings, which works at once; check it points at the
  profile's direnv.
- **Hook denies everything, including `ls`.** A regex error makes the ERR
  trap fire, which is the fail-closed design. Run the unit tests; the first
  failing case points at the line.
- **`/model` fails with `EROFS: read-only file system, open
  '/nix/store/...-home-manager-files/.claude/settings.json.tmp...'`.**
  home-manager owns `~/.claude/settings.json` as a store symlink and Claude
  Code writes that file itself at user scope. A harness revision before
  2026-10-24 did this through `programs.claude-code.settings` in the home
  module: move the host to a newer revision and switch; home-manager drops
  the link and the next `/model` writes a plain file. Your own
  `programs.claude-code.settings` has the same effect, so keep user-scope
  settings out of home-manager on a harness host; the managed settings
  carry everything the harness needs.

## 8. Known gaps, by design

- Deny rules and the hook match text. `git -C`, `bash -c`, quoting and
  `env` prefixes are covered by normalisation; a script that opens files
  itself is not. The sandbox and Azure RBAC are the layers for that.
- On a managed host the sandbox is host-wide and cannot be scoped by
  directory. What is hidden from agents in harness repos is hidden in every
  other repo too. On an unmanaged host it comes from the repo file and
  applies inside harness repos only.
- Settings files reload live, so a repo converted while a session is open
  picks up the deny rules; hooks from a file that did not exist at start
  are the uncertain part. Restart the session.
- The hook refuses `.claude/settings.local.json` changes inside a repo,
  which is also where "Yes, and don't ask again" writes. The file is still
  written; the new allow rule applies from the next session. Allow rules
  for a project belong in `devenv.nix` (`harness.settings`).
- Hooks run outside the sandbox with your full permissions. Keep
  `env-guard.sh` small; it is the one script that must be right.
- Without managed settings (unmanaged host) the repo file is the top
  layer. What it cannot do is listed in the README ("What a repo cannot
  enforce on its own"): mod policy, launch flags of the outer `claude`,
  sessions started above the repo, the folder trust dialog, account-synced
  skills and plugins (the bootstrap turns those off in user scope).

Sandbox limits, checked against the sandboxing docs and live on 2026-10-20.
The README's "Lockdown level today" table summarises them; the roadmap's
"sandbox hardening" entry closes them in order:

- The tmux server runs outside the sandbox and its socket is reachable
  from inside (`allowAllUnixSockets`): a sandboxed `tmux send-keys`,
  `run-shell` or `new-window` runs unsandboxed and unhooked. The command
  center is out of its reach since it has no sandbox, but its pane is one
  a work session can type into; since 2026-10-24 hook rule 6 refuses the
  same launch flags after `ccmux` as after `claude`. Roadmap 2.8
  (2026-10-24).
- Reads are open. A sandboxed command reads the whole machine except the
  `denyRead` paths (`~/.azure`, `~/.gnupg`, `~/.terraform.d`, `~/.netrc`,
  `~/.ssh`, and since 2026-10-21 `~/.aws`, `~/.config/gh` and
  `~/.git-credentials`). `~/.claude/.credentials.json`, `~/.claude.json`,
  `~/.config` and every sibling repo under the code root are readable by
  any command the hook's secret-path rule lets through (one harmless verb,
  no pipe), and the Read tool
  reaches them too (`blockReadsOutsideWorkingDirectories` is unset: a
  session in the test repo reads the harness checkout through it, which is
  how this document was checked). The docs allow a read fence from the repo
  file (`denyRead ["~/"]` plus `allowRead` for the repo and the paths devenv
  needs); untested, see the roadmap. The `Read(**/.env)` deny rules do
  become sandbox `denyRead`: a `.env` under the checkout is bind-mounted as
  `/dev/null` for every command, whatever verb reads it (measured
  2026-10-21); a `.env` outside the cwd tree is not fenced.
- Glob `denyWrite` entries do nothing on Linux (`mkdir $TMPDIR/x/.claude-plugin`
  succeeds inside the sandbox; they stay for macOS). Since 2026-10-21 the
  repo file repeats its protected paths as literal paths under the
  checkout (`config.devenv.root`), which Linux honours; a plugin manifest
  or hook directory elsewhere under `$HOME` is still creatable, and
  `~/.claude` plus Claude Code's own working-directory protections hold.
- Network is prompt-gated unless the user-scope `~/.claude/settings.json`
  sets `sandbox.network.strictAllowlist = true`, which the bootstrap writes
  (user-or-managed scope; a repo cannot). Without it an unlisted host
  prompts in an interactive session and is refused in a `-p` one, which is
  why the live checks look strict either way.
- Every unix socket is reachable (`allowAllUnixSockets`, all-or-none on
  Linux): the D-Bus session bus, the secret service behind it, the display
  server, not only the Nix daemon and go-plugin. One more reason to keep
  `trusted-users` off (the daemon socket would be root-equivalent). The
  SSH agent is the measured case (2026-10-21): `SSH_AUTH_SOCK` is stripped,
  but `/run/user/<uid>/gcr/ssh` is guessable and answers from inside the
  sandbox, so what holds is that no plain key is loaded in the agent
  (README, "Git over SSH"). Roadmap item 2.3 hides the socket directories.
- The environment: the sandbox's `credentials.envVars` denies the Azure
  secrets, the SSH agent and the GitHub tokens; every other variable of the
  launching shell is inherited. `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`, which
  would strip credential-shaped names and values, is off since 2026-10-22:
  in a repo file it is ignored, and in user scope it turns the sandbox's
  Bash auto-allow off, so every command with a variable, every read outside
  the working directory and every write under `~/.claude` prompts
  (changelog). Name a secret in `sandbox.credentials.envVars` through
  `harness.settings` instead.
- The hook strips quotes before matching, so a quoted string that mentions
  a config path next to something that looks like a write is refused too:
  `echo "settings -> $(readlink .claude/settings.json)"` (the `->`) and
  `ls ~/.claude/.credentials.json | head` are both denied. A secret path
  anywhere in a command is refused unless the command is one harmless verb
  (`ls`, `stat`, `rm`, `wc`, `echo`, ...) with no pipe, substitution or
  input redirection, so `claude -p "why is .env hidden"` is refused too.
  Rephrase.

Accepted for now (2026-10-17), after comparing with Hermes Agent, Codex,
destructive_command_guard and codex-protect. Each is a text-matching gap the
other layers are meant to catch; revisit when tightening:

- Shell constructs that compute the command at runtime: `$IFS`, `git\ push`,
  `$(echo git) push`, variable indirection, `base64 -d | sh`, python or node
  spawning git. No regex closes these; the sandbox, the absence of push
  credentials inside it and server-side branch protection are the gate.
- GitHub CLI writes (`gh pr merge`, `gh release create`, `gh repo delete`,
  `gh secret set`, `gh gist create`, `gh api -X DELETE`) and package or
  image publishing (`npm publish`, `cargo publish`, `dotnet nuget push`,
  `docker push`). Same policy as `git push`; not yet encoded.
- Git config keys that run programs: `-c core.hooksPath=`, `core.sshCommand`,
  `credential.helper`, `--config-env`, `git log --output`. The `.git/hooks`
  write block does not cover a hooksPath pointing elsewhere. Writing one
  into the main checkout's `.git/config` fails in the sandbox (the lock
  path is masked: `could not lock config file .git/config: File exists`,
  `harness check` case 15, 2026-10-24); the `-c` form, `--global` and a
  worktree's config are the accepted gaps.
- `git checkout <path>` with one word (a path cannot be told from a branch
  name) and `git -c alias.x=reset x`, which runs through the `-c` keys. A
  ref followed by paths is refused since 2026-10-21.
- `az storage blob upload` and other az upload or copy verbs: the az regex
  lists mutation verbs, not transfer verbs.
- Shell writes to your own config (`echo >> ~/.bashrc`, `authorized_keys`,
  `git config --global`): the Edit tool is blocked, the shell path is left
  to the sandbox write allowlist.
- Outbound transfer (`curl -T`, `scp`, `ngrok`, `ssh -R`): the network
  allowlist is the layer; open by choice on an unmanaged host.
- The nested `claude` launch-flag rule matches the flag word anywhere in
  the command, quotes stripped, so `claude -p "why is --bare refused"` is
  denied too. Rephrase the prompt.
