# Handoff: tiers, read fence, customer module, ccmux subcommands

For a Claude Code session started in this repo, and for Raul reviewing its
plans. Written 2026-10-18 from an inventory of this repo, of
`~/nixos-config` and of the Claude Code 2.1.296 docs; sections 1 and 2
re-checked 2026-10-20 after the laptop moved from NixOS to Fedora and the
`scripts/` directory arrived. It replaces the Perplexity plan
"nix-ccode-harness and ccmux": that plan assumed one repo, a WSL host and a
hand-written sandbox wrapper, none of which is the case here. Section 1
says what is already done, section 2 what is true on disk, section 4 what
to build, in phases; `docs/roadmap.md` keeps the overall order and points
here for the tier work.

Rules for the session: read, propose the file list for a phase, wait for
approval, implement, stop. Do not activate any NixOS or home-manager
generation. Do not change flake inputs without asking. A bare `nix flake
check` fails inside a session (the sandbox masks `.gitmodules` and shell
startup files in the working directory); `nix flake check path:<harness
checkout>` works from the test repo (2026-10-20), and Raul runs the git
form before committing. A session cannot commit, and the hook refuses
edits to `devenv/devenv.nix` (its pattern matches any `devenv.nix`),
`devenv.yaml` and `.envrc`; propose those as diffs.

## 1. Already done from the nixos-config session (2026-10-18)

In this repo, committed: `ccmux` replaces `ccode`; the `ccode` entry point was dropped on 2026-10-21.

In `~/nixos-config`, uncommitted:

- The working-style rule moved out of `modules/claude-doc-quality/` into
  its own home-manager module `modules/claude-working-style/`
  (`programs.claude-working-style.enable`, exported as
  `homeModules.claude-working-style`). Doc-quality now carries
  documentation concerns only. It is a personal preference of Raul's, so it
  lives in nixos-config, not in a harness tier; if the work host should
  carry it too, the WSL base config imports that module.
- The doc-quality eval fixtures were gone from `/tmp`; they were recreated
  from the assertions in `evals/evals.json` under
  `modules/claude-doc-quality/evals/fixtures/`.

## 2. Inventory: what is on disk

