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
   resolution without starting anything. `ccode` is the former name and
   still works.
3. Several objectives at once: one `ccmux` call each. Sessions that edit files
   get `--worktree`; the worktree lives under `.claude/worktrees/<name>`,
   has its own `.devenv/`, and its `.envrc` is auto-allowed only if it is
   byte-identical to the main checkout's (the env hook checks).
4. When a session waits for you, its tmux window turns orange. It clears on
   your next prompt. If you do not see it, the Notification hook is not
   firing; see troubleshooting.
5. You commit and push. Agents stage (`git add`), diff and branch; the
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

By hand, or copy from a repo that already imports the module:

1. `devenv.yaml`: add the `harness` input (`flake: false`) and
   `imports: - harness/devenv`. Use a git URL pinned by `devenv.lock`; the
   `path:` form is for developing the harness itself.
2. `devenv.nix`: project tools, and `harness.settings` for project allow
   rules. On a host without the home module (one set up by `install.sh`),
   `harness.claudeCode.enable = true` here and `allow_unfree: true` in
   devenv.yaml put Claude Code, tmux and jq in the shell.
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
7. `direnv allow`, then `ccmux <customer>/<repo> -p "list the tools on PATH"`
   as a smoke test.

## 4. Host configuration

| Host | Set |
|---|---|
| Managed host (NixOS, NixOS-WSL) | NixOS module `harness.enable = true;` and home module `harness.enable = true;`, nothing else; everything strict, everywhere |
| Unmanaged host | No harness modules. Your own config provides direnv >= 2.38 (`pkgs/direnv.nix`), `devenv`, `programs.claude-code`; harness repos import `harness/devenv` and bring their own rules. Sessions outside them keep whatever your own settings allow. |
| Mixed host | NixOS module with `enforcementRoots`, `sandboxStrictAllowlist = false`, `allowManagedHooksOnly = false`, `extraKnownMarketplaces` for your own plugins, `allowMemoryEdits = true` if Claude Code should keep its auto-memory. Managed rules under the roots, your own settings elsewhere. |

