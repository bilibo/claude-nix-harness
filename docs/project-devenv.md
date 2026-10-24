# The project devenv

For whoever looks after a harness repo and has not used Nix. Every repo
under the harness gets its tools from a devenv shell: direnv enters it
when you `cd` into the repo, and the same shell wraps every Bash command
Claude Code runs there. `harness init` writes the files below, and you
change one of them, `devenv.nix`, when the project needs something new.
Everything below is a change to `devenv.nix` or `devenv.yaml`.

## The files

| File | What it is | Who edits it |
|---|---|---|
| `devenv.nix` | The project's tools, toolchains, environment variables and harness options | you, by hand; an agent proposes the diff |
| `devenv.yaml` | Where the inputs come from (the harness, nixpkgs), plus `allow_unfree` | you, rarely; `harness init --force` rewrites it |
| `devenv.lock` | The exact revision of every input, nixpkgs included. Commit it | nobody: `devenv update` writes it |
| `.envrc` | Three lines that make direnv load the shell and ask before loading changes | nobody: `harness init --force` rewrites it |
| `.claude/settings.json` | The rules Claude Code runs under, generated at every shell entry, gitignored; absent with the guard rails off (below) | nobody; edits are overwritten |

A `devenv.local.nix` beside them is per developer: gitignored, imported
by devenv on its own, for values that are not the repository's (README,
"Where project configuration goes").

## How a change lands

The same four steps, whatever the change:

1. An agent that needs a tool or a rule proposes the diff to `devenv.nix`
   and stops: the hook refuses its edits to these files and the shell
   commands that write them. You can also write the change yourself.
2. You apply it in your editor and read it: this file runs as you,
   outside any sandbox, at the next shell entry.
3. `direnv allow` in the repo. `.envrc` ends with `require_allowed
   devenv.nix devenv.yaml devenv.lock`, so after a change to any of the
   three direnv says they `require approval` until you do. It flags, it
   does not block: the shell loads the new content either way (runbook,
   troubleshooting), so read a change before you allow it, one a `git
   pull` brought included. In VS Code, mkhl.direnv asks the same
   question. A changed `.envrc` is different: it does not load at all
   until `direnv allow`, and every Bash command a session runs is refused
   with `fix: direnv allow <repo>` until then.
4. Commit `devenv.nix` (and `devenv.lock` when it moved). The agent never
   commits.

The first load after a change downloads or builds what is new, seconds
to minutes; after that it is instant.

## Adding a tool

```nix
  packages = [
    pkgs.git
    pkgs.jq
    pkgs.azure-cli
    pkgs.opentofu
  ];
```

The name after `pkgs.` is the package's attribute name. Find it at
<https://search.nixos.org/packages> (channel "unstable"; the "Name"
field, which is not always the command's name: `az` is
`pkgs.azure-cli`), or with `devenv search <word>` in the repo. The
version is whatever the locked nixpkgs carries; `az version` or
`<tool> --version` in the shell says which. `devenv update` moves
nixpkgs and every tool with it, then step 3 above again.

A package marked unfree (Terraform since 1.6, VS Code, Claude Code) fails
the load with an "unfree" error until `devenv.yaml` says:

```yaml
allow_unfree: true
```

## A language toolchain

devenv bundles the usual set for a language behind one line:

```nix
  languages.rust.enable = true;       # rustc, cargo, clippy, rustfmt, rust-analyzer
  languages.python.enable = true;
  languages.javascript.enable = true; # node and npm
```

These take the versions nixpkgs carries. A pinned version (a Rust
channel, a Python minor) needs one more input in `devenv.yaml`; the
language's page under <https://devenv.sh/languages/> has the lines.

The package manager is the other half. cargo, pip and npm download from
hosts the sandbox does not allow by default, so a session's `cargo
build` fails on the network until the project allows them (below):
`index.crates.io` and `static.crates.io` for cargo, `pypi.org` and
`files.pythonhosted.org` for pip, `registry.npmjs.org` for npm. Tools
from `packages` need none of this: Nix fetches them outside the sandbox.

## Environment variables

```nix
  env.ARM_TENANT_ID = "00000000-0000-0000-0000-000000000000";
  env.ARM_SUBSCRIPTION_ID = "00000000-0000-0000-0000-000000000000";
  env.TF_VAR_environment = "dev";
```

Exported into your shell and every command a session runs. Identifiers
only: `devenv.nix` is committed and the agent reads it. Secrets stay in
`.env` or your `az login` session, which the agent never sees (README,
"Where project configuration goes", has the split and why).

## Project allow rules

A command the project runs all the time can skip the permission prompt:

```nix
  harness.settings.permissions.allow = [
    "Bash(terraform plan *)"
    "Bash(cargo test *)"
  ];
```

The syntax is Claude Code's permission rules (`Bash(<command> *)`, `Read(<path>)`,
...). An allow rule only skips the prompt; it never opens what a deny
rule, the hook or the sandbox refuses, so a refused command stays refused
however it is allowed here. The rules apply to everyone who uses the
repo.

To refuse more, add to the harness's list instead of replacing it:

```nix
  harness.extraDeny = [ "Bash(az devops *)" ];
