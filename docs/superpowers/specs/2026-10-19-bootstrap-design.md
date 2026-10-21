# Bootstrap for any Linux

Design for the install route of claude-nix-harness, written 2026-10-19 from
a conversation with Raul. It replaces the container as the route for hosts
without Nix; that work is set aside in the claude-nix-harness-container
repo. A builder plans from this document; what it does not decide is left
to the builder on purpose.

## Intent

A person on a plain Linux laptop makes a directory, clones this repo into
it, and runs one script. When it exits they have Nix, devenv and direnv on
the host, the repo's shell built, and the harness rules on in it: the
generated `.claude/settings.json`, the guard hook, the deny set, the
sandbox, bypass mode disabled. From then on they start Claude with `ccmux`
in a terminal or by opening the folder in VS Code; their editor is their
choice. The script is one-off. After it, devenv's own tooling does updates.

Why: both existing tiers need Nix on the host. The managed tier is NixOS;
the unmanaged tier assumes nix, devenv and direnv are already there. Nix
coexists with apt, dnf and pacman because everything lives under /nix, so
the only thing standing between a plain distro and the unmanaged tier is
an installer that knows the four steps and the one kernel setting.

## Goals

- `git clone`, `./install.sh`, done. One script, run once, interactive
  where sudo is needed, idempotent enough to re-run after a failure.
- Nix from the nix-installer at artifacts.nixos.org: multi-user daemon,
  survives OS upgrades, has an uninstaller. (Found during review on
  2026-10-19: that URL now serves the NixOS community fork, which installs
  upstream Nix with flakes off; the script passes the experimental-features
  flags itself.)
- The repo-only tier exactly as it works on an unmanaged host today.
- Claude Code pinned by the project: it comes from the devenv shell, with
  tmux for `ccmux`, not from a host install.
- The host settings the home module sets on NixOS and that the sandbox or
  `ccmux` rely on are set here too: direnv's `strict_env`,
  `load_dotenv = false` and warn timeout, and the tmux environment hygiene
  for direnv variables.
- A clear end state: the script's last lines say what was installed, how to
  start, and how to undo.

## Non-goals

- Updating anything after the first run. `devenv update`, `nix profile
  upgrade` and the Determinate uninstaller are the tools from then on.
- The managed tree. Linking /etc/claude-code makes every Claude session on
  the machine subject to the harness, including the person's other
  projects, and scoping it is the machine owner's decision. The README
  names it as the next step for who wants it.
- macOS and WSL. Same script later; Linux first. The WSL tier builds on
  this route.
- A curl-to-sh one-liner for the harness itself. The person clones first
  and reads the script if they like; only the Nix installer is fetched.

## Anti-goals

- Touching the host's package manager or system libraries. Nix under /nix,
  profiles under the user's home, two rc-file lines, and at most one
  sysctl file.
- Silent sudo. Every privileged step is announced with what it does and
  why, and can be declined; the script then prints the command for later.
- Editing shell rc files that already have the direnv hook, or writing a
  direnv.toml or tmux snippet over one the person already has.

## Constraints

- The sandbox is bubblewrap with user namespaces. Ubuntu 23.10 and later
  restrict unprivileged user namespaces through AppArmor
  (`kernel.apparmor_restrict_unprivileged_userns = 1`); older Debian
  gates them with `kernel.unprivileged_userns_clone`. With the restriction
  on, `failIfUnavailable` refuses every Claude command. The script must
  detect it and offer the fix.
- direnv must be 2.38 or newer for `require_allowed`; nixpkgs may still
  ship 2.37 (pkgs/direnv.nix is the override). The flake exposes the right
  one for the script to install.
- devenv.yaml of a harness repo needs `allow_unfree: true` for claude-code.
- `nix profile install` was renamed `nix profile add` in Nix 2.29; the
  Determinate installer ships a current Nix. The builder checks which the
  installed version accepts.
- The script runs where only `sh`, `curl`, `git` and `sudo` can be assumed.
  Bash is fine once Nix is in, but the preflight runs before Nix exists.
- Claude Code's sandbox needs `bubblewrap` and `socat` on PATH; the
  nixpkgs claude-code wrapper adds them to its own PATH, so no host
  install is needed when claude comes from the shell.

## Decisions

Decided by Raul:

- Clone, then one install script in the repo; Determinate Nix installer;
  devenv tooling afterwards; Claude Code from the devenv shell or a flake;
  repo-only tier, managed tree later; entry through `ccmux` or VS Code.

Claude's calls, open to correction:

- The harness repo is the template people clone and work in, and the
  script is `install.sh` at its root. A separate project repo gets the same
  result by importing `harness/devenv` and running the same script from
  the harness checkout with the project directory as argument.
- The devenv module gains `harness.claudeCode.enable`, default false so
  no importing repo breaks on `allow_unfree`; it adds `pkgs.claude-code`
  and `pkgs.tmux` to the project shell. This repo sets it true, and the
  README's onboarding says to set it with `allow_unfree: true`. On a
  managed NixOS host the home module's copies serve sessions outside
  repos; inside a repo the project's pinned one wins on PATH.
- This repo becomes a devenv project on `main`: `devenv.yaml` with
  `inputs.nixpkgs = github:NixOS/nixpkgs/nixos-unstable` (the hook needs
  Claude Code 2.1.295 or newer; devenv-nixpkgs/rolling can lag),
  `imports: [ ./devenv ]`, `allow_unfree: true`; `devenv.nix` with the
  name and `harness.claudeCode.enable = true`; `.envrc` with
  `require_allowed devenv.nix devenv.yaml devenv.lock` as the runbook
  says; `devenv.lock` committed, which is what "pinned by the project"
  means.
- `ccmux` resolves `<customer>/<repo>` under `~/code/git`; a clone
  elsewhere has no name. The devenv module exports
  `HARNESS_PROJECT=local/<name>` whenever `DEVENV_ROOT` is outside the code
  root, so `ccmux` works from any clone and the managed host is unchanged
  for repos under the root. `tests/ccmux-test.sh` gets the case.
- devenv and direnv are installed from this flake's own nixpkgs lock
  (`packages.devenv`, `packages.direnv`), served by cache.nixos.org, so no
  `trusted-users` edit and no cachix trust are needed and nix.conf is never
  touched. devenv's own `latest` flake would need the person to be a
  trusted user or build devenv from source.
- The Nix installer is run as it ships; the uninstall line in the summary
  is its `/nix/nix-installer uninstall`, printed only when that file exists.
- The script's steps, in order: preflight (curl, git, sudo, distro, user
  namespaces), Nix if missing, `nix profile` install of devenv (from
  cachix/devenv latest) and this flake's `packages.direnv`, direnv hook
  line appended to `~/.bashrc` and `~/.zshrc` where those exist and lack
  it, `~/.config/direnv/direnv.toml` written only if absent, the tmux
  snippet installed as a file the person's `~/.tmux.conf` sources (one
  appended line), then `direnv allow` in the target directory and
  `devenv shell -- true` to build it, then a self-check: the generated
  `.claude/settings.json` exists with `disableBypassPermissionsMode ==
  "disable"`, and the hook from it runs.
- The user-namespace fix is offered, not applied: the script prints the
  sysctl line and the drop-in file it would write under /etc/sysctl.d,
  asks, and applies it with sudo on yes.
- The direnv and tmux settings come from one source each, shared with the
  home module, so the two hosts cannot drift: the home module reads the
  same files the script installs.
- The script is tested like the hooks are: a bash test with stubbed
  `curl`, `nix`, `sudo`, `direnv` and `devenv` on PATH, asserting order,
  idempotency (Nix present means no installer call; hook line present
  means no second line) and the declined-sudo path.

## Left to the builder

- The exact Determinate installer invocation and whether to pass
  `--no-confirm`.
- How the script finds the devenv and direnv installables for `nix
  profile`, and how it tells `install` from `add`.
- The preflight's distro detection and the exact sysctl names per family.
- The content of the end-of-run summary and the uninstall lines.
- Whether the tmux snippet is a file under `pkgs/` or `hooks/`; the home
  module's extraConfig becomes a `builtins.readFile` of it.

## Verification

For Raul, on a throwaway Ubuntu 24.04 VM or container with a sudo user:

1. `git clone <repo> harness && cd harness && ./install.sh`. The script
   reports the user-namespace restriction, applies the sysctl on yes,
   installs Nix, devenv and direnv, builds the shell, and ends with the
   self-check lines passing.
2. New terminal, `cd harness`, `direnv` loads without a prompt;
   `ccmux` opens tmux with Claude; `claude -p 'run: git commit -m x'`
   is refused; `claude -p 'run: grep -i nonewprivs /proc/self/status'`
   shows NoNewPrivs 1.
3. Open the folder in VS Code with the direnv extension; the integrated
   terminal has `claude` and `ccmux` on PATH.
4. Run `./install.sh` again: no installer call, no duplicate rc lines,
   same end state.
5. `/nix/nix-installer uninstall` leaves apt untouched and the repo intact.
