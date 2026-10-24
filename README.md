# claude-nix-harness

Guard rails for Claude Code that travel with the repository. A devenv
module the repo imports writes its `.claude/settings.json`: deny rules, a
fail-closed hook and the Bash sandbox. A session in such a work repo cannot
commit, push, read `.env` or the SSH key, change its own rules or leave
the sandbox; agents stage and diff, you commit and push. (The harness
checkout itself runs the lighter `center` role: same rules, no sandbox;
see below.) This works on any
Linux host with Nix. A managed host (the NixOS module) adds what only
root-owned settings can: mod policy and immunity to your own settings.

Pick the route for your host:

| Host | Route | Tested |
|---|---|---|
| Fedora 44 or newer, Ubuntu, any other Linux, with or without Nix | `scripts/install.sh` ("Any Linux" below): Nix if missing, then `harness bootstrap` for the user side and `harness init` for each repo | Fedora 44 and Ubuntu 26.10 laptops, end to end through `harness check` (2026-10-22) |
| NixOS, your own configuration | Your configuration provides direnv >= 2.38 (`pkgs/direnv.nix`), `devenv` and `programs.claude-code`, or `scripts/install.sh` adds this flake's packages to your profile: on NixOS it downloads nothing, writes nothing under `/etc` (it prints the `nix.settings` block when `nix.conf` lacks flakes or the devenv cache) and leaves home-manager's files alone, printing the option instead. Harness repos import `harness/devenv` as everywhere | NixOS 26.11 laptop, in daily use, this repo's own sessions included (2026-10-23); the install route only dry-run there |
| NixOS or NixOS-WSL, managed | NixOS module and home module, `harness.enable = true` and nothing else: every rule everywhere, strict network allowlist (`examples/nixos-host.nix`) | module and its tests; the module evaluates in `nix flake check` (2026-10-23); live on the NixOS-WSL laptop from 2026-10-23 until it moved to the plain route (2026-10-24), no native NixOS host yet |
| Windows 11, NixOS-WSL | `scripts/install-wsl.ps1 -HostRepo <your nixos-config>` from a checkout on Windows ("Windows" below): installs NixOS-WSL from the latest release, puts your flake at `/etc/nixos`, switches; rerun to pull and switch. The host is plain: `examples/nixos-wsl-plain.nix` carries only the sandbox prerequisites (user namespaces, bubblewrap and socat, flakes and the devenv cache, `allowUnfree`) plus tmux, and no `claude`. Then, inside the distro, `nix run github:bilibo/claude-nix-harness#harness -- bootstrap` and `harness init <customer>/<repo>` per work repo, as on any NixOS. The managed modules (previous row, `examples/nixos-wsl-host.nix`) are the stricter opt-in | Windows 11 Home 26H2, WSL 3.0.3 laptop: managed shape end to end through `scripts/wsl/verify.sh` (19 checks, 2026-10-23); plain shape evaluated (dry-run of both host outputs) and `verify.sh`'s unmanaged branch exercised, 2026-10-24; not yet switched in, bootstrap not yet run there |
| Mixed host | NixOS module with `enforcementRoots = [ "~/code/git" ]`: managed rules under the roots, your own settings elsewhere | available, superseded by the first two rows |
| macOS (nix-darwin) | managed settings under `/Library/Application Support/ClaudeCode/` | not started |

The first two rows and the Windows row are the unmanaged shape: the repo
file is the whole harness, and sessions outside harness repos keep whatever
your own settings allow. "Enforcement layers" below says what each layer
holds and what a repo cannot enforce on its own.