```

Never set `harness.settings.permissions.deny` or a list under
`harness.settings.sandbox`: `harness.settings` is merged into the
generated file key by key, and a list there replaces the harness's own,
the full deny set or the network allowlist with it. `extraDeny` and
`extraAllowedDomains` are the options that add.

## Network hosts for the sandbox

Every Bash command a session runs reaches only the hosts on the sandbox's
allowlist: the Azure and Terraform endpoints, GitHub, and the container
registries trivy uses. Anything else fails with a connection error naming
the host. A project that needs more lists them:

```nix
  harness.extraAllowedDomains = [ "dev.azure.com" "index.crates.io" "static.crates.io" ];
```

That works on a host set up with `scripts/install.sh`. A managed host
(the NixOS module) ignores a repo's allowlist; there the host goes into
the system configuration's `harness.extraAllowedDomains` instead.

## The other harness options

The `devenv.nix` `harness init` writes lists every option, the unused
ones commented out; `devenv/devenv.nix` in the harness has the full
descriptions.

| Option | What it does |
|---|---|
| `enable = false` | the guard rails off for this repo (next section) |
| `role` | `"work"`, the default and the only value a project sets. `"center"` belongs to the harness checkout alone (the command center, `docs/command-center.md`) and turns the sandbox off there, so never in a customer repo; `harness init` warns about a repo that has it |
| `allowMemoryEdits` | Claude keeps its auto-memory under `~/.claude/projects` |
| `allowLocalCommits` | agents commit on their worktree branch; push stays impossible |
| `readFence`, `extraAllowRead` | hide the rest of `$HOME` from sandboxed commands, and say what the project still reads there |
| `allowConnectors` | the claude.ai account's connectors load in this repo's sessions |
| `platform = "wsl"` | hide `/mnt/c` and `/run/WSL` from the sandbox; `harness init` sets it on a WSL host |
| `claudeCode.enable` | Claude Code's CLI, tmux and jq from this shell, for `ccmux` and tmux sessions on a host with no `claude` of its own; needs `allow_unfree: true`. `harness init` turns both on when it finds no `claude` on the host's `PATH`, as on the plain WSL host, where the VS Code extension runs its own bundled copy and the repo's shell is the only CLI there is; with one there, it leaves them commented out |

## Turning the guard rails off (and on)

A repo that should not run under the guard rails turns them off with one
line in `devenv.nix`. One that `harness init` wrote since 2026-10-24 has
it, commented out, first in the `harness = { ... }` block: remove the
`#`. In an older one, add it there:

```nix
  harness = {
    enable = false;
  };
```

Outside that block the same line is `harness.enable = false;`. Then
`direnv allow` in the repo (step 3 above). From the next shell entry:

- `.claude/settings.json` is gone: devenv removes the link it wrote
  before (if one is still there after the next `cd`, delete it by hand).
  Sessions started in the repo run under your own settings only:
  none of the repo's deny rules, no hook, no sandbox, and Claude Code's
  usual permission prompts.
- Every shell entry says so: `harness: guard rails off for this repo
  (harness.enable = false in devenv.nix)`.
- The tools stay: `packages`, toolchains, `env.` variables, `ccmux`, and
  Claude Code itself with `claudeCode.enable`. The other harness options
  stay in the file and do nothing until the rails are back on.
- `harness init` on the repo reports `off` after the first shell entry
  and checks nothing; `harness check` says it is not a harness repo.

A session that was already open may keep what it loaded: start new
ones after the change, either way.

An agent cannot flip the switch. It is a line in `devenv.nix`, and the
deny rules and the hook refuse an agent's edits to that file (step 1
above), as for every other line in it; one that could write the file
could already loosen the rules through `harness.settings`, so the switch
opens nothing new. A change to `devenv.nix` you did not make still shows
up as `require approval` at the next `cd`.

To turn them back on, delete the line (or write `enable = true;`, the
default) and `direnv allow`. The next shell entry writes
`.claude/settings.json` again; start new sessions.

Committed, the switch applies to everyone who uses the repo. For
yourself only, put `harness.enable = false;` in `devenv.local.nix`
instead ("The files" above).

On a managed host (the NixOS module) this only turns off the repo's own
copy of the rules. The managed settings under `/etc/claude-code` are
root-owned: their deny rules, hook and sandbox apply in this repo
whatever `devenv.nix` says.

## When the shell does not load

- `require approval` is not this: the shell loaded; step 3.
- `.envrc is blocked`: `direnv allow`, after reading the `.envrc`.
- An evaluation error after an edit: `devenv shell` in the repo prints it
  with the line. A missing `;` or `]` is the usual one.
- `undefined variable` or `attribute ... missing` for a package: the
  name is not the attribute name; search again.
- `unfree`: `allow_unfree: true` in `devenv.yaml`.
