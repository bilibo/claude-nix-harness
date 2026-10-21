# Handoff: tiers, read fence, customer module, ccmux subcommands

For a Claude Code session started in this repo, and for Raul reviewing its
plans. Written 2026-10-18 from an inventory of this repo, of
`~/nixos-config` and of the Claude Code 2.1.296 docs. It replaces the
Perplexity plan "nix-ccode-harness and ccmux": that plan assumed one repo,
a WSL host and a hand-written sandbox wrapper, none of which is the case
here. Section 1 says what is already done, section 2 what is true on disk,
section 4 what to build, in phases; `docs/roadmap.md` keeps the overall order and points here for the tier work.

Rules for the session: read, propose the file list for a phase, wait for
approval, implement, stop. Do not activate any NixOS or home-manager
generation. Do not change flake inputs without asking. `nix flake check`
cannot run inside a session in this repo (the sandbox masks `.gitmodules`
and shell startup files, and the Nix daemon socket may be unreachable);
write the test cases and tell Raul to run them. A session here cannot
commit or edit `devenv/devenv.nix`, `devenv.yaml` or `.envrc` under
`~/code/git` either; propose those as diffs.

## 1. Already done from the nixos-config session (2026-10-18)

In this repo, committed: `ccmux` replaces `ccode` (the old name stays as a second entry point), tested under both names.

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
`upgrade` or `platform` subcommand exists.

**Settings.** One body, `lib/settings.nix`, two destinations:
`managed = true` for `/etc/claude-code/managed-settings.json` (NixOS module
`nixos/default.nix`, `environment.etc`), `managed = false` for the repo's
`.claude/settings.json` written by the devenv module as a read-only store
symlink at every shell entry. On the laptop only the repo copy exists:
nixos-config dropped the harness modules on 2026-10-18. Deny rules in
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
`ARM_CLIENT_SECRET`, `AZURE_CLIENT_SECRET`, `SSH_AUTH_SOCK` and
`SSH_AGENT_PID` denied as env vars. `allowAllUnixSockets = true` (go-plugin,
Nix daemon). `bubblewrap` and `socat` come from the host's system packages.

**devenv-base.** Does not exist. There is one devenv module,
`devenv/devenv.nix`, imported as `harness/devenv`. It exports options `harness.*`
(allowLocalCommits, allowMemoryEdits, platform, extraDeny,
extraAllowedDomains, settings, managedSettingsPath, claudeCode.enable), writes the
settings file, ships `ccmux` in the shell, exports `HARNESS_PROJECT`. No
repo sets `AZURE_CONFIG_DIR`. The only repos under `~/code/git` are
`raul/claude-nix-harness` and `raul/azfn-rust-handler`; the latter's
`devenv.yaml` still points at `git+file:///home/raul/nixos-config?dir=harness`,
which no longer exists in nixos-config HEAD. Raul edits it (the hook
forbids a session doing so).

**Versions.** Claude Code 2.1.296. nixos-config pins home-manager
`6407259` and nixpkgs `8edc0c7` (nixos-unstable). This repo pins its own
nixpkgs in `flake.lock`. Podman was removed from the laptop; no container
engine is assumed anywhere.

**Host.** The laptop is native NixOS on a Framework 16 with COSMIC, not
WSL. `platform = "wsl"` is implemented but has never run live. The hook
regexes and deny rules deny `nixos-rebuild`, `home-manager switch`,
`nix profile`, `nix-env`, `nix-channel`, `nix-collect-garbage`, `systemctl`,
`sudo`. Nothing denies `nh`: `nh os switch` and `nh home switch` pass both
layers today. `nixos-rebuild` is denied as a whole, `build` included.

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
- "`nh os switch` is refused in both tiers": false today, see Host above.
- "Podman is the container engine": removed; nothing depends on it.
- `claude plugin validate` is denied by the universal `claude plugin` rule;
  a platform tier that allows it needs the rule split into
  `claude plugin install|marketplace|...` and the hook regex changed too.

## 4. Phases

Each phase: file list first, approval, implement, tests as cases in
`tests/` for Raul to run with `nix flake check`.

### Phase 1: housekeeping and `ccmux doctor`

- `nh` into the system set of `lib/deny-rules.nix` and the hook's system
  regex: `nh os switch|boot|test`, `nh home switch`, `nixos-rebuild
  switch|boot|test`, `home-manager switch`. Leave `nh os build`,
  `nixos-rebuild build`, `nix build`, `nix flake check` alone. Test cases
  for each, both directions.
- `--add-dir` into the hook's nested-`claude` flag list, with a test.
- `ccmux doctor`: Claude Code version, whether
  `/etc/claude-code/managed-settings.json` exists, `bwrap` and `socat`
  present, user namespaces enabled, direnv and devenv versions,
  `HARNESS_CODE_ROOT`, `HARNESS_PROJECT`, resolved tier for the cwd (phase
  2), state of the repo's `.claude/settings.json` symlink (present, dangling,
  which store path), and the hook paths it registers. Plain text, one line
  per item, exit 1 when something it needs is missing. Add it as a
  subcommand of the same script; `ccmux -n` stays.