This checkout is also the command center: start a session in it (`ccmux`
inside the checkout) to launch sessions in the work repos with `ccmux
<customer>/<repo>`, read their staged diffs and maintain the harness. Its
`devenv.nix` sets `harness.role = "center"` (2026-10-24): a work repo's
deny rules and hook, except that it may write other repos' `devenv.nix`,
`devenv.yaml`, `devenv.lock`, `.envrc` and `.claude/` skills and hooks to
set them up (its own, and every repo's `.claude/settings*.json` and
`devenv.local.*`, stay refused), and no Bash sandbox. The center is open
by design; `harness.role = "work"` in its `devenv.nix` locks it down like
any work repo. Every Bash command
goes through Claude Code's permission prompt, a script there can read
`~/.ssh` and the other credential paths and reach any host, and
auto-memory is writable. It imports the harness module pinned from
GitHub, so its live rules move only when you bump its `devenv.lock`.
`docs/command-center.md` has what it can and cannot do and what the
sandbox no longer hides there.

`devenv/` is the project side: every repo imports it. A container route
was built and set aside; it lives in the claude-nix-harness-container repo,
whose README has what works and what was never verified.

Operating it: `docs/runbook.md`. What is next: `docs/roadmap.md`. What
changed when: `docs/changelog.md`. The tier and customer-module plan:
`docs/handoff-tiers.md`. How sessions coordinate without trusting each
other (tiers and proposals): `docs/sessions.md`. Changing a
project's tools, variables and rules without knowing Nix:
`docs/project-devenv.md`.

## Layout

```
lib/        pure Nix: deny rules (universal + project), settings.nix (one body for the managed and the repo copy), hooks packaging, managed-tree packaging
hooks/      env-guard.sh (the guard hook), tmux-notify.sh
nixos/      NixOS module: harness.* -> /etc/claude-code
home/       home-manager module: devenv, direnv, tmux, programs.claude-code, `ccmux`
devenv/     devenv module (devenv/devenv.nix) every repo imports: generates .claude/settings.json with deny rules, hooks and sandbox; `ccmux`
pkgs/       ccmux launcher, direnv >= 2.38 override, claude-code override (alsa-lib as a RUNPATH instead of an `LD_LIBRARY_PATH` every command inherits), the `harness` CLI (harness.nix; bodies under harness/: bootstrap.sh for bootstrap, upgrade, doctor and reset, init.sh, check.sh)
scripts/    install.sh: the one install route on Linux; what must happen before Nix exists (Fedora's packages, or the nix-installer), then `harness bootstrap`, then `harness init` on the checkout. install-wsl.ps1: the Windows route (NixOS-WSL from PowerShell), with wsl/bootstrap.sh, wsl/update.sh and wsl/verify.sh run inside the distro
examples/   nixos-host.nix (managed NixOS), nixos-wsl-plain.nix (plain NixOS-WSL, the default) and nixos-wsl-host.nix (managed NixOS-WSL): the host files a nixos-config flake imports
tests/      hook-test.sh (env-guard.sh unit tests), project-settings-test.sh (the generated repo file, plain and fenced), ccmux-test.sh, host-config-test.sh, install-test.sh and harness-bootstrap-test.sh (the install route with stubbed hosts), harness-doctor-test.sh, harness-init-test.sh, managed-tree-test.sh (the mod policy: no marketplace directory, the keys that refuse mods), claude-code-test.sh (the override: wrapper, RUNPATH, `--version`; unfree, so only when the evaluator allows it)
docs/       runbook (daily flow, onboarding, verification, troubleshooting), project-devenv (a project's devenv.nix for non-Nix users), command-center (this checkout as the session that orchestrates the work repos), roadmap, changelog, handoff-tiers (tiers, read fence, customer module, phased), sessions (tiers, proposals), suggestion (ideas with a shape, not planned)
```

## Any Linux: the install script

Needs git and sudo, and curl off Fedora. Tested on Fedora 44 and Ubuntu
26.10; any other Linux goes through the same nix-installer route as
Ubuntu and should work.

```
git clone https://github.com/bilibo/claude-nix-harness.git harness
cd harness
scripts/install.sh
ccmux
```

The script installs Nix where it is missing, then `harness bootstrap`
puts direnv, devenv, `ccmux` and `harness` into your profile and writes
the user files, then `harness init` builds the checkout's own shell. It
says what it did, and running it again installs nothing twice. The
runbook's host table lists every file it touches. On Ubuntu 23.10 and
later AppArmor confines user namespaces; bootstrap offers the bwrap
profile from the Claude Code sandboxing docs (`/etc/apparmor.d/bwrap`)
and, until it is in place, every Claude command is refused.

