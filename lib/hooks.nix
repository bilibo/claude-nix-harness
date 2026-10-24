# The two hook scripts as one store path, shared by the managed tree
# (/etc/claude-code/hooks) and by the repo settings the devenv module writes,
# which point at the store path directly.
{
  pkgs,
  lib,
  direnvPackage,
  allowLocalCommits ? false,
  allowMemoryEdits ? false,
  # Empty: project rules everywhere. The repo settings always build with an
  # empty list, since that file only loads in sessions started in the repo.
  enforcementRoots ? [ ],
  # The command center's checkout (`harness.role = "center"`,
  # docs/command-center.md), or null. Set: env-guard.sh with
  # hooks/center-guard.sh spliced in, other repos' setup files open and this
  # root's closed. null builds env-guard.sh as it is, so a work repo's hook
  # is the same store path whatever the center's does.
  centerRoot ? null,
}:
# It is written into the hook between double quotes, and the hook splits
# command text on spaces: a plain path only.
assert lib.assertMsg
  (centerRoot == null || builtins.match "(/[A-Za-z0-9._+-]+)+" centerRoot != null)
  "lib/hooks.nix: centerRoot must be a plain absolute path (letters, digits, ._+-), not ${toString centerRoot}";
let
  mkHook =
    name: src: tools: extra:
    pkgs.replaceVarsWith {
      inherit name src;
      isExecutable = true;
      replacements = {
        path = lib.makeBinPath tools;
      }
      // extra;
    };

  # Three exact lines of env-guard.sh (`--replace-fail`: a changed line fails
  # the build): the two config-file refusals ask center-guard.sh first, and
  # center-guard.sh goes in below the substituted variables, last, so its
  # comments are left alone.
  centerGuardSrc = pkgs.runCommand "env-guard-center.sh" { } ''
    substitute ${../hooks/env-guard.sh} $out \
      --replace-fail 'deny "edit of $1 is forbidden (config/env/credentials/plugin)"' \
        'center_open "$1" || deny "edit of $1 is forbidden (config/env/credentials/plugin)"' \
      --replace-fail 'deny "shell write to config file blocked"' \
        'center_shell_ok || deny "shell write to config file blocked"' \
      --replace-fail 'ENFORCEMENT_ROOTS="@enforcementRoots@"' \
        "$(printf '%s\n' 'ENFORCEMENT_ROOTS="@enforcementRoots@"'; cat ${../hooks/center-guard.sh})"
  '';

  envGuard =
    mkHook "env-guard.sh" (if centerRoot == null then ../hooks/env-guard.sh else centerGuardSrc)
      [
        pkgs.jq
        direnvPackage
        pkgs.coreutils
        pkgs.diffutils
        pkgs.findutils
        pkgs.gnused
      ]
      (
        {
          allowLocalCommits = if allowLocalCommits then "1" else "0";
          allowMemoryEdits = if allowMemoryEdits then "1" else "0";
          enforcementRoots = lib.concatStringsSep ":" enforcementRoots;
        }
        // lib.optionalAttrs (centerRoot != null) { inherit centerRoot; }
      );
  tmuxNotify = mkHook "tmux-notify.sh" ../hooks/tmux-notify.sh [ pkgs.tmux ] { };
in
pkgs.runCommand "claude-nix-harness-hooks" { } ''
  mkdir -p $out
  cp ${envGuard} $out/env-guard.sh
  cp ${tmuxNotify} $out/tmux-notify.sh
  chmod 0555 $out/*
  # `#!/usr/bin/env bash` -> the store bash: the hook depends on nothing
  # outside the store, and the tests run inside the Nix sandbox.
  patchShebangs $out
''