- Update the runbook's verification section to start with `ccmux doctor`.

Tests: `nix flake check` passes; `ccmux doctor` output pasted by Raul from
the laptop.

### Phase 2: tiers and the read fence

Two tiers, chosen by `ccmux` from the cwd: `ccmux platform`, or a cwd under
a configured platform root (`~/nixos-config`, this repo), gives `platform`;
a cwd under `HARNESS_CODE_ROOT` gives `customer`; anything else refuses to
start. `HARNESS_TIER` exported into the tmux window.

Common to both, in `lib/settings.nix`:

- `permissions.blockReadsOutsideWorkingDirectories = true`. Check whether
  `sandbox.filesystem` has an allow-read list (`allowRead` or similar) in
  the settings reference; if it does, add `denyRead` of the code root with
  an allow-read of the repo itself (`config.devenv.root` is known at devenv
  eval time), so Bash cannot read a sibling customer either. If it does not,
  record Bash reads of siblings as a gap closed only by RBAC.
- The `nh` and `nixos-rebuild` rules from phase 1.

Platform tier: a generated settings file for repos that have no devenv,
passed by `ccmux` as `--settings <store path>` on the outer `claude`
(the hook's refusal of `--settings` is for nested sessions only, so this is
consistent; document it). Deny set: universal minus `claude plugin
validate`, plus the project git rules only if Raul wants them there (today
nixos-config sessions commit; ask). No cloud tools: the platform PATH is the
user's PATH, so `az` and `terraform` from `home.packages` in nixos-config
are on it. Either Raul moves them to a devenv, or the tier wraps `claude`
with a PATH filter; propose both, let him pick. No `AZURE_CONFIG_DIR`, no
`ARM_*`.

Customer tier: the existing devenv module output, unchanged except for the
read fence. `platform = "wsl"` already hides `/mnt/c` and `/run/WSL`;
device-code login is a devenv-module concern (phase 3).

Tests (unit, in `tests/`): the generated platform and customer files carry
`blockReadsOutsideWorkingDirectories`; `nh os switch` denied in both; `az`
absent from the platform PATH if the wrapper route is chosen; `ccmux -n`
reports the tier. Live cases go to phase 5.

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
  Ask Raul before choosing.

Tests: a scratch repo built in a `nix flake check` derivation cannot run
devenv; write the module so its pure parts (env var attrset, hook branch)
are testable with the existing hook-test pattern, and give Raul a
`devenv shell` smoke list for the rest.

### Phase 4: `ccmux new` and `ccmux upgrade`

As in the Perplexity plan: registry at `~/code/git/<customer>/customer.toml`,
rendered files (`devenv.yaml` pinned to a harness revision, `devenv.nix`
with the customer block, `.envrc` with `use devenv` and `require_allowed`,
`.gitignore`, `.worktreeinclude`, `.claude/settings.json` left to devenv,
`CLAUDE.md`, `README.md`, `.editorconfig`), `git init` and first commit,
the two `AZURE_CONFIG_DIR` directories, `--dry-run`, idempotent,
`--force`, template version recorded in `devenv.yaml`, `upgrade` shows the
diff. Templates under `devenv/templates/`. No `az login`, no secrets, no
backend provisioning; `--init-backend` explicit and human-identity only.
Skip `--agent sp` sops wiring until a customer actually needs a service
principal; `user` is the default.

Tests: `ccmux new test/scratch --dry-run` under a temp `HOME` renders
without writing; a real run there yields a repo where `direnv allow` and
`devenv shell` export the expected vars (Raul runs); a second run reports
no changes.

### Phase 5: limits suite

`tests/limits/run.sh`, a `nix run .#limits` app (not a check: it needs a
live `claude -p` and the network). Runs inside a scratch customer repo
created by `ccmux new`, one `claude -p` per case, records the exact refusal
text. Cases from the plan plus: nested `claude --add-dir ..`, `nh os
switch`, `nixos-rebuild switch`, `home-manager switch`, Read of a sibling
customer file and of `~/nixos-config/flake.nix`, Read of another project's
`~/.claude/projects/` directory, `az login` in platform tier, `terraform
apply` with `allowWrite = false` and with a mismatched subscription, write
to `~/.claude/settings.json`, `/mnt/c` and `/run/WSL` in customer tier on
WSL only, `git push`. Human `/add-dir` is listed as accepted, not tested.
`ccmux doctor --full` runs it.

## 5. Decisions only Raul can make

1. Whether the harness should carry the working-style rule (now a
   nixos-config module) for the work host, or the WSL base config imports
   it from nixos-config.
2. Platform-tier cloud tools: move `az`, `azd`, `terraform` from
   `home.packages` into a devenv, or wrap `claude` with a PATH filter.
3. Whether platform-tier sessions may commit (today they do).
4. Where the doc-quality plugin lives for customer repos.
5. `allowWrite = true` semantics against the unconditional apply/destroy
   deny.
6. Fix `azfn-rust-handler/devenv.yaml` to point at this repo.