Afterwards: `harness doctor` reports every prerequisite, `harness
upgrade` moves the profile to this checkout's `flake.lock` after a `git
pull`, `harness reset` reverses what bootstrap wrote. The managed layer
(the NixOS module, or `nix build .#managed` linked at `/etc/claude-code`
on another distro) is the step beyond this when you want rules your own
settings cannot undo.

Another project that imports `harness/devenv` gets the same shell contents
with `harness.claudeCode.enable = true` in its devenv.nix and
`allow_unfree: true` in its devenv.yaml; `harness init <customer>/<repo>`
writes one and does its first shell entry. On a host with no `claude` of
its own (the plain WSL host, where Claude Code is the VS Code extension's
bundled binary) init writes both lines uncommented, so the repo's shell
brings the CLI, tmux and jq for `ccmux` sessions; with a host `claude` it
leaves both commented out.

## Windows: NixOS-WSL from PowerShell

Windows 11 22H2 or newer with WSL 2.4 or newer from the Store
(`wsl --install --no-distribution` once, then reboot). From a checkout of
this repo on Windows:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-wsl.ps1 -HostRepo https://github.com/you/nixos-config
```

`-HostRepo` is your NixOS configuration flake (a git URL, or a folder on
this machine for the first install). It imports NixOS-WSL and carries the
sandbox prerequisites and no harness module; `examples/nixos-wsl-plain.nix`
is the host file. The script downloads the latest NixOS-WSL release and
checks it against the published sha256, registers the distro, makes
`/etc/nixos` a git checkout of your flake owned by the default user, builds
`nixosConfigurations.<name>` (`-Output`, default `nixos-wsl`) as that user
and activates it as root, applies the host repo's `windows/wslconfig` as
your `.wslconfig`, restarts WSL and runs `scripts/wsl/verify.sh` (on a plain
host it skips the managed-layer checks, checks tmux, and reports direnv,
devenv, ccmux and claude without judging them). Running it again is the update: `git pull
--ff-only` and switch, never a commit on the box. `-NoSwitch` builds and
prints the activation commands instead; `-Tag` picks a NixOS-WSL release.
The image only bootstraps; afterwards NixOS and NixOS-WSL move through your
flake's inputs.

Then, inside the distro, as yourself: `nix run
github:bilibo/claude-nix-harness#harness -- bootstrap` (the NixOS path:
nothing under `/etc`, the `nix.settings` block printed if it is missing),
then `harness init <customer>/<repo>` for each work repo. Leave `~/.bashrc`
to the user rather than home-manager: bootstrap skips a store-symlinked rc
file and only prints the option. For rules everywhere, the managed layer is
the opt-in: import this repo's NixOS and home modules as well
(`examples/nixos-wsl-host.nix`).

The plain host carries tmux but deliberately no `claude`: Claude Code is
the VS Code extension on Windows, which runs its bundled binary inside WSL
over Remote-WSL (nix-ld runs it), and that is enough for interactive use.
For tmux and `ccmux` sessions a work repo brings its own CLI `claude` (and
tmux) through `harness.claudeCode.enable` in its `devenv.nix`, which
`harness init` writes when it finds no `claude` on the host PATH; `ccmux`
takes `claude` from your PATH, else from the target repo's shell.

What a session gets on WSL is in `lib/settings.nix` (`platform = "wsl"`,
set by `harness init` in the repo, auto-detected by the NixOS module on a
managed host): `/mnt/c` and `/run/WSL` hidden and `WSL_INTEROP` stripped,
so it can neither read Windows files nor run Windows executables. The host
file keeps the Windows PATH off the Linux PATH for the same reason, and for
speed.

## Enforcement layers

Each Claude Code mechanism covers a different surface, so all are used:

1. The repo's `.claude/settings.json` (devenv module, read-only store
   symlink): the full deny set, every hook, the sandbox, bypass mode
   disabled. Deny lists and sandbox deny entries merge across scopes, so no
   user or local file can remove one; the hook and the sandbox keep the
   agent from rewriting the file or `.claude/settings.local.json`.
   `harness.enable = false` in the repo's `devenv.nix` removes this layer
   for that repo.
2. Managed settings (root-owned, managed hosts): the same body plus the
   managed-only keys. Nothing in `~/.claude` or a repo can relax them.
3. `permissions.deny`: prefix/glob matching, all modes, final against
   user-tier mods on a managed host because the managed settings make the
   built-in guard load. Cannot be scoped by directory, so with
   `enforcementRoots` set the managed copy carries only the universal rules.
4. `env-guard.sh` PreToolUse/ConfigChange hook: normalised whole-command
   regex (`bash -c`, `env`, `git -C`, quoted words), config-file edit block,
   shell-side config writes, settings-change block, nested `claude` launch
   flags that would skip the repo's rules. Sees `cwd`, so project rules apply
   only under the enforcement roots when there are any. `onFailure: block`.
5. Bash sandbox (bubblewrap): filesystem and egress confinement for
   everything `az`, `terraform`, `tflint`, `trivy` do at runtime. Works
   nested inside `vscode-fhs`. Off in the command center (`harness.role =
   "center"`), where Claude Code's permission prompt takes its place;
   managed settings keep it on there too.
6. Mod policy (managed only): no mod loads: the harness ships none (since
   2026-10-24) and the built-in guard refuses every other; no marketplace
   can be added beyond `extraKnownMarketplaces` (none by default); sideload
   flags rejected.
7. Azure RBAC: a Reader-only identity per customer (outside this repo).

Universal rules (everywhere on a managed host): credentials, `sudo` and
system changes, plugin loading, Windows executables, the user's own
Claude/Nix/shell config. Project rules (under the roots, or everywhere in a
repo that imports the devenv module): git history writes, cloud writes,
project config and env files, the SSH agent and key files, nested sessions
with their own settings.

### What a repo cannot enforce on its own

Without managed settings, these stay with the human who launches the
session; the hook catches them only for a nested `claude` started from
inside a session.

- `allowManagedHooksOnly`, `strictKnownMarketplaces`, `disableSideloadFlags`
  and the built-in mod guard's option are read from managed settings only.
  The guard that makes deny rules final against user-tier mods does not
  load at all without managed settings.
- `sandbox.network.strictAllowlist` is user-or-managed scope; the bootstrap
  writes it into the user-scope `~/.claude/settings.json`.
- `claude --setting-sources user`, `--settings`, `--bare` or a session
  started above the repo load none of the repo's rules; `--plugin-dir`
  loads the rules but also an unvetted plugin. Inside a session the hook
  refuses these flags on a nested `claude`.
- A `.claude/settings.local.json` that exists at session start outranks the
  repo file for scalar keys (`disableAllHooks`, `sandbox.enabled`). The
  agent cannot create one (Edit deny, hook, sandbox denyWrite); the human
  can.
- Project hooks and allow rules wait for the folder trust dialog in an
  interactive session; `-p` treats the folder as trusted.
- With the sandbox on, Claude Code runs Bash commands without a permission
  prompt (`autoAllowBashIfSandboxed`, default true). Inside a repo the deny
  rules, the hook and the sandbox are the gate, not the prompt. In the
  command center the sandbox is off and the prompt is the gate.
- Skills and plugins synced from the claude.ai account: `syncClaudeAiSkills`
  and `syncClaudeAiPlugins` are user-or-managed scope, so a `false` in the
  repo file is ignored; `harness bootstrap` writes both `false`s at user
  scope, by default since 2026-10-24 (`--account-sync` leaves sync on). The
  account's connectors (Gmail, Drive, Notion, ...) are the exception:
  `disableClaudeAiConnectors` holds from any scope, so the repo file turns
  them off (`harness.allowConnectors` turns them back on per repo).

### Lockdown level today

What a session gets on each host shape, with the repo file as written by
the devenv module (2026-10-20, Claude Code 2.1.304). "Prompted" means the
human at the terminal decides; a `-p` session treats a prompt as a refusal.

