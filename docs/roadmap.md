# Roadmap

What exists, what is next, and ideas that are not committed to. Numbers in
parentheses refer to sections of the original build brief.

## Done

- NixOS module: managed settings, hook, sandbox, mod policy, directory
  scoping, per-host options (5.2)
- home-manager module: direnv, tmux, `ccmux` (5.1, without the broker signal)
- devenv module: generated project settings, host check
- Hook unit tests (154 cases, 180 with enforcement roots), the generated
  repo settings file and ccmux resolver tests, run by `nix flake check`
  (part of 5.6)
- Own repo with a `flake.nix` exporting `nixosModules.harness`,
  `homeModules.harness`, `lib`, the managed trees as packages and the tests
  as `checks` (2026-10-17)
- Verified against a real project repo (Azure Functions, Rust)
- Host prerequisites settled: trusted-users, direnv 2.38
- Repo-only shape (2026-10-18): one settings body for the managed and the
  repo copy, the devenv module writes hooks and sandbox too, the hook
  blocks `settings.local.json` changes and nested `claude` launch flags,
  `project-settings-test` in `nix flake check`. An unmanaged host needs no
  host modules; the managed layer is the managed-host shape.

## Next, in order

The tier, read-fence, customer-module and `ccmux` subcommand work is
phased in `docs/handoff-tiers.md`; this list keeps the overall order.

0. **Bootstrap for any Linux** (decided 2026-10-19, not yet designed): an
   install script that puts Nix, devenv and direnv on the host and the
   managed tree at /etc/claude-code, so a non-NixOS machine gets the
   managed-host tier with one command. The WSL tier builds on it too.
1. **Verify the repo-only shape live.** On an unmanaged host: `direnv
   reload` in a harness repo, accept the trust dialog once, run the live
   checks in the runbook. First time a real session runs on the repo file
   alone.
2. **devenv-base repo with the `azure` module** (5.3): `az` pin, Terraform
   with azurerm/azuread/alz providers, tflint, trivy, and the
   `AZURE_CONFIG_DIR` task under `.git/devenv-base/azure` shared by
   worktrees. `imports: - devenv-base/azure` resolves to
   `azure/devenv.nix`, same rule as `harness/devenv`.
3. **Repo template** (5.4): the test repo minus Rust, plus the azure module.
   Convert one real customer repo; confirm `az account show` and
   `terraform plan` inside the sandbox with the network allowlist, and
   record the exact blob hosts the first `terraform init` and `trivy` run
   need.
4. **Reader-only service principal per customer** (7.1). The one control
   that holds against every client, including things the hook never sees.
   Human logs it into the repo's `AZURE_CONFIG_DIR`.
5. **Live verification suite** (5.6): the runbook's manual checks as a
   script, run against a throwaway repo, one case per hard limit. Include
   the `.devenv/shell-*.sh` litter count over 50 commands.
6. **Managed host base config**: a NixOS-WSL base configuration (and later
   a native NixOS one) shipped with the harness, `harness.enable`
   on both modules and nothing else, with the WSL-specific checks
   (`/run/WSL` and `/mnt/c` empty inside the sandbox, `cmd.exe` fails).
   First time the managed layer runs live.
7. **Broker mod** (5.7): observe-only, `/fleet` table from a file under
   `$XDG_RUNTIME_DIR`, deployed through the managed marketplace directory,
   `claude plugin validate` output as the contract. Only after everything
   above is boring.

## Open questions

- Notification hook: the matcher names (`permission_prompt`, `idle_prompt`,
  `elicitation_dialog`) come from the docs index, not verified live. If the
  window never turns orange, that is the first suspect.
- FileChanged matcher syntax: assumed to be a file-name pattern.
- `AZURE_CONFIG_DIR` shared across worktrees (7.2): MSAL lock contention is
  a known risk; revisit if two sessions switch subscriptions under each
  other.
- Per-command env evaluation cost (7.3): measure once the azure module is
  in; the SessionStart-only variant is the fallback.

## Ideas, not planned

- Tighten the hook with the gaps listed in the runbook's known-gaps section:
  gh and package publishing as project rules, git exec-vector config keys,
  az transfer verbs, and a fail-closed rule for dynamic shell constructs
  (`$IFS`, `$(`, `base64 -d |`) inside the enforcement roots. Each one
  starts as a test case.
- Remote Control (`claude remote-control`): the driven session is the local
  process, so managed settings, hook and sandbox apply unchanged; what
  changes is that anyone holding the claude.ai account can prompt a machine
  with work credentials nearby. Per-host opt-in, off on a managed host until
  the broker and the verification suite exist; check whether managed
  settings can disable it outright.
- nix-darwin module: same `lib/`, managed settings under
  `/Library/Application Support/ClaudeCode/`, seatbelt sandbox keys.
- Container route: built and set aside in the claude-nix-harness-container
  repo (same `lib/`, root-owned store behind a nix-daemon, devcontainer
  files per engine; never run under podman or VS Code). The WSL tier does
  not use it; NixOS-WSL builds its distro tarball from the NixOS module.
- A parser-based second guard (cc-safety-net rulebooks) beside the regex
  hook (7.6).
- A `wsl/` or nix-darwin module alongside `nixos/`, consuming the same
  `lib/`.
