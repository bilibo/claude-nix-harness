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
# `harness.enable = false` is the repo owner's off switch: no settings file
# (devenv's files cleanup removes the link it wrote before), so no deny
# rules, hook or sandbox from the repo, and no HARNESS_* exports; a notice
# at every shell entry says so. The packages stay: they are tools, not
# rules. A session cannot set it: the deny rules and the hook refuse its
# edits to devenv.nix, the same as for every other option here. The
# command center can write it into another repo's devenv.nix; it takes
# effect when you `direnv allow` that repo, so read the diff first.
#
# `harness.role = "center"` is the command center (docs/command-center.md):
# the harness checkout, where you launch and review the work repos'
# sessions, and set up and change the work repos. Its file is a work
# repo's with the sandbox off, so Bash commands are prompted instead of
# confined, and with other repos' setup files open: the deny rules and the
# hook refuse devenv.nix, devenv.yaml, devenv.lock, .envrc and .claude/
# hooks and skills in this checkout only (`centerRoot`), and every repo's
# .claude/settings*.json and devenv.local.* as before. Memory is writable
# by default there, and the shell adds the harness's own dev tools. Work
# repos keep the default, `work`.
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
  center = cfg.role == "center";
  harnessLib = import ../lib { inherit lib; };
  projectName = if config.name == null then "project" else config.name;

  # The hook calls `direnv status` and `direnv allow`; any version does, but
  # the same override as the home module keeps the two in step.
  direnvPackage = import ../pkgs/direnv.nix { inherit pkgs; };

  # The command center's checkout; null in a work repo, whose hook and
  # deny rules then carry nothing of the center's (same store paths).
  centerRoot = if center then config.devenv.root else null;

  # Roots empty: this file only loads in sessions started inside the repo.
  hooks = import ../lib/hooks.nix {
    inherit
      pkgs
      lib
      direnvPackage
      centerRoot
      ;
    inherit (cfg) allowLocalCommits allowMemoryEdits;
  };

  ccmux = import ../pkgs/ccmux.nix { inherit pkgs; };
  # nixpkgs' claude-code without the LD_LIBRARY_PATH its wrapper leaks into
  # every command (pkgs/claude-code.nix).
  claudeCode = import ../pkgs/claude-code.nix { inherit pkgs; };