| | Unmanaged host (in use) | Mixed host | Managed host |
|---|---|---|---|
| Enforced | deny rules; the fail-closed hook on every writing tool and settings change; the Bash sandbox with no unsandboxed fallback; bypass mode off; `~/.ssh` and the agent socket hidden; account connectors off | the same inside the roots; plus mod policy and the built-in guard | the same everywhere; plus the strict network allowlist and immunity to user settings |
| Enforced since 2026-10-21 | the strict network allowlist (user-scope key written by the bootstrap); the repo's own settings, hooks, skills, plugin manifest and `.git` hooks and config as literal `denyWrite` paths; the GitHub tokens stripped from every subprocess (`credentials.envVars`; the `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` scrub is off since 2026-10-22, in user scope it turns the sandbox's Bash auto-allow off) | the same | the same |
| Prompted | edits outside the working directory | network hosts outside the allowlist (`sandboxStrictAllowlist = false`) | nothing in the sandbox: unknown hosts are refused |
| Open | reads of the whole home and of sibling repos except the `denyRead` paths (`~/.azure`, `~/.gnupg`, `~/.terraform.d`, `~/.netrc`, `~/.ssh`, and since 2026-10-21 `~/.aws`, `~/.config/gh`, `~/.git-credentials`); every unix socket (D-Bus, the display, the secret service); account-synced skills and plugins where the bootstrap ran with `--account-sync`, or has not run since 2026-10-24; the user's own marketplace; `/add-dir`; environment variables not named in `credentials.envVars` typed by the human; dynamic shell constructs (runbook section 8) | the same, minus the marketplace | the same, minus the marketplace and the synced skills |

The table describes a work repo (`harness.role = "work"`, the default).
The command center (this checkout, `harness.role = "center"`, since
2026-10-24) keeps the deny rules and the hook, other repos' setup files
apart, but has no sandbox. Every
Bash command is prompted instead (none once the owner allows `Bash(*)`),
there is no network allowlist, and a script reaches the credential paths,
the secret variables and any file you can write; only the hook's text
rules and the Read tool's deny rules still name them
(`docs/command-center.md`, section 5). On a managed host the managed
sandbox stays on in the center too.

The glob `denyWrite` entries (`**/...`) have no effect on Linux and stay
for macOS; the repo copy repeats them as literal paths under the checkout
(`repoRoot` in `lib/settings.nix`), and `~/.claude` plus Claude Code's own
protections for the working directory hold as before. Closing the open
items, in order, is the "sandbox hardening" entry of the roadmap.

## Usage

Every repo the harness should govern, on every host:

```yaml
# a repo's devenv.yaml
inputs:
  harness:
    url: github:bilibo/claude-nix-harness   # or path:/path/to/claude-nix-harness while developing
    flake: false
imports:
  - harness/devenv
```

```nix
# the repo's devenv.nix
harness.settings.permissions.allow = [ "Bash(terraform plan *)" ];  # project allow rules
harness.extraAllowedDomains = [ "dev.azure.com" ];                   # sandbox allowlist, unmanaged host only (see below)
harness.allowMemoryEdits = true;                                     # Claude keeps its auto-memory (off by default in a work repo, on in the center)
```

```
# the repo's .worktreeinclude: `claude --worktree` sessions start in
# .claude/worktrees/<name>, where only the files listed here exist.
.claude/settings.json
```

