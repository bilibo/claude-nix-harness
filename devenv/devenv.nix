# Every repo under the harness imports this from devenv.yaml:
#
#   inputs:
#     harness:
#       url: git+https://...  (or path:..., flake: false)
#   imports:
#     - harness/devenv
#
# It writes the repo's .claude/settings.json with everything a repo can
# enforce on its own: the full deny set, every hook (store paths), the
# sandbox and the SSH rule. On a host without managed settings (an unmanaged
# host) that file is the whole harness; on a managed host the root-owned
# copy adds what only it can (mod policy, immunity to user settings) and
# `allowManagedHooksOnly` keeps the repo's hooks from running twice.
#
# direnv runs `devenv direnv-export` for humans and for every Claude Code
# Bash command alike, so everything in enterShell happens on both paths.
# Project tools (az, terraform, ...) belong in the project's own devenv.nix
# or in devenv-base, not here.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.harness;
  harnessLib = import ../lib { inherit lib; };
  projectName = if config.name == null then "project" else config.name;

  # The hook calls `direnv status` and `direnv allow`; any version does, but
  # the same override as the home module keeps the two in step.
  direnvPackage =
    if lib.versionOlder pkgs.direnv.version "2.38" then
      import ../pkgs/direnv.nix { inherit pkgs; }
    else
      pkgs.direnv;

  # Roots empty: this file only loads in sessions started inside the repo.
  hooks = import ../lib/hooks.nix {
    inherit pkgs lib direnvPackage;
    inherit (cfg) allowLocalCommits allowMemoryEdits;
  };

  ccmux = import ../pkgs/ccmux.nix { inherit pkgs; };
in
{
  options.harness = {
    allowLocalCommits = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Let agents commit on their worktree branch (push stays impossible). Match the host's harness.allowLocalCommits where there is one.";
    };

    allowMemoryEdits = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Let agents write their auto-memory under ~/.claude/projects. Match the host's harness.allowMemoryEdits where there is one.";
    };

    platform = lib.mkOption {
      type = lib.types.enum [
        "linux"
        "wsl"
      ];
      default = "linux";
      description = "Host kind the repo is used on. `wsl` adds the Windows-interop entries to the sandbox.";
    };

    extraDeny = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "Bash(az devops *)" ];
      description = "Additional permission deny rules appended to the harness set.";
    };

    extraAllowedDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "dev.azure.com" ];
      description = ''
        Additional sandbox network allowlist entries for this repo. Effective
        on a host without managed settings; a managed host makes the sandbox
        admin-required and Claude Code then ignores a repo's allowlist, so
        add the host there (`harness.extraAllowedDomains` in the NixOS module).
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      example = {
        permissions.allow = [ "Bash(terraform plan *)" ];
      };
      description = ''
        Extra project settings merged into the generated .claude/settings.json.
        Lists replace rather than append; use `extraDeny` and
        `extraAllowedDomains` to add to the harness lists.
      '';
    };

    managedSettingsPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/claude-code/managed-settings.json";
      description = "Where a managed host keeps the managed settings; checked at shell entry when HARNESS_EXPECT_MANAGED is set.";
    };

  };

  config = lib.mkMerge [
    {
      files.".claude/settings.json".json = lib.recursiveUpdate (harnessLib.projectSettings {
        hookDir = "${hooks}";
        inherit (cfg)
          platform
          allowLocalCommits
          allowMemoryEdits
          extraDeny
          extraAllowedDomains
          ;
      }) cfg.settings;

      # `ccmux` in the project shell only; the home module adds it host-wide
      # on managed hosts.
      packages = [ ccmux ];

      enterShell = ''
        # The harness home module exports HARNESS_EXPECT_MANAGED on hosts that
        # are meant to carry managed settings; an unmanaged host without the
        # module runs on the repo file alone and stays quiet.
        if [ -n "''${HARNESS_EXPECT_MANAGED:-}" ] && [ ! -r "${cfg.managedSettingsPath}" ]; then
          echo "harness: ${cfg.managedSettingsPath} is missing: repo rules only, no mod policy on this host" >&2
        fi
        # Name this project for `ccmux`: <customer>/<repo> relative to the code
        # root, from the main checkout or any worktree under it. A bare `ccmux`
        # in this shell then opens the right tmux session.
        _harness_root="''${HARNESS_CODE_ROOT:-$HOME/code/git}"; _harness_root="''${_harness_root%/}"
        if [[ "$DEVENV_ROOT" == "$_harness_root/"*/* ]]; then
          _harness_rel="''${DEVENV_ROOT#"$_harness_root/"}"
          IFS=/ read -r _harness_a _harness_b _ <<<"$_harness_rel"
          export HARNESS_PROJECT="$_harness_a/$_harness_b"
          unset _harness_rel _harness_a _harness_b
        fi
        unset _harness_root
      '';
    }
  ];
}