in
{
  options.harness = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        The guard rails for this repo. `false` turns them off: no
        .claude/settings.json (devenv removes the one it wrote before), so
        none of the repo's deny rules, hooks or sandbox, no HARNESS_*
        exports, and a one-line notice at shell entry. The packages (ccmux,
        claudeCode.enable's, the center's tools) stay. A managed host's
        root-owned settings apply either way.
      '';
    };

    role = lib.mkOption {
      type = lib.types.enum [
        "work"
        "center"
      ];
      default = "work";
      description = ''
        `work`: a repo sessions work in, under the full set. `center`: the
        command center (docs/command-center.md), the harness checkout from
        which you launch and review the work repos' sessions. Its sandbox is
        off (`sandbox.enabled = false`): no network allowlist, no filesystem
        confinement, and Bash commands go through Claude Code's ordinary
        permission prompts instead of the sandbox's auto-allow. The
        deny rules and the hook are a work repo's but for the setup files
        of other repos: devenv.nix, devenv.yaml, devenv.lock, .envrc and
        .claude/ skills and hooks are refused in this checkout only, so
        the center can set up and change the work repos; every repo's
        .claude/settings*.json and devenv.local.* stay refused. There
        `allowMemoryEdits` and `claudeCode.enable` default to true,
        `readFence` is ignored (the center reads the whole code root),
        `extraAllowRead` and `extraAllowedDomains` have nothing to apply
        to, and the shell adds nixfmt, statix, deadnix and shellcheck. If
        the prompts annoy you, `settings.permissions.allow = [ "Bash(*)" ]`
        allows every command without one; the deny rules and the hook still
        win over it, but they match command text, and with neither sandbox
        nor prompt nothing else stands between a command and the network or
        the credential files. A managed host's settings keep the sandbox on
        whatever this says. Exported to the shell as HARNESS_ROLE.
      '';
    };

    allowLocalCommits = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Let agents commit on their worktree branch (push stays impossible). Match the host's harness.allowLocalCommits where there is one.";
    };

    allowMemoryEdits = lib.mkOption {
      type = lib.types.bool;
      default = center;
      defaultText = lib.literalExpression ''config.harness.role == "center"'';
      description = "Let agents write their auto-memory under ~/.claude/projects. On by default in the command center only (`role`). Match the host's harness.allowMemoryEdits where there is one.";
    };

    allowConnectors = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Let the claude.ai account's connectors (Gmail, Drive, Notion, ...) load in sessions in this repo. They are MCP servers outside the Bash sandbox. A user or managed `false` wins over a `true` here.";
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

    readFence = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Hide the rest of your home directory from sandboxed commands:
        `denyRead ["~/"]` plus `allowRead` for this repo and the paths the
        devenv shell entry needs (lib/settings.nix). Sibling repos and
        `~/.claude/.credentials.json` become unreadable from the shell. Add
        what the project itself reads under `$HOME` with `extraAllowRead`.
        Ignored with `role = "center"`.
      '';
    };

    extraAllowRead = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "~/.cargo" ];
      description = "Further sandbox `allowRead` paths for a repo with `readFence` on, such as a `path:` devenv input or a tool's cache under `$HOME`.";
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

    claudeCode.enable = lib.mkOption {
      type = lib.types.bool;
      default = center;
      defaultText = lib.literalExpression ''config.harness.role == "center"'';
      example = true;
      description = "claude-code, tmux and jq in the project shell, for hosts where no home module installs them; on by default in the command center. Needs `allow_unfree: true` in devenv.yaml.";
    };

    managedSettingsPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/claude-code/managed-settings.json";
      description = "Where a managed host keeps the managed settings; checked at shell entry when HARNESS_EXPECT_MANAGED is set.";
    };

  };

  config = lib.mkMerge [
    # Tools, not rules: in the shell whether or not the guard rails are on.
    # `ccmux` in the project shell only; the home module adds it host-wide
    # on managed hosts.
    {
      packages = [
        ccmux
      ]
      ++ lib.optionals cfg.claudeCode.enable [
        claudeCode
        pkgs.tmux
        pkgs.jq # install.sh's self-check reads the generated settings with it
      ]
      # The command center maintains the harness: CLAUDE.md's lint tools.
      ++ lib.optionals center [
        pkgs.nixfmt
        pkgs.statix
        pkgs.deadnix
        pkgs.shellcheck
      ];
    }

    (lib.mkIf cfg.enable {
      files.".claude/settings.json".json = lib.recursiveUpdate (harnessLib.projectSettings {
        hookDir = "${hooks}";
        repoRoot = config.devenv.root;
        inherit centerRoot;
        # The center: no sandbox, and so no read fence to put in it.
        sandbox = !center;
        readFence = cfg.readFence && !center;
        inherit (cfg)
          platform
          extraAllowRead
          allowLocalCommits
          allowMemoryEdits
          allowConnectors
          extraDeny
          extraAllowedDomains
          ;
      }) cfg.settings;

      enterShell = ''
        # The harness home module exports HARNESS_EXPECT_MANAGED on hosts that
        # are meant to carry managed settings; an unmanaged host without the
        # module runs on the repo file alone and stays quiet.
        if [ -n "''${HARNESS_EXPECT_MANAGED:-}" ] && [ ! -r "${cfg.managedSettingsPath}" ]; then
          echo "harness: ${cfg.managedSettingsPath} is missing: repo rules only, no mod policy on this host" >&2
        fi
        # Name this project for `ccmux`: <customer>/<repo> relative to the code
        # root, from the main checkout or any worktree under it, else
        # local/<name> with the directory alongside. A bare `ccmux` in this
        # shell then opens the right tmux session.
        _harness_root="''${HARNESS_CODE_ROOT:-$HOME/code/git}"; _harness_root="''${_harness_root%/}"
        if [[ "$DEVENV_ROOT" == "$_harness_root/"*/* ]]; then
          _harness_rel="''${DEVENV_ROOT#"$_harness_root/"}"
          IFS=/ read -r _harness_a _harness_b _ <<<"$_harness_rel"
          export HARNESS_PROJECT="$_harness_a/$_harness_b"
          unset _harness_rel _harness_a _harness_b HARNESS_PROJECT_DIR
        else
          export HARNESS_PROJECT="local/${projectName}"
          export HARNESS_PROJECT_DIR="$DEVENV_ROOT"
        fi
        unset _harness_root
        # harness.role: `center` in the command center, `work` elsewhere.
        export HARNESS_ROLE=${cfg.role}
      '';
    })

    # Off: no file, so devenv's files cleanup removes the settings link from
    # the last shell entry, and no HARNESS_PROJECT, so nothing reads this
    # repo as governed (a bare `ccmux` still resolves it from the cwd under
    # the code root). Said at every entry, never silent.
    (lib.mkIf (!cfg.enable) {
      enterShell = ''
        echo "harness: guard rails off for this repo (harness.enable = false in devenv.nix)" >&2
      '';
    })
  ];
}