The devenv module writes the repo's `.claude/settings.json` (read-only
symlink into the store) at every shell entry: deny rules, hooks, sandbox,
SSH rule, bypass mode disabled. Repos outside the harness do not import it.
A repo that imports it can still turn the guard rails off with one line in
its `devenv.nix`, `harness.enable = false;`, then `direnv allow`: no
`.claude/settings.json`, so none of the repo's deny rules, hook or sandbox,
and a notice at every shell entry; the packages stay, and a managed host's
root-owned settings still apply. Only the owner can set it: the deny rules
and the hook refuse an agent's edits to `devenv.nix`
(`docs/project-devenv.md`, "Turning the guard rails off (and on)").
The host needs direnv >= 2.38 for `require_allowed` in `.envrc` (the
locked nixpkgs, 2026-10-14, ships 2.37.1; `pkgs/direnv.nix` is the
override), `devenv` on PATH,
and `bubblewrap` and `socat` with user namespaces enabled for the sandbox
(`failIfUnavailable` refuses to start a session without it). The home
module below brings the first two; on an unmanaged host they come from
your own configuration, or from this flake, pinned by its lock:
`nix profile add path:<checkout>#direnv path:<checkout>#devenv
path:<checkout>#ccmux`, and `path:<checkout>#claude-code` when Claude
Code itself comes from Nix: nixpkgs' wrapper exports an `LD_LIBRARY_PATH`
that every hook, command and MCP server inherits and that kills a distro
binary loading libasound (`pkgs/claude-code.nix` carries the library as a
RUNPATH instead; the home and devenv modules use it). `scripts/install.sh` does the root steps `nix
run` needs (on Fedora 44 or newer the `nix` and `nix-daemon` packages, the
SELinux label and the daemon socket; elsewhere the nix-installer) and
hands over to `harness bootstrap`, which adds direnv, devenv, ccmux and
`harness` itself to the profile and writes the user files; `harness
doctor` reports every host prerequisite afterwards, `claude doctor`
included, and `harness init <customer>/<repo>` writes the files above
into a repo and runs its first shell entry. `nix run
path:<checkout>#harness -- <command>` runs it from a checkout.

A managed host makes the sandbox admin-required, and Claude Code then
ignores a repo's `network.allowedDomains` and `filesystem.allowWrite`
entries: there, extra domains go in the NixOS module's
`harness.extraAllowedDomains`. Deny entries from the repo apply everywhere.

A managed host adds the managed layer:

```nix
# flake.nix of your NixOS configuration
inputs.harness = {
  url = "github:bilibo/claude-nix-harness";
  inputs.nixpkgs.follows = "nixpkgs";
};

# NixOS
imports = [ inputs.harness.nixosModules.harness ];
harness.enable = true;                       # platform auto-detects wsl vs linux
# Mixed host only:
# harness.enforcementRoots = [ "~/code/git" ];
# harness.sandboxStrictAllowlist = false;
# harness.allowMemoryEdits = true;           # Claude keeps its auto-memory

# home-manager
imports = [ inputs.harness.homeModules.harness ];
harness.enable = true;
```

While changing the harness itself, build the host from a checkout instead
of the locked revision:
`nixos-rebuild switch --override-input harness path:/path/to/claude-nix-harness`.

### Where project configuration goes

Agents never read `.env`: the sandbox mounts it as `/dev/null` and the hook
refuses commands that name it. So split a project's settings by what they
are, not by where a dotenv file would have put them:

| What | Where | Who sees it |
|---|---|---|
| Identifiers the tools need: tenant, subscription, client and resource IDs, region, environment name | `devenv.nix`, `env.ARM_TENANT_ID = "..."` and friends, committed | you and the agent, exported into every command by the devenv shell |
| The same, per developer or not for the repository | `devenv.local.nix`, gitignored; devenv imports it on its own | you and the agent; the agent cannot create or change it |
| Secrets: client secrets, tokens, passwords | `.env`, loaded into your shell with devenv's `dotenv.enable = true` (direnv's own dotenv loading is off on a harness host), or your `az login` session | you only; the agent's preamble loads an empty file, and `ARM_CLIENT_SECRET`, `AZURE_CLIENT_SECRET` and the GitHub tokens are stripped from its environment either way |

A project that keeps its IDs in `.env` today sees `az` and `terraform plan`
fail inside the sandbox until those lines move to `devenv.nix`.
`docs/project-devenv.md` has the `env.` lines, and tools, toolchains,
allow rules and network hosts the same way.

## Git over SSH

Agents never push; you do, from your own tmux window or editor terminal.
Both run as the same user, so the key has to be unusable for a session
without being unusable for you. Two kinds of key do that, pick one per
machine; both need you present for every signature.