See `nixos/default.nix` for every option. In a repo, `devenv.nix` sets the
same `harness.allowLocalCommits` and `harness.allowMemoryEdits` as the host
(the hook is built from the repo's values on an unmanaged host), plus
`harness.settings` for allow rules, `harness.extraAllowedDomains` and
`harness.extraDeny`.

`allowMemoryEdits` is off by default on purpose: memory under
`~/.claude/projects/<slug>/memory/` is text that every later session on the
machine reads as context, so on a managed host it is a persistence channel for
anything an agent picked up from a repo. With it on, only that directory
opens; the rest of `~/.claude` stays read-only.

Changing any of it is a rebuild: `nh os switch` or `boot` and reboot.
Claude Code reloads settings files live, but a running session is not the
place to confirm a change: restart it.

The home-manager side (`home/`) is the same on every managed host: direnv
config, tmux rules, `ccmux`, `programs.claude-code`. It never carries deny
rules.

## 5. Verifying after a rebuild or a Claude Code upgrade

Unit tests, no Claude Code needed, from a checkout of this repo:
```
nix flake check                                     # every suite under tests/, in the Nix sandbox
nix shell nixpkgs#jq -c tests/hook-test.sh /etc/claude-code/hooks/env-guard.sh   # the installed hook, managed host
nix shell nixpkgs#jq -c tests/hook-test.sh "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' <repo>/.claude/settings.json)"   # the repo's hook
tests/ccmux-test.sh "$(command -v ccmux)"           # inside a repo shell, or after home-manager switch
```
Run these from your own terminal. Inside a Claude Code session in this repo
the sandbox masks shell startup files and `.gitmodules` in the working
directory with device nodes, so Nix cannot read the repo as a git flake and
`nix flake check` fails there. An agent can still test the installed hook
directly: `tests/hook-test.sh /etc/claude-code/hooks/env-guard.sh` with jq
on PATH.

Live checks, inside a harness repo (the test repo), on any host:

```
claude -p 'run: grep -i nonewprivs /proc/self/status'      # NoNewPrivs: 1 => sandboxed
claude -p 'run: git commit -m x'                            # env-guard block
claude -p 'run: cat ~/.azure/msal_token_cache.json'         # blocked
claude -p 'run: echo x > devenv.nix'                        # blocked
claude -p 'edit .envrc and add a comment'                   # blocked
claude -p 'run: claude --dangerously-skip-permissions -p hi' # blocked (nested session)
claude -p 'run: which cargo'                                # the devenv one, not system
claude --debug -p hi 2>&1 | grep -c env-guard               # repo hooks registered
```

Managed hosts only:

```
claude --plugin-dir /tmp/x -p hi                            # rejected at startup
claude --debug -p hi 2>&1 | grep -i allowManagedModsOnly    # guard loaded
```

Outside the repo: on an unmanaged host everything your own settings allow;
on a mixed host `git commit` allowed, `sudo` still blocked.

On a fresh distro (a throwaway Ubuntu 24.04 VM with a sudo user), the
install route:

1. `git clone <repo> harness && cd harness && ./install.sh`: the
   user-namespace restriction is reported and fixed on `y`, Nix installed,
   two profile installs, shell built, the self-check line passes.
2. New terminal, `cd harness`, `ccmux` opens tmux with Claude; in a second
   window `claude -p 'run: git commit -m x'` is refused and
   `claude -p 'run: grep -i nonewprivs /proc/self/status'` prints
   `NoNewPrivs: 1`.
3. VS Code with the direnv extension: the integrated terminal has `claude`
   and `ccmux`.
4. `./install.sh` again: no installer, no duplicate rc lines.
5. `/nix/nix-installer uninstall`: apt untouched, repo intact.

After a Claude Code upgrade also re-read the settings reference for the
keys in `lib/settings.nix`; the file header records the version they were
checked against. Keys that stop existing are silently ignored,
which is the dangerous direction.

## 6. Upgrades and pins

- Claude Code comes from nixpkgs (`programs.claude-code`). Auto-update is
  disabled; `nix flake update nixpkgs` moves it. Minimum 2.1.295 for
  `onFailure: block`.
- direnv: `pkgs/direnv.nix` overrides to 2.38.2 while nixpkgs is older and
  is `pkgs.direnv` otherwise. When `nix eval nixpkgs#direnv.version`
  reports 2.38 or newer, delete the file and replace every
  `import ../pkgs/direnv.nix` with `pkgs.direnv`.
- devenv from nixpkgs (2.4.0 at the time of writing). Each repo pins its own
  devenv inputs in `devenv.lock`; `devenv update harness` bumps the harness
  input in one repo.

## 7. Troubleshooting

- **Agent's tools are the system ones, not the project's.** The env hook
  did not run or direnv is not allowed in that directory. Check
  `direnv status` in the repo, and `~/.claude/shell-snapshots/` is not the
  source of PATH any more: the preamble runs `direnv export bash` per
  command.
- **"sandbox unavailable" at start.** `failIfUnavailable` is on, so the
  session refuses to start. bubblewrap needs user namespaces
  (`security.allowUserNamespaces`, asserted by the module) and works nested
  inside `vscode-fhs`. Inside a container it needs `/proc` unmasked.
- **Repo hooks do not fire on an unmanaged host.** Interactive sessions
  hold back every hook from settings files until you accept the workspace
  trust dialog for the folder; `-p` sessions treat it as trusted. Check
  with `claude --debug -p hi 2>&1 | grep env-guard`. A dangling
  `.claude/settings.json` symlink (store path collected) has the same
  effect; `direnv reload` rewrites it.
- **Plugin or marketplace refused.** `strictKnownMarketplaces` lists only
  the managed directory plus `extraKnownMarketplaces`. Add the source on
  that host, or accept that the plugin does not load there.
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
- **Hook denies everything, including `ls`.** A regex error makes the ERR
  trap fire, which is the fail-closed design. Run the unit tests; the first
  failing case points at the line.

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
  sessions started above the repo, the folder trust dialog.

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
  write block does not cover a hooksPath pointing elsewhere.
- `az storage blob upload` and other az upload or copy verbs: the az regex
  lists mutation verbs, not transfer verbs, and `az` is not in the
  credential-reader list.
- Shell writes to your own config (`echo >> ~/.bashrc`, `authorized_keys`,
  `git config --global`): the Edit tool is blocked, the shell path is left
  to the sandbox write allowlist.
- Outbound transfer (`curl -T`, `scp`, `ngrok`, `ssh -R`): the network
  allowlist is the layer; open by choice on an unmanaged host.
- The nested `claude` launch-flag rule matches the flag word anywhere in
  the command, quotes stripped, so `claude -p "why is --bare refused"` is
  denied too. Rephrase the prompt.
