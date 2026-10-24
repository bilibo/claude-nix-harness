# claude-nix-harness

Guard-railed Claude Code for hosts with Nix. This checkout is itself a
harness repo with `harness.role = "center"` (since 2026-10-24 the root
`devenv.yaml` imports the harness module pinned from GitHub, like a work
repo, so the working tree's `hooks/` and `lib/` are not this shell's live
rules until the human runs `devenv update harness`), so a session here
runs under the repo file: the hook refuses edits to `devenv.nix`,
`devenv.yaml`, `devenv/devenv.nix`, `.envrc` and `.claude/`; propose those
as diffs. No sandbox in the center: Bash is prompted, and the credential
paths are reachable by scripts (`docs/command-center.md`, section 5).
Other repos' setup files (`devenv.nix`, `devenv.yaml`, `devenv.lock`,
`.envrc`, `.claude/` skills and hooks) are open to a center session by
the Edit tool or one shell command naming the absolute path; every
repo's `.claude/settings*.json` and `devenv.local.*` stay refused.
Agents stage and diff; the human commits and pushes.

## Which document owns what

- `README.md`: current state, the layers, the host and lockdown tables.
- `docs/roadmap.md`: what is next, in order; its "Done" list is what exists.
- `docs/changelog.md`: dated history, newest first, with what was learned.
- `docs/handoff-tiers.md`: the tier, read-fence and customer-module phases,
  and the standing rule: never activate a NixOS or home-manager generation,
  never change flake inputs without asking.
- `docs/sessions.md`: how sessions coordinate (tiers, proposals).
- `docs/command-center.md`: this checkout as the command center: what a
  session started here may and may not do, and the memory decision.
- `docs/runbook.md`: what the operator types; written for the human.
- `docs/project-devenv.md`: a project's `devenv.nix`, for a human who
  does not know Nix; `harness init`'s template links it.
- `docs/suggestion.md`: ideas with a shape but no commitment; the
  roadmap's "Ideas, not planned" points here.

A closed decision is reopened only by a new dated roadmap or changelog
entry, never by editing the old one. Dates are absolute, never relative.

## Checks

A bare `nix flake check` fails inside a sandboxed session, and so does
`path:` on the checkout: the sandbox masks the checkout's untracked dotfiles
(`.bashrc`, `.gitmodules`, `.vscode`, ...) as device nodes or empty files,
which the `path:` fetcher refuses. Run it on a copy of the regular files
only:

```
git ls-files -co --exclude-standard -z \
  | while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done \
  | tar --null -T - -cf - | tar -xf - -C <dir>
nix flake check path:<dir>
```

One check at a time: `nix build path:<dir>#checks.x86_64-linux.<name>
--no-link -L`. Before handing over Nix changes: format, `statix`,
`deadnix`; never pass `self` into a package. From a session `nix fmt`
finds no tree root in the copy and walks the whole visible filesystem
(six minutes, nothing formatted, 2026-10-24), so run the tools on the
files: `nixfmt --check $(git ls-files -- '*.nix')` (`nix shell
nixpkgs#nixfmt`), `nix run nixpkgs#statix -- check <file>`, `nix run
nixpkgs#deadnix -- --fail <file>`.