**Hardware key, recommended.** A FIDO2 token (YubiKey, Nitrokey, SoloKey).
The private key never leaves the token, every signature needs a touch, and
with `verify-required` a PIN too. The key handle may live in an agent: an
agent cannot touch the token for anyone. There is nothing on the machine to
steal, so even a session that escaped the sandbox could not sign.

```
ssh-keygen -t ed25519-sk -O resident -O verify-required -C "$USER@$(hostname)"
```

`-O resident` keeps the key on the token, so another machine gets it back
with `ssh-keygen -K`. The passphrase prompt may be left empty: the token and
PIN are the protection. GitHub, GitLab and Codeberg all accept `-sk` keys.

**Passphrase key, fallback.** For hosts and people without a token. The
passphrase is the protection, so it is asked on every use and the key is
never cached in an agent. A session has no terminal to answer the prompt,
which is what makes the key useless to it.

```
ssh-keygen -t ed25519 -a 100 -C "$USER@$(hostname)"
```

Choose a real passphrase at the prompt. Never pass `-N`: it puts the
passphrase in shell history and process lists. Then keep ssh away from every
agent for the hosts that use this key, in `~/.ssh/config` or
`programs.ssh.matchBlocks`:

```
Host github.com
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  IdentityAgent none
```

`IdentityAgent none` is the line that matters. Desktop keyrings (GNOME and
COSMIC's gcr, KDE) run an agent that loads keys from `~/.ssh` on first use
and offers to remember the passphrase; with this line ssh never asks them.
Never set `AddKeysToAgent yes` for this key. Check with `ssh-add -l`: the
passphrase key must not be listed. If it is, `ssh-add -d ~/.ssh/id_ed25519`
removes it, and a remembered passphrase is cleared with
`secret-tool clear unique "ssh-store:$HOME/.ssh/id_ed25519"` (package
`libsecret`).

**Register the public key** (`id_ed25519_sk.pub` or `id_ed25519.pub`).
Print it, paste it under GitHub Settings, SSH and GPG keys, New SSH key
(Codeberg and GitLab: Settings, SSH keys), then test:

```
cat ~/.ssh/id_ed25519.pub
ssh -T git@github.com
```

With the GitHub CLI installed, `gh ssh-key add ~/.ssh/id_ed25519.pub` does
the paste (it needs the `admin:public_key` scope: `gh auth refresh -s
admin:public_key`). Nothing here requires it.

**What to expect.** Every push asks: a touch (and PIN) for the hardware key,
the passphrase for the software key. A push that goes through silently means
the key is cached somewhere; see the `ssh-add -l` check above.

**In a harness repo** the sandbox also strips `SSH_AUTH_SOCK` from every
agent command and hides `~/.ssh`, so a session there cannot even reach the
hardware key's handle. The repo's `.claude/settings.json` carries the rule
(`lib/ssh-sandbox.nix`); managed settings carry it too on a host that
enforces everywhere. A session that runs `git push` there gets
`Permission denied (publickey)`; sessions clone over HTTPS.

## Tests

```
nix flake check              # hook unit tests (both managed trees), the generated repo file, ccmux resolution, the install route with stubbed hosts, doctor and init, the check parser, the NixOS module evaluated
nix build .#managed-scoped   # a managed tree to inspect: result/managed-settings.json
nix build .#project-settings # the repo's .claude/settings.json with default options
```

Hook tests run without Claude Code: they feed hook JSON on stdin and check
the exit code. `project-settings-test.sh` asserts every layer the repo file
must carry and runs each hook it names. Add a case per hard limit you rely
on.

Live, with Claude Code, on an unmanaged host (runbook section 5 has the
from-zero sequence):

```
harness doctor                  # host prerequisites and, inside a repo, its settings symlink and hooks; exit 1 when one is missing
harness init <customer>/<repo>  # writes a repo, enters its shell, runs both unit tests on the result
harness check <repo>            # fourteen `claude -p` sessions (sixteen in a fenced repo, seven in the command center), judged on transcripts and files; costs API calls
```