**Launcher.** `pkgs/ccmux.nix`, a `writeShellApplication`. Resolves
`<customer>/<repo>` from the argument, else `HARNESS_PROJECT` (exported by
the devenv module's `enterShell`), else the cwd under `HARNESS_CODE_ROOT`
(default `~/code/git`). Creates or attaches tmux session `<customer>-<repo>`,
opens one window per call running `claude <args>; exec $SHELL`. Assumes
`tmux` (runtime input) and `claude` on the PATH of the tmux window. Knows
nothing about direnv or devenv: the hook's `CLAUDE_ENV_FILE` preamble runs
`direnv export bash` before every Bash command. No `doctor`, `new`,
`upgrade` or `platform` subcommand exists on `ccmux`; since 2026-10-20 the
work they were to do lives in the `harness` CLI (`pkgs/harness.nix`, one
command since 2026-10-21, three scripts the day before): `harness doctor`
is the host doctor, `harness init` is `new` without the customer registry
and templates, `harness upgrade` is `upgrade`, `harness check` is the
limits suite's first cut. Phases 1, 4 and 5 below build on that rather
than on `ccmux`.

**Settings.** One body, `lib/settings.nix`, two destinations:
`managed = true` for `/etc/claude-code/managed-settings.json` (NixOS module
`nixos/default.nix`, `environment.etc`), `managed = false` for the repo's
`.claude/settings.json` written by the devenv module as a read-only store
symlink at every shell entry. On the laptop only the repo copy exists: no
`/etc/claude-code`, no harness modules (the Fedora host has none; the
NixOS configuration before it dropped them on 2026-10-18). Deny rules in
`lib/deny-rules.nix`, universal plus project sets. Hooks: `env-guard.sh` on
SessionStart, CwdChanged, FileChanged, ConfigChange and PreToolUse
(`onFailure = "block"`), `tmux-notify.sh` on Notification and
UserPromptSubmit. `permissions.blockReadsOutsideWorkingDirectories` is not
set anywhere.

**Sandbox.** Claude Code's built-in bubblewrap sandbox, configured in the
same settings body (`sandbox.*`), not a wrapper script. `allowWrite`
`~/.cache/nix` and `~/.cache/devenv`; `denyWrite` `~/.claude`, `~/.config`,
`~/.azure`, `~/.ssh`, git hooks and config, every `.claude/settings*.json`,
hooks, skills and plugin manifests; `denyRead` `~/.azure`, `~/.gnupg`,
`~/.terraform.d`, `~/.netrc`, plus `~/.ssh` as a project rule, plus
`/run/WSL` and `/mnt/c` when `platform = "wsl"`. `WSL_INTEROP`,
`ARM_CLIENT_SECRET`, `AZURE_CLIENT_SECRET`, the GitHub tokens,
`SSH_AUTH_SOCK` and `SSH_AGENT_PID` denied as env vars, and
no `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` for the rest (ignored in a repo
file; in user scope it turns the sandbox's Bash auto-allow off,
2026-10-22). The
repo copy adds its protected paths except `devenv.local.*` as literal
`denyWrite` entries under `config.devenv.root` (a literal entry is masked
unreadable, and devenv reads those two; 2026-10-22). `allowAllUnixSockets = true` (go-plugin,
Nix daemon). `bubblewrap` and `socat` come from the host's system packages.
`disableClaudeAiConnectors = true` since 2026-10-20 (`allowConnectors`
option). What the sandbox does not do (open reads, every unix socket;
the network is strict once the bootstrap has written the user-scope key)
is in runbook section 8 and ordered as roadmap item 2; phase 2 below is
the read-fence part of it.

**devenv-base.** Does not exist. There is one devenv module,
`devenv/devenv.nix`, imported as `harness/devenv`. It exports options `harness.*`
(allowLocalCommits, allowMemoryEdits, platform, extraDeny,
extraAllowedDomains, settings, managedSettingsPath, claudeCode.enable), writes the
settings file, ships `ccmux` in the shell, exports `HARNESS_PROJECT`. No
repo sets `AZURE_CONFIG_DIR`. The harness checkout itself lives outside the
code root (`~/code/claude-nix-harness`) and has no `.envrc`, so a session
there is not governed; the governed test repo is
`~/code/git/raul/harness-test`, written by `harness init` with a
`path:` harness input. `raul/azfn-rust-handler`'s `devenv.yaml` still
points at `git+file:///home/raul/nixos-config?dir=harness`, which no longer
exists. Raul edits it (the hook forbids a session doing so).

**Versions.** Claude Code 2.1.304 on the Fedora host (native install,
`autoUpdates` off); the settings keys were last checked against 2.1.296.
This repo pins nixpkgs in `flake.lock` (2026-10-14; direnv 2.37.1 there,
so `pkgs/direnv.nix` is in use). No container engine is assumed anywhere.

**Host.** The laptop runs Fedora 44 (unmanaged host shape), set up by
`scripts/install.sh` and `harness bootstrap`: Fedora's `nix` and `nix-daemon` packages,
no `trusted-users`, SELinux enforcing with the daemon socket directory
labelled `var_run_t`, `NIX_SSL_CERT_FILE` exported. The NixOS facts below
apply to a managed host. `platform = "wsl"` is implemented but has never
run live. The hook regexes and deny rules deny `nixos-rebuild`,
`home-manager switch`, `nix profile`, `nix-env`, `nix-channel`,
`nix-collect-garbage`, `systemctl`, `sudo`. Nothing denies `nh`: `nh os
switch` and `nh home switch` pass both layers on a NixOS host.
`nixos-rebuild` is denied as a whole, `build` included. On Fedora, `dnf`
is not denied by name; `sudo` is, which is what `dnf install` needs.

**Docs, checked 2026-10-18 against code.claude.com/docs.**

- `permissions.blockReadsOutsideWorkingDirectories` exists (2.1.257+),
  boolean, settable from any scope; a `true` anywhere wins and no lower
  scope lifts it. It makes Read, Grep, Glob and LSP refuse paths outside the
  working directories in every permission mode. It does not cover Bash:
  `cat ~/code/git/other/x` inside the sandbox still works unless the sandbox
  hides the path. Additional directories (`additionalDirectories`,
  `--add-dir`, `/add-dir`) count as working directories.
- Managed settings cannot lock `additionalDirectories` or disable `/add-dir`
  and `--add-dir`; `disableSideloadFlags` covers plugin, agent and MCP flags
  only. The `DirectoryAdded` hook fires after the fact and cannot block.
  `allowManagedPermissionRulesOnly` drops parent-supplied allow rules and
  additional directories; the docs do not say it drops them from user or
  project files. So: the hook refuses `--add-dir` on a nested `claude`
  (same list as `--settings`, `--bare`), and a human typing `/add-dir` in
  their own session is an accepted gap, recorded as such in the limits
  suite.
- `Read(~/path)` and `Read(//absolute)` deny rules work; a Read deny also
  blocks Edit and Write there, and Grep and Glob best-effort. A single
  leading `/` is project-relative.
- Managed scope is host-wide. Per-directory policy means a different
  generated settings file per repo, which is what the devenv module already
  does.
- `sandbox.filesystem.denyRead` applies to sandboxed commands only; the
  docs do not say what a read of a denied path returns, and do not cover
  `/mnt/c` behaviour. The roadmap's "empty inside the sandbox" claim is an
  observation to verify on a WSL host, not a documented guarantee.

## 3. Where the Perplexity plan is wrong

- One repo: the harness and the laptop config are two repos, and the
  laptop imports nothing from the harness. Nothing from the harness goes
  into nixos-config except what Raul copies by hand.
- `modules/tiers/*.nix`, `modules/managed-settings.nix`, `pkgs/ccmux/`,
  `devenv-base/`, `tests/limits/`: the existing layout is `lib/`, `hooks/`,
  `nixos/`, `home/`, `devenv/`, `pkgs/`, `tests/`, `docs/`. Keep it; add a
  tier parameter to `lib/settings.nix`, a `devenv/customer/` module and
  `tests/limits/`.
- "Bash sandbox wrapper", "which paths it binds": Claude Code's own sandbox
  via settings keys. There is no wrapper to invoke.
- "Managed settings are root-owned, generated by NixOS environment.etc":
  true for the module, false for the laptop, where nothing is deployed. The
  managed layer is the future WSL work-host shape.
- "The doc-quality module ... also carries a working-style rule": not any
  more, see section 1.
- "Deny ... writes under /etc": the sandbox write policy is cwd plus
  `allowWrite`; `/etc` is already unwritable, and root-owned anyway.
- `HARNESS_TIER` with values `platform` or `agent` conflates two axes: the
  tier of the repo (platform or customer) and who is in the shell (the agent
  under `ccmux`, or Raul in his own terminal). Use `HARNESS_TIER` for
  platform/customer and derive the actor from `CLAUDECODE` (Claude Code sets
  it in the Bash tool's environment; verify in a live session before
  relying on it) for the `-agent`/`-human` suffix of `AZURE_CONFIG_DIR`.
  Realised 2026-10-24 as `HARNESS_ROLE` (`work`/`center`), from the devenv
  shell rather than `ccmux` (phase 2).
- "`nh os switch` is refused in both tiers": false today, see Host above.
- "Podman is the container engine": removed; nothing depends on it.
- `claude plugin validate` is denied by the universal `claude plugin` rule;
  a platform tier that allows it needs the rule split into
  `claude plugin install|marketplace|...` and the hook regex changed too.
  Moot since 2026-10-24: the harness ships no mods (`docs/sessions.md`
  section 5), so no tier has anything to validate and the rule stays whole.

## 4. Phases

Each phase: file list first, approval, implement, tests as cases in
`tests/` for Raul to run with `nix flake check`.

### Phase 1: housekeeping and `harness doctor`

- Done 2026-10-23: `nh` in the system set of `lib/deny-rules.nix` and the
  hook's system regex (`nh os switch|boot|test`, `nh home switch`);
  `nh os build`, `nix build`, `nix flake check` pass. `nixos-rebuild` stays
  denied as a whole, `build` included, until Raul says otherwise. Test
  cases both directions (hook-test).
- Done 2026-10-23: `--add-dir` in the hook's nested-`claude` flag list,
  with tests.
- `harness doctor` exists since 2026-10-21: the host report, `claude
  doctor` (Claude Code's own read-only diagnostics), the cwd repo's
  `.claude/settings.json` symlink (present, dangling, which store path),
  its direnv approval and the hooks it registers; plain text, one line per
  item, exit 1 when something it needs is missing. Still to add:
  `HARNESS_CODE_ROOT`, `HARNESS_PROJECT` and the cwd's `HARNESS_ROLE`
  (phase 2). `ccmux -n` stays as it is.
- Update the runbook's verification section to start with `harness doctor`.

Tests: `nix flake check` passes; `harness doctor` output pasted by Raul
from the laptop.

### Phase 2: tiers and the read fence

Partly realised on 2026-10-24 as `harness.role` (`docs/command-center.md`,
`docs/sessions.md` section 3). The plan was two tiers chosen by `ccmux`
from the cwd (`ccmux platform`, or a cwd under a configured platform root
such as `~/nixos-config` or this repo, gives `platform`; a cwd under
`HARNESS_CODE_ROOT` gives `customer`; anything else refuses to start),
`HARNESS_TIER` in the tmux window, a read fence common to both, and for
platform roots without a devenv a generated file passed by `ccmux` as
`--settings <store path>` on the outer `claude`.

What the role gives:

- The tier is the repo owner's devenv option, `harness.role = "work"`
  (default, the customer tier) or `"center"` (the platform tier, this
  checkout), exported by the shell as `HARNESS_ROLE` and carried by
  `ccmux`, which names the tmux window after it and does not pass
  `center` on to a work session it launches. No platform roots, no `ccmux
  platform`.
- `center`: the same deny set and hook as `work`, git rules included
  (decision 3 below), the sandbox off (Bash prompted, no allowlist, no
  confinement), memory on, read fence off, the lint tools in the shell.
  The checkout imports the module pinned from GitHub like a work repo, so
  its live rules move with `devenv.lock`, not with the working tree.
- `work`: the existing module output, unchanged; `harness init` refuses a
  repo that sets `center`.
- The hook refuses `ccmux` with the launch flags it refuses on a nested
  `claude` (rule 6).

Still open:

- The managed host. A managed `sandbox.enabled = true` wins over the repo
  file and cannot be scoped by directory, so there `center` turns nothing
  off: the center keeps the sandbox, and `ccmux` from it meets the tmux
  socket again (roadmap 2.8). Whether a managed host has a center at all,
  and whether its managed layer limits `center` to configured platform
  roots (the plan's roots, as a NixOS option), is undecided.
- Platform roots without a harness devenv (`~/nixos-config`): no role, no
  generated file; the `--settings` route was not built. Its deny set as
  planned: universal, the `claude plugin` rule whole (the `validate`
  exception went with the broker mod, 2026-10-24), the git rules if Raul
  wants them there. Cloud tools on its PATH stay decision 2.
- The read fence. `readFence` exists for work repos (roadmap 2.1), off by
  default; `permissions.blockReadsOutsideWorkingDirectories` is set
  nowhere, and the center must not set it: it reads the work repos.
- `harness doctor` reporting the role (phase 1).

Tests (unit): `project-settings-center-test` (the center's file: sandbox
off with only the credential list under it, every other check a work
repo's), `devenv-module-eval` (`role = "center"` writes exactly that file,
exports `HARNESS_ROLE=center`, adds the lint tools; `work` is the
default), the `ccmux` cases in `hook-test`. `nh os switch` is denied in
both roles (phase 1). Live cases go to phase 5.

### Phase 3: `devenv/customer` module

`imports: - harness/devenv/customer` next to `harness/devenv`. Options as
in the Perplexity plan (`customer.name`, `tenantId`, `subscriptionId`,
`agentAuth`, `allowWrite`, `lang`). Behaviour:

- `AZURE_CONFIG_DIR` under `$(git rev-parse --git-common-dir)/devenv-base/azure-<actor>`
  so worktrees share it; `Read(**/.git/devenv-base/**)` is already denied.
  Actor from `CLAUDECODE` as above.
- `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID`, `CUSTOMER_NAME` exported;
  `ARM_CLIENT_SECRET` stays a denied env var.
- `scripts.az-login`: `az login --tenant <id> --use-device-code` then
  `az account set`; for `agentAuth = "sp"` read the sops path the bootstrap
  wrote. Never in `enterShell`. Note that `az login` and `az account set` are
  in the universal deny set, so only Raul runs this script, which is the
  intent.
- `enterShell`: compare `az account show --query tenantId` with
  `customer.tenantId`, one-line warning on mismatch or when not logged in,
  exit 0, no prompt.
- Hook extension: a `customer` branch in `env-guard.sh` that, before
  `az`, `terraform apply|destroy`, `pulumi up`, compares the live tenant and
  subscription with `ARM_*` and denies on mismatch; `allowWrite = false`
  denies apply and destroy outright (today the project rules deny them
  unconditionally; `allowWrite = true` would need an allow path, which is a
  policy change for Raul to confirm).
- `lang` picks toolchain packages and the README template.
- The doc-quality plugin for cloud sessions: it is built from nixos-config
  (`packages.claude-doc-quality`), which the harness must not depend on.
  Options: move the plugin to this repo, or give the devenv module a
  `harness.plugins` list of store paths it links under `.claude/skills/`.
  Ask Raul before choosing. Since 2026-10-24 the harness ships no plugins
  or mods (`docs/sessions.md` section 5), which rules out the first option
  as a plugin; skills linked by the devenv module are still open.

Tests: a scratch repo built in a `nix flake check` derivation cannot run
devenv; write the module so its pure parts (env var attrset, hook branch)
are testable with the existing hook-test pattern, and give Raul a
`devenv shell` smoke list for the rest.

### Phase 4: `harness init` and `harness upgrade`

`harness init` already renders `devenv.yaml`, `devenv.nix`,
`.envrc`, `.gitignore`, `.worktreeinclude` and `CLAUDE.md`, does
`git init`, the two `direnv allow`s and the unit tests, with `--dry-run`,
`--force` for the harness-owned files and idempotent re-runs. What phase 4
adds, as the `init` subcommand of the `harness` CLI (in the roadmap's Done
list since 2026-10-21): the
registry at `~/code/git/<customer>/customer.toml`, the customer block in
`devenv.nix`, `README.md` and `.editorconfig`, the first commit, the two
`AZURE_CONFIG_DIR` directories, the template version recorded in
`devenv.yaml`, and `upgrade` showing the diff. Templates under
`devenv/templates/`. No `az login`, no secrets, no backend provisioning;
`--init-backend` explicit and human-identity only. Skip `--agent sp` sops
wiring until a customer actually needs a service principal; `user` is the
default.

Tests: `harness init test/scratch --dry-run` under a temp `HOME` renders
without writing; a real run there yields a repo where `direnv allow` and
`devenv shell` export the expected vars (Raul runs); a second run reports
no changes.

### Phase 5: limits suite

`harness check` is the first cut: twelve `claude -p` cases inside a
harness repo (thirteen with the read fence on), judged on the stream-json
transcript and the files afterwards, transcripts kept for the exact
refusal text, the first ten 10/10 on 2026-10-20. It is a `nix run` app,
not a flake check (it needs a live `claude -p` and the network). Phase 5
runs it inside a
scratch customer repo created by `harness init`, and adds the cases:
nested `claude --add-dir ..`, `nh os switch`, `nixos-rebuild switch`,
`home-manager switch`, Read of a sibling customer file and of a file
outside the code root, Read of another project's `~/.claude/projects/`
directory, a credential read through a reader the hook does not list
(sandbox audit), a sibling-repo read through the shell, `az login` in
platform tier, `terraform apply` with `allowWrite = false` and with a
mismatched subscription, write to `~/.claude/settings.json`, `/mnt/c` and
`/run/WSL` in customer tier on WSL only, `git push`, the `.devenv/shell-*.sh`
litter count over 50 commands. Human `/add-dir` is listed as accepted, not
tested. `harness doctor --full` runs it.

## 5. Decisions only Raul can make

1. Whether the harness should carry the working-style rule (now a
   nixos-config module) for the work host, or the WSL base config imports
   it from nixos-config.
2. Platform-tier cloud tools: move `az`, `azd`, `terraform` from
   `home.packages` into a devenv, or wrap `claude` with a PATH filter.
3. Whether platform-tier sessions may commit (today they do). Decided
   2026-10-24 for the command center: no, its git rules are a work
   repo's (`docs/command-center.md`); `~/nixos-config` is still open.
4. Where the doc-quality plugin lives for customer repos.
5. `allowWrite = true` semantics against the unconditional apply/destroy
   deny.
6. Fix `azfn-rust-handler/devenv.yaml` to point at this repo.
7. Account connectors: off by default in every harness repo since
   2026-10-20 (`harness.allowConnectors`). Whether account-synced skills
   and plugins should be off on the work host too (`syncClaudeAiSkills`,
   `syncClaudeAiPlugins`: user or managed scope; the bootstrap's
   `--no-account-sync` writes them since 2026-10-21, default on).
   Decided 2026-10-24 for unmanaged hosts: off by default, the bootstrap
   writes both `false`s unless run with `--account-sync`. The managed
   settings do not set them; the managed host is still open.
8. Decided 2026-10-21: a new `harness` command (`pkgs/harness.nix`;
   `ccmux` stays a launcher and the scripts keep their bash bodies under
   `pkgs/harness/`), not subcommands of `ccmux` as the phases above
   first said.
9. Applied 2026-10-20: the `devenv/devenv.nix` hunk for `allowConnectors`
   (an option next to `platform`, and `allowConnectors` in the
   `inherit (cfg)` list of the settings file). The hook refuses that path
   for a session in the test repo; a session in the harness checkout
   applied it on Raul's explicit instruction there.
