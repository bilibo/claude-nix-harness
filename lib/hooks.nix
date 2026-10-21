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
}:
let
  mkHook =
    name: tools: extra:
    pkgs.replaceVarsWith {
      inherit name;
      src = ../hooks/${name};
      isExecutable = true;
      replacements = {
        path = lib.makeBinPath tools;
      }
      // extra;
    };

  envGuard =
    mkHook "env-guard.sh"
      [
        pkgs.jq
        direnvPackage
        pkgs.coreutils
        pkgs.diffutils
        pkgs.findutils
        pkgs.gnused
      ]
      {
        allowLocalCommits = if allowLocalCommits then "1" else "0";
        allowMemoryEdits = if allowMemoryEdits then "1" else "0";
        enforcementRoots = lib.concatStringsSep ":" enforcementRoots;
      };
  tmuxNotify = mkHook "tmux-notify.sh" [ pkgs.tmux ] { };
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
