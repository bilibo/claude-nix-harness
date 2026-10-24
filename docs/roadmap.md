# Roadmap

What exists, what is next, and ideas that are not committed to. Dated
history is in `docs/changelog.md`; the tier, read-fence, customer-module
and launcher-subcommand work is phased in `docs/handoff-tiers.md`.

## Done

- NixOS module: managed settings, hook, sandbox, mod policy, directory
  scoping, per-host options.
- home-manager module: direnv, tmux, `ccmux`.
- `harness.role` (work | center) and the pinned command-center import,
  2026-10-24; `harness.enable` as the per-repo off switch, the same day.
- devenv module: generated project settings, host check.
- One settings body for the managed and the repo copy; the repo file
  carries deny rules, every hook and the sandbox, so an unmanaged host runs
  on it alone. The hook blocks `settings.local.json` changes and nested
  `claude` and `ccmux` launch flags.
- Tests in `nix flake check`: hook unit tests (154 cases, 180 with
  enforcement roots), the generated repo settings file (15 checks), ccmux
  resolution under both names.
- Own repo with a `flake.nix` exporting the modules, `lib`, the managed
  trees, `packages.direnv` and `packages.devenv` for an unmanaged host, and
  the tests as `checks`.
- Unmanaged Fedora host (2026-10-20): `scripts/bootstrap-fedora.sh` with
  `--check`, `--upgrade` and `--reset`; `scripts/init-repo.sh` (runbook
  section 3); `scripts/live-check.sh` (section 5's live cases). The
  from-zero sequence in runbook section 5 passed end to end on the Fedora
  laptop: first time a real session ran on the repo file alone.
- Host prerequisites settled: direnv 2.38 (override until nixpkgs ships
  it), Nix multi-user without `trusted-users` (the devenv cache goes into
  the root-owned `nix.conf` instead; `--trusted-user` opts in).
- Account connectors off in harness repos (`disableClaudeAiConnectors`
  from the repo file, `harness.allowConnectors` per repo), 2026-10-20.
- Sandbox hardening, the first three items of the 2026-10-20 audit
  (2026-10-21): the bootstrap writes `sandbox.network.strictAllowlist =
  true` into the user-scope `~/.claude/settings.json` (and
  `syncClaudeAiSkills` and `syncClaudeAiPlugins = false`, the default since
  2026-10-24; `--account-sync` leaves them out); the repo
  file lists its own settings, hooks, skills, plugin manifest and `.git`
  hooks and config as literal `denyWrite` paths under `config.devenv.root`,
  which Linux honours; `env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = "1"` strips
  credential-shaped variables from every subprocess and the GitHub tokens
  the scrub keeps are `deny` entries. `project-settings-test` 18 checks;
  `live-check` cases 11 (repo write) and 12 (env scrub) written, not yet
  run.
- One CLI instead of three scripts (2026-10-21): `harness` (`pkgs/harness.nix`)
  with `bootstrap`, `upgrade`, `doctor`, `init`, `check`, `reset` and shared
  `--dry-run`, `--yes`, `--verbose`; the script bodies under `pkgs/harness/`,
  shellchecked at build time; `scripts/install.sh` does the root steps
  `nix run` needs and hands over to `harness bootstrap`; a receipt at
  `~/.local/state/claude-nix-harness/receipt.json` drives `reset` and
  `upgrade`; `harness doctor` and `harness init --dry-run` run in
  `nix flake check`.
- Install route for any Linux without Nix (2026-10-19): root `install.sh`
  (nix-installer, profile packages, rc lines, direnv and tmux files), tested
  with every command stubbed (`install-test`, `host-config-test`); not yet
  run on a real distro. Overlaps with `scripts/install.sh` + `harness
  bootstrap`; one of the two goes.
- Secret paths in the hook, path-first (2026-10-21): a command naming a
  secret file is refused unless it is one harmless verb with no pipe,
  substitution or input redirection; the reader-verb list is gone.
  `devenv.local.nix` and `devenv.local.yaml` in `repoProtected`, so the
  file devenv auto-imports without any re-approval cannot be created from
  the sandbox. Bootstrap appends `pkgs/direnv.toml` and `pkgs/tmux.conf`
  instead of its own copies; `reset` without a receipt leaves Nix alone;
  `scripts/install.sh` does dnf, the SELinux label and the daemon socket
  (what `nix run` needs) and hands the rest to `harness bootstrap`; `ccode`
  is gone.
- Read fence prototype (2026-10-21): `harness.readFence` (off by default)
  hides the rest of `$HOME` from sandboxed commands; the hook's env preamble
  puts direnv and devenv on PATH by store path because `~/.nix-profile`, a
  symlink, is not mounted back into a fenced sandbox. Live in the test repo:
  devenv shell loads, `~/.bashrc` and the VS Code settings unreadable,
  `~/.claude` present for the shell snapshot. `project-settings-fenced-test`
  (21 checks).
- Root `CLAUDE.md` (2026-10-21), under 30 lines: which document owns what,
  the handoff's standing rules, the closed-decision rule, how a session runs
  the checks. First `harness doctor` and `harness init --dry-run` against
  the checkout: init leaves `devenv.yaml`, `devenv.nix` and `.envrc` alone
  and would add three `.gitignore` lines that `.claude/` already covers;
  doctor's repo report and VS Code lines were false from inside a session
  (the sandbox masks `.claude/settings.json` as a character device, and the
  host's `code` dies on the shell's `LD_LIBRARY_PATH`), now reported as
  such (`harness-doctor-test` 27 checks). `harness check` against the
  checkout still has not run: it needs a terminal, not a session.
- One install route (2026-10-21): `scripts/install.sh` + `harness
  bootstrap` survives; the root `install.sh` is gone and what only it did
  moved over. The script: the nix-installer where Fedora's packages are
  not there (before `nix run` exists), the checkout as the default ref,
  `harness init` on the checkout at the end (the old shell build and
  self-check). bootstrap: no Fedora-only preflight, the user-namespace
  sysctl offered on its own and declinable, the direnv hook in a
  `~/.bashrc` that does not source `~/.bashrc.d` and in `~/.zshrc`, the
  tmux block in the file tmux reads (`~/.tmux.conf` when it exists),
  flakes in `nix.conf` where the installer left them off; `reset` undoes
  the sysctl and runs the installer's uninstaller. `install-test` rewritten
  for the script (both routes, 44 checks), `harness-bootstrap-test` new
  (94 checks: rc-file layouts, nix.conf, the sysctl, idempotency, reset). Run on nothing but the stubs so far; the runbook's
  fresh-distro list (section 5) is the verification, on Ubuntu 24.04.
- Audit fixes (2026-10-21, staged; in once committed): two whole-repo
  audits (Opus, then Fable), every hook claim re-run against the built
  hook, worked by three sessions the same evening (changelog). The hook
  refuses working-tree discards and force-moves (`checkout .`/`-f`,
  `switch -f`/`-C`, `checkout -B`, `branch -f`, `tag -f`, `worktree
  remove -f`), checks edits on the link target as well as the name, and
  covers `~/.bashrc.d`, `~/.local/bin` and every `file -f` spelling;
  `~/.aws`, `~/.config/gh` and `~/.git-credentials` are hidden by every
  layer. `harness init` asks before loading repo files it did not write;
  `harness upgrade` builds before it removes; the no-receipt `reset`
  branch, the profile-ccmux ref fallback and `lib/project-settings.nix`
  are gone; the direnv version check lives in `pkgs/direnv.nix` only.
  hook-test 241 cases, project-settings-test 22 (23 fenced),
  harness-bootstrap-test 101, harness-init-test 24; `nix flake check`
  green on the combined tree.
- The 2026-10-23 brief, all seven items (changelog): `harness init` runs
  the settings test with the real repo path; NixOS and WSL detection in
  install, bootstrap and doctor with the store-symlink guard on
  `root_write`; `nh` and `--add-dir` denied; the hook refuses a Bash
  command whose `.envrc` cannot load (`check_env`); `harness check`
  verdicts from tool results only, with `--parse`; the AppArmor bwrap
  profile instead of the sysctl on Ubuntu; the NixOS module evaluated in
  `nix flake check` with `examples/nixos-host.nix`. Every piece has a
  check; the AppArmor and WSL pieces are stub-tested only until the Ubuntu
  laptop and a WSL host run them.
- First live `harness check` (2026-10-22, Ubuntu, 9 of 12): `devenv.local.*`
  out of the literal `denyWrite` list so the devenv shell can load inside
  the sandbox (unverified until the next run); the environment scrub gone
  for good, a repo file's copy is ignored and a user-scope copy turns the
  sandbox's Bash auto-allow off; case 11 reads the sandbox's mask as the
  refusal it is; a `-p` permission refusal counts as inconclusive and
  every case keeps its debug log (changelog).
- The Windows route (2026-10-23): `scripts/install-wsl.ps1` provisions
  NixOS-WSL from the latest release and makes it a managed host from your
  nixos-config flake; `scripts/wsl/{bootstrap,update,verify}.sh` do the
  work inside the distro, pull-only after the first install;
  `examples/nixos-wsl-host.nix` is the host file. First live managed host:
  NixOS-WSL on a Windows 11 Home laptop (changelog).

## Target flow (2026-10-21)

What the pieces add up to, and what is missing for it:

1. One installer per host: `curl -fsSL .../scripts/install.sh | bash -s
   -- --yes` (or `scripts/install.sh` from a clone) does the root and
   pre-Nix work, then `harness bootstrap` the user side, on Fedora,
   Ubuntu and NixOS, each also under WSL.
2. The harness checkout is the command center: its own devenv shell,
   `ccmux` in it, the session where the human accepts what other
   sessions propose.
3. `harness init <customer>/<repo>` per project: a standard
   `devenv.nix` a non-Nix user can add tools to.
4. `ccmux` sessions per project, set on tasks by hand or by the command
   center; what their rules refuse, they propose to the command center
   instead of working around.

Status against it: 1 runs end to end on Fedora 44 and on Ubuntu 26.10
(2026-10-22: install, bootstrap, `harness init` on the checkout, `harness
check`, `ccmux`; changelog); NixOS is detected since 2026-10-23 (gap A, the
NixOS half), WSL detection is stubbed. 2 works by convention
(CLAUDE.md contracts and `SendMessage`, as on 2026-10-21 when three
sessions worked the audit board); since 2026-10-24 the checkout has its
own role (`center`), but its hook is a work repo's, so it still refuses
its `devenv.nix` and the module source `devenv/devenv.nix`.
3 works, with a guide since 2026-10-24 (gap C). 4 works by hand.

The gaps, in order:

- A. **Host detection**: NixOS half done 2026-10-23, WSL detection
  stubbed, live WSL pending (changelog). As written on 2026-10-21:
  (`scripts/install.sh`, once; exported to bootstrap
  and init). Fedora 44+ as today. NixOS (`/etc/NIXOS` exists): no
  installer, and bootstrap must not write `/etc/nix/nix.conf` (a store
  symlink the next rebuild restores): print the `nix.settings` lines for
  the devenv cache instead, or point at the NixOS and home modules (the
  README's managed row), then do the user steps. WSL
  (`/proc/sys/fs/binfmt_misc/WSLInterop` or `WSL_DISTRO_NAME`): check
  that systemd runs in the distro (`[boot] systemd=true` in
  `/etc/wsl.conf`; the nix-installer's daemon needs it, else
  `--init none`: verify which), skip the `environment.d` step (no
  Linux GUI login), and `harness init` writes `harness.platform =
  "wsl";` into `devenv.nix` so `/mnt/c` and `/run/WSL` are hidden from
  the sandbox; today no unmanaged WSL repo gets that. NixOS-WSL stays the
  module route (item 7). Tests: install-test and harness-bootstrap-test
  cases with a fake `ID=nixos` os-release plus a marker path, and a fake
  WSL marker (`HARNESS_*` overrides, as the other system paths have).
- B. **Ubuntu for real**: runbook section 5's fresh-distro list on Ubuntu
  24.04, done under WSL so it verifies A's WSL branch on the same run.
- C. **A guide to the project devenv for non-Nix users**: written
  2026-10-24 (changelog), every case below; the template links it in its
  header and gains the `packages`, `languages` and `env` lines. As written
  on 2026-10-21:
  (`docs/project-devenv.md`, linked from the README and from the
  `devenv.nix` `harness init` writes): what the four files are and which
  ones a human edits; adding a tool (`packages = [ pkgs.terraform ];`,
  names from search.nixos.org/packages); a language toolchain
  (`languages.rust.enable = true;`); environment variables (`env.X =
  "...";`, never secrets: README "Where project configuration goes");
  project allow rules (`harness.settings.permissions.allow`); network
  hosts for the sandbox (`harness.extraAllowedDomains`); unfree packages
  (`allow_unfree: true`); the `direnv allow` prompt after every change
  and why (`require_allowed`); and the agent's side: it proposes the
  diff, the human applies it. The template gains one commented line per
  case pointing at the guide. Phase 3's `lang` option (handoff) shortens
  it later; the guide comes first. Since 2026-10-21 the template lists
  every harness option commented out; the guide is still to write.
- D. **Command center as a tier**: realised 2026-10-24 as `harness.role`
  (handoff phase 2, `docs/sessions.md` section 3). `center` is this
  checkout: the same deny rules and hook as a work repo, no sandbox, Bash
  prompted, memory on, `HARNESS_ROLE=center` carried by `ccmux`. `work`
  is everywhere else. The checkout imports the module pinned from GitHub,
  so a working-tree edit never becomes its live hook. Open: the managed
  host, where the managed sandbox stays on in the center and limiting
  `center` to platform roots is undecided; `~/nixos-config` as a platform
  root without a devenv. The broker's stage B it also named (item 8) was
  dropped on 2026-10-24; proposals stay the CLAUDE.md contract and the
  center's permission prompt (`docs/sessions.md` section 4). What the
  command center is and does: `docs/command-center.md`.

## Next, in order

0. **Audit follow-ups (2026-10-21).** What the audit fixes left open or
   turned up. The human's, in this order:
   1. Review and commit the staged set (17 files). One choice inside it:
      `~/.config/gh` in `denyRead` (`lib/settings.nix`) ends `gh` reads
      in sessions as well as the token leak; drop that line to keep them,
      and accept that `gh auth login` without a keyring puts a push token
      in reach again.
   2. Done 2026-10-21: `devenv/devenv.nix` imports `pkgs/direnv.nix`.
   3. Done 2026-10-24: `root_steps` in `pkgs/harness/bootstrap.sh` keeps
      only the nix.conf block and `userns_steps`; the dnf loop, the SELinux
      block, the daemon-socket block and `ROOT_RPMS` are gone, `reset` and
      `doctor` unchanged, bootstrap-test case 11 a doctor-only Fedora host
      line (changelog). As written: `scripts/install.sh` owns every root
      and pre-Nix step, `harness bootstrap` the user side.
   4. Done 2026-10-22: `CLAUDE.md`, section "Checks", carries the copy of
      the regular files and `nix flake check path:<dir>` (changelog). No
      memory note: `CLAUDE.md` is loaded into every session here.
   5. Done 2026-10-22: `tests/harness-bootstrap-test.sh` runs the harness
      with the stub directory as the whole PATH (the wrapper prepends its
      own store tools), so a by-hand run no longer sees the host's
      `getenforce` and `code`; the header no longer claims the Nix build
      sandbox guarantees that. On a nix-installer host the bootstrap's
      `nix_path` then put the default profile's real nix ahead of the stub
      (52 cases, GitHub unreachable from a session): the profile.d files
      it sources are `HARNESS_NIX_PROFILE_D`, empty in the test.
   6. Done 2026-10-24: `harness init` counts a `devenv.lock` that exists
      before the first `direnv allow` as foreign and prints the inputs it
      pins under the `==>` header, so the y/N covers it; harness-init-test
      has the case (changelog). As written: a foreign lock was approved by
      the second `direnv allow` without being shown, and it pins every
      input, nixpkgs included.
   7. Done 2026-10-21: hook refuses `git checkout <ref> <path>...` (changelog).
   8. Written 2026-10-24, not yet run live: `harness check` case 14
      (`cred-sandbox`), the sandbox hiding `~/.git-credentials` on its
      own, by `wc -c ~/.git-cred*` with a fake file when the host has
      none; which of `0` or no-such-file the sandbox answers is for the
      first run to say (changelog). As written: the command spells the
      path around the hook's `cred_files` regex, create the fake line
      first when absent (`https://x:live-check@example.invalid`), remove
      it after, leave a real one alone.
   9. Done 2026-10-22, on the Ubuntu laptop itself: `harness upgrade`
      removed the scrub key from `~/.claude/settings.json`, the hook's
      preamble got devenv a writable runtime directory (changelog), and
      `harness check` passed 12 of 12: case 2 the devenv shell inside the
      sandbox, case 12 the two GitHub tokens.
   10. Review and commit the staged set (2026-10-24): the 2026-10-23 WSL
       route (9 files) and the home-module change that stops home-manager
       writing `~/.claude/settings.json` (changelog 2026-10-24). Then
       switch the WSL host to a harness revision that has it (the update
       in runbook section 4 once the host flake's `harness` input points
       there; `--override-input harness path:<checkout>` for a trial
       build) and confirm `/model` in a session writes a plain
       `~/.claude/settings.json`. The host repo's `check-access.sh` case
       "HM settings.json is a store symlink" inverts with it.
   Not planned: `~/.kube/config` and `~/.docker/config.json` the same way
   as `~/.aws`, until a harness host holds them.
1. **Interactive check of the repo-only shape.** `-p` sessions are verified
   (live-check 10/10 on 2026-10-20; `harness check` 12 of 12 on the Ubuntu
   laptop, 2026-10-22).
   Left: a `ccmux` session in the test repo, the trust dialog accepted
   once, hooks seen firing and the tmux window turning orange (`ccmux` on
   the checkout runs on the Ubuntu laptop since 2026-10-22; the hook
   firing and the orange window are still unobserved). The
   Notification matcher names are verified against the hooks reference;
   whether the event fires in tmux is not.
2. **Sandbox hardening**, the rest of the 2026-10-20 audit (runbook
   section 8, "Sandbox limits"); the strict allowlist, the literal
   `denyWrite` paths and the environment scrub are done. Each item is a
   `lib/settings.nix` change with a `project-settings-test` check, or a
   bootstrap change, plus a `live-check` case where the behaviour is only
   visible live:
   1. Read fence, prototyped live in the test repo on 2026-10-21 and kept
      opt-in: `harness.readFence = true` gives `denyRead ["~/"]` plus
      `allowRead` for the repo and the shell-entry paths (`lib/settings.nix`),
      `harness.extraAllowRead` for what the project reads under `$HOME`.
      Left: turn it on in a real repo and watch what breaks (a `path:`
      devenv input and `~/.cargo` are the known cases), then decide the
      default; `harness check` runs case 13 in a fenced repo.
   2. `permissions.blockReadsOutsideWorkingDirectories = true` last. Any
      scope, `true` wins; it stops the Read tool outside the working
      directories, which also stops a session in the test repo reading the
      harness checkout. Decide per tier (handoff phase 2).
   3. Keyring agent sockets: `denyRead` for `/run/user/*/gcr` and
      `/run/user/*/keyring` next to the `/run/WSL` entry. Every unix socket
      is reachable and the gcr address is guessable; `ssh-add -l` against it
      listed the user's keys from inside the sandbox (changelog 2026-10-21);
      whether the agent signs without a desktop prompt was not measured. If
      the wildcard does not take on Linux, the NixOS module writes the
      literal uid path. `harness check`: `ls /run/user/$(id -u)/gcr` fails
      and `ssh-add -l` against the guessed path gets `Could not open a
      connection`. `harness doctor`: warn when `ssh-add -l` lists a key that
      is not `-sk`. With it: the `lib/ssh-sandbox.nix` header (the gate is
      no usable key in any agent, not an unknown address) and a README line
      on `ssh-add -c` and the hardware-key touch timing.
   4. `<repoRoot>/.claude/worktrees` as a literal `denyWrite` in the main
      checkout's file: a child path neither the literal list nor Claude
      Code's cwd-and-parents protection covers. Check first that a worktree
      session's own file (the worktree as `repoRoot`) still writes there;
      if the parent's deny wins, document sibling worktrees as an accepted
      gap.
   5. Answered 2026-10-22, no: a literal `denyWrite` entry is masked as an
      unreadable device node (changelog), so a file direnv or devenv reads
      can never be one; `devenv.local.*` left the list that day and the
      interpreter-write gap moved to item 2.7. As written: `.envrc`,
      `devenv.nix`, `devenv.yaml` and `.env*` in `repoProtected`
      (`devenv.local.*` is in since 2026-10-21): closes the interpreter
      writes the hook cannot see. Check first that the preamble's `direnv
      export` and devenv's first evaluation write none of them;
      `devenv.lock` is the doubtful one. `harness check`: an interpreter
      write gets a permission error, not the hook's message.
   6. Answered 2026-10-24, no hole: in a session in this checkout `git
      config core.hooksPath` fails with `could not lock config file
      .git/config: File exists` (the sandbox masks `.git/config.lock` as
      `/dev/null`); `harness check` case 15 asserts it, not yet run by
      `harness check` itself, and runbook section 8 names the `-c`,
      `--global` and worktree forms as the accepted gaps (changelog). As
      written: `git config core.hooksPath /tmp/h` inside the sandbox,
      expecting a permission error on `.git/config`.
   7. `devenv.local.nix` and `devenv.local.yaml` can be created by an
      interpreter write the hook does not see, and devenv imports them on
      the next evaluation without a `direnv allow` (the literal `denyWrite`
      that closed this broke the shell, 2026-10-22). Candidate: the `.envrc`
      the template writes fails the load when either file exists (a test
      before `use devenv`), so a harness repo never carries them; the
      checkout's own `.envrc` the same, by hand. `harness check`: a
      `python3` write creating one gets the next command's preamble failing
      loudly, not a silently imported file.
   8. **The tmux socket** (2026-10-24; work it before 2.1: the one open
      item that leaves the sandbox entirely). `allowAllUnixSockets`
      reaches the user's tmux server, which runs outside the sandbox as
      the user: a sandboxed `tmux send-keys`, `run-shell` or `new-window`
      runs a command with no sandbox and no hook, or types a prompt into
      another session's pane. The hook has no tmux rule (synthetic run
      2026-10-24: `run-shell`, `new-window`, `capture-pane` pass). Not
      observed live: no server ran during the check (`tmux ls` in the
      sandbox: `couldn't create directory /run/user/1000/tmux-1000
      (Read-only file system)`, the directory absent); under `ccmux` the
      client takes the path from `$TMUX`, and a socket on the read-only
      `/run/user` mount answers (the gcr case, 2026-10-21). `ccmux` from
      a command-center session uses this path by design, and hook rule 6
      matches `claude`, not `ccmux`: `ccmux <c>/<r> --setting-sources
      user` or `--bare` passes and starts a session with none of the
      repo's rules. Since 2026-10-24 the command center runs without the
      sandbox (`harness.role = "center"`), so it has nothing to escape and
      is out of this item's scope, and its `ccmux` launches cross no
      sandbox boundary. The item stays open for work repos, and the
      center's pane is among those a work session's sandboxed `tmux
      send-keys` can type into, which matters more now that the center
      has no sandbox. The `ccmux` flag hole is closed (2026-10-24): rule 6
      matches `ccmux` as well as `claude` (for `ccmux` outside the
      enforcement roots too) and reads separators inside quotes as text,
      with hook-test cases; the tmux rule of (a) stays open, a separate
      decision. Shapes:
      a. Hook rule: refuse `tmux` unless the subcommand is read-only
         (`ls`, `list-*`, `has-session`, `display-message -p`, `show-*`)
         and the command has no `-C`, `\;` or `source-file`; an allowlist
         because tmux takes unique prefixes (`neww`, `send`, `run`) and
         the executing set is long (`send-keys`, `paste-buffer`,
         `run-shell`, `new-window`, `split-window`, `new-session`,
         `respawn-*`, `pipe-pane`, `if-shell`, `source-file`, `set-hook`,
         `bind-key`, `display-popup`, `display-menu`, `command-prompt`,
         `confirm-before`, `set-option default-command`). Rule 6 becomes
         `(claude|ccmux)`. Keeps `ccmux`; text only, so a script or
         `python` on the socket still gets through.
      b. Private socket: `ccmux` runs tmux with `-S` under a directory the
         repo file can `denyRead` without knowing the uid
         (`~/.local/state/claude-nix-harness/tmux`). The real boundary.
         Costs `ccmux` from inside a sandboxed work session (moot for the
         center, which has no sandbox) unless that repo lists it in
         `sandbox.excludedCommands` (unsandboxed, behind a prompt; verify
         with `allowUnsandboxedCommands = false` and for compound
         commands). A `claude` in the user's own tmux still
         uses the default socket (`/tmp/tmux-<uid>`,
         `$XDG_RUNTIME_DIR/tmux-<uid>`): needs the uid, or a glob
         `denyRead` that holds on Linux (verify).
      c. Claude outside tmux: `tmux-notify.sh` goes quiet (no orange
         window), the session layout is lost, and VS Code's terminal
         brings its own sockets into `/run/user/<uid>`
         (`vscode-ipc-*.sock`, seen 2026-10-24). Not on its own.
      First (a), with hook-test cases: one regex and its tests, `ccmux`
      keeps working, and it closes the flag hole that (b) leaves. Then
      (b) together with 2.3 (the same mechanism, a socket directory in
      `denyRead`). `tmux-notify.sh` must keep working: it runs as a hook,
      outside the sandbox, needs `$TMUX` and `$TMUX_PANE` in claude's
      environment and the socket reachable from there, and only runs
      `set-window-option -t $TMUX_PANE window-status-style` (and `-u`).
      (a) does not touch hooks; (b) must leave `TMUX`/`TMUX_PANE` out of
      `credentials.envVars` unless that list is shown not to reach hook
      environments. `harness check`: from a `ccmux` session, `tmux
      display-message -p '#S'` prints the session name today; after (a)
      the hook refuses `tmux new-window`; after (b) the client cannot
      connect.
   9. **Memory carve-out to the session's own project** (2026-10-24).
      `env-guard.sh` allows `~/.claude/projects/*/memory/*`: a command-
      center session can write a work repo's memory (prompted, outside
      the working directory), and that repo's next session loads it with
      its own flag off. Restrict the case to the slug of
      `$CLAUDE_PROJECT_DIR` (verify Claude Code's slug rule and the
      worktree case); hook-test: another slug's `MEMORY.md` is refused.
3. **devenv-base repo with the `azure` module**: `az` pin, Terraform with
   azurerm/azuread/alz providers, tflint, trivy, and the `AZURE_CONFIG_DIR`
   task under `.git/devenv-base/azure` shared by worktrees.
   `imports: - devenv-base/azure` resolves to `azure/devenv.nix`, same rule
   as `harness/devenv`.
4. **Repo template**: the test repo minus Rust, plus the azure module;
   `harness init` renders it. Convert one real customer repo; confirm
   `az account show` and `terraform plan` inside the sandbox with the
   network allowlist, and record the exact blob hosts the first
   `terraform init` and `trivy` run need.
5. **Reader-only service principal per customer.** The one control that
   holds against every client, including things the hook never sees. Human
   logs it into the repo's `AZURE_CONFIG_DIR`.
6. **Limits suite**: `scripts/live-check.sh` is the first cut. Still to do:
   a throwaway repo (`harness init` into a temporary code root), the cases
   from item 2, the `.devenv/shell-*.sh` litter count over 50 commands,
   `harness doctor --full` running it.
7. **Managed host base config**: a NixOS-WSL base configuration (and later
   a native NixOS one) shipped with the harness, `harness.enable` on both
   modules and nothing else, with the WSL-specific checks (`/run/WSL` and
   `/mnt/c` empty inside the sandbox, `cmd.exe` fails). First time the
   managed layer runs live. 2026-10-23: the module evaluates in `nix
   flake check` (`nixos-module-eval`, `nixos-module-assertion`) and
   `examples/nixos-host.nix` is the import snippet; no generation has been
   activated anywhere. 2026-10-24: the managed layer ran live on the
   NixOS-WSL laptop from 2026-10-23 (generation 8) and was then taken off
   it: the Windows route's host is plain by default
   (`examples/nixos-wsl-plain.nix`, the sandbox prerequisites and nothing
   from the harness), the harness comes afterwards as the user, and the
   managed base config stays as the stricter opt-in
   (`examples/nixos-wsl-host.nix`). What remains here is the native NixOS
   managed host, when someone wants one.
8. **Broker mod: dropped 2026-10-24.** A mod is a hooks module the engine
   loads into every session on the machine, outside the Bash sandbox, and
   an enabled organisation mod is the one kind the built-in guard lets
   through; shipping the broker would have made its code, build,
   marketplace and registration keys a trust surface the harness defends
   on every host, for coordination that never relaxes a rule. Removed the
   same day: `mods/` (the observe slice), `lib/mods.nix`, `harness.mods`,
   the managed marketplace directory with its
   `extraKnownMarketplaces`/`enabledPlugins` wiring, `packages.managed-mods`
   and `packages.harness-broker`, `tests/mod-validate-test.sh`. Kept: the
   policy that refuses mods on a managed host (`allowManagedModsOnly`,
   `strictKnownMarketplaces` empty unless `harness.extraKnownMarketplaces`
   lists a source, `disableSideloadFlags`, `allowManagedHooksOnly`),
   asserted by `managed-tree-test` and `nixos-module-eval`; the bootstrap
   turns account-synced skills and plugins off by default. Coordination
   stays the proposal flow (`docs/sessions.md` section 4) plus `ccmux`; a
   proposal record or a structural gate comes back only through a new
   dated entry here.

## Open questions

- Notification hook: the matcher names (`permission_prompt`, `idle_prompt`,
  `elicitation_dialog`) are in the hooks reference (2026-10-20), with more
  available (`auth_success`, `agent_needs_input`, `agent_completed`).
  Whether the window turns orange in tmux is item 1 above.
- FileChanged matcher: the reference says the value is split on `|` and
  each part is a literal file name in the working directory, so the
  current matcher is right for a session started at the repo root; a
  session started in a subdirectory will not see `devenv.nix` change.
- `AZURE_CONFIG_DIR` shared across worktrees: MSAL lock contention is a
  known risk; revisit if two sessions switch subscriptions under each
  other.
- Per-command env evaluation cost: measure once the azure module is in;
  the SessionStart-only variant is the fallback. 2026-10-22: the case for
  it is no longer cost alone. Five workarounds now exist for running
  direnv and devenv inside the sandbox (changelog, case 2), and the
  SessionStart hook runs outside it, so it could run `direnv export bash`
  once and write the exports into the env file; the cwd-change and
  file-change events would refresh it, if they fire as the hook assumes.
  Deciding it reopens decision 7.3 with a dated entry here. Measured
  2026-10-23 on the NixOS laptop in this checkout: `direnv export bash`
  0.19 to 0.23 s warm, 4.5 s after a change; the hook's `check_env` adds
  36 to 41 ms per Bash call in steady state (changelog).
- Account-synced skills and plugins: decided 2026-10-24 for unmanaged
  hosts, off by default (`harness bootstrap` writes `syncClaudeAiSkills`
  and `syncClaudeAiPlugins = false`; `--account-sync` opts back in,
  `--no-account-sync` is still accepted). The managed settings do not set
  them; whether the managed host should is still open.
- `LD_LIBRARY_PATH` inside a session carries a Nix alsa-lib path that
  neither devenv, direnv nor the harness exports (2026-10-21); the host's
  `code` loads `librt` from the Nix glibc through it and dies. Trace the
  exporter (the launcher, the terminal, Claude Code itself) before the
  managed host, where more host binaries run from sessions. Traced
  2026-10-24 (changelog): nixpkgs' `claude-code` wrapper (`--prefix
  LD_LIBRARY_PATH : <alsa-lib>/lib`), inherited by every hook and Bash
  command. Closed the same day: `pkgs/claude-code.nix` drops the wrapper
  line and puts alsa-lib on the binary's RUNPATH; the home module,
  `packages.claude-code` and (once the human applies the diff) the
  devenv module use it; `claude-code-test` checks it (changelog). Not the
  hook preamble: that would have covered the Bash tool only.

## Ideas, not planned

- `docs/suggestion.md` (2026-10-24): agents built on the Claude Agent SDK
  (the harness's own jobs, headless agents on the managed host; three
  test cases before any code), and the agent's cloud identity (Entra
  Agent ID) as a separate repository with three seams into this one.
- Tighten the hook with the gaps listed in the runbook's known-gaps section:
  gh and package publishing as project rules, git exec-vector config keys,
  az transfer verbs, and a fail-closed rule for dynamic shell constructs
  (`$IFS`, `$(`, `base64 -d |`) inside the enforcement roots. Each one
  starts as a test case. Also: stop matching `*/devenv.nix` when the path
  is the harness's own `devenv/devenv.nix`, which the hook refuses today.
- Edit-rule asymmetry: the hook refuses Edit on `.envrc`, `devenv.*`,
  `.claude/settings*`, `.claude/hooks`, `.claude/skills` and
  `.claude-plugin`; Claude Code's own sandbox also protects `.mcp.json`,
  `.claude/agents`, `.claude/commands`, `.claude/workflows` and `.vscode`
  from Bash writes. Mirror that set in `lib/deny-rules.nix` and the hook's
  `config_files`, or write down why not (`.mcp.json` and `.vscode/tasks.json`
  have their own prompts). `.github/workflows/` is separate: CI runs with
  repository secrets, and "agents never push" is the gate today.
- Remote Control (`claude remote-control`, `claude rc`, `--remote-control`,
  `/rc` in a session): the driven session is the local process, so managed
  settings, hook and sandbox apply unchanged; what changes is that anyone
  holding the claude.ai account can prompt a machine with work credentials
  nearby, and attachments from the phone land on disk as `@` references.
  Needs a claude.ai login (Pro, Max, Team, Enterprise; not API key, Bedrock
  or Foundry), so on this laptop it refuses to start today (2.1.300).
  `disableRemoteControl = true` turns it off everywhere it can start,
  including the in-session toggle; the settings reference lists the key as
  any-file scope (checked 2026-10-21), so the repo file can carry it with a
  `harness.allowRemoteControl` option in the `allowConnectors` shape, and
  the managed file makes it final. Which scope wins when they disagree is
  not stated; assume `true` wins as for `disableBypassPermissionsMode` and
  confirm live. Off until the verification suite exists (the broker it also
  waited for was dropped on 2026-10-24); the
  hook's nested-launch rule does not need the flag once the key is set.
- nix-darwin module: same `lib/`, managed settings under
  `/Library/Application Support/ClaudeCode/`, seatbelt sandbox keys; the
  glob `denyWrite` entries apply there.
- Container route: built and set aside in the claude-nix-harness-container
  repo (same `lib/`, root-owned store behind a nix-daemon, devcontainer
  files per engine; never run under podman or VS Code). The WSL tier does
  not use it; NixOS-WSL builds its distro tarball from the NixOS module.
- A parser-based second guard (cc-safety-net rulebooks) beside the regex
  hook.
- An assertion in `devenv/devenv.nix` that `harness.settings` sets no
  `permissions.deny` and no list under `sandbox` (2026-10-24): merged
  with `recursiveUpdate`, either replaces the harness's own list, and
  only `harness init`'s settings test notices, once. Today
  `docs/project-devenv.md` warns against it.
