# Links the managed tree at /etc/claude-code, root-owned, so every Claude
# Code session on the host is bound by it. The same module serves NixOS-WSL
# at work and native NixOS at home; the options decide how far it reaches.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.harness;
  package = import ../lib/managed-tree.nix {
    inherit pkgs lib;
    inherit (cfg)
      platform
      allowLocalCommits
      allowMemoryEdits
      allowConnectors
      enforcementRoots
      extraDeny
      extraAllowedDomains
      allowManagedHooksOnly
      direnvPackage
      ;
    strictAllowlist = cfg.sandboxStrictAllowlist;
    inherit (cfg) extraKnownMarketplaces;
  };
in
{
  options.harness = {
    enable = lib.mkEnableOption "the guard-railed Claude Code managed configuration";

    platform = lib.mkOption {
      type = lib.types.enum [
        "linux"
        "wsl"
      ];
      default = if lib.attrByPath [ "wsl" "enable" ] false config then "wsl" else "linux";
      defaultText = lib.literalExpression ''if config.wsl.enable then "wsl" else "linux"'';
      description = "Host kind. `wsl` adds the Windows-interop mitigations to the sandbox.";
    };

    enforcementRoots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "~/code/git" ];
      description = ''
        Directories under which the project rules apply. `~` is the session
        user's home. Empty: project rules apply everywhere (a dedicated work
        host). Non-empty: a mixed host whose other sessions keep
        `git commit` and friends.
      '';
    };

    sandboxStrictAllowlist = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Refuse network access to hosts outside the allowlist (true) or prompt for them (false).";
    };

    extraKnownMarketplaces = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      example = lib.literalExpression ''[ { source = "github"; repo = "anthropics/claude-plugins-official"; } ]'';
      description = ''
        Plugin marketplaces a user may add, written as the managed
        `strictKnownMarketplaces` list. Empty, the default: no marketplace
        can be added at all. The harness ships no mods and registers no
        marketplace of its own. A source here lets the user of a mixed host
        add that marketplace and its plugins (their hooks run only with
        `allowManagedHooksOnly = false`); mods stay refused by the built-in
        guard (`allowManagedModsOnly`) whatever this lists.
      '';
    };

    allowLocalCommits = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Let agents commit on their worktree branch. Push stays impossible either way (brief decision 7.5).";
    };

    allowMemoryEdits = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Let agents write their auto-memory under ~/.claude/projects/<slug>/memory/.
        Everything else under ~/.claude stays read-only. Off on a work host:
        memory is a persistent channel into every later session on the
        machine. On for a mixed host where the user wants Claude Code
        to remember things.
      '';
    };

    allowConnectors = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Let the claude.ai account's connectors (Gmail, Drive, Notion, ...)
        load in sessions. They are MCP servers outside the Bash sandbox, so
        off by default; a `false` here holds against every repo and user file.
      '';
    };

    allowManagedHooksOnly = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Only managed and built-in hooks run; user, project and plugin hooks are ignored. Set false where the user relies on plugin hooks.";
    };

    extraDeny = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "Bash(az devops *)" ];
      description = "Additional permission deny rules appended to the managed set.";
    };

    extraAllowedDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "dev.azure.com" ];
      description = "Additional sandbox network allowlist entries.";
    };

    direnvPackage = lib.mkOption {
      type = lib.types.package;
      default = import ../pkgs/direnv.nix { inherit pkgs; };
      defaultText = lib.literalExpression "pkgs.direnv (>= 2.38, overridden while nixpkgs is older)";
      description = "direnv used by the env hook. Must match the user's direnv so `direnv allow` state is shared.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = package;
      description = "The generated managed tree (managed-settings.json, hooks/).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.security.allowUserNamespaces;
        message = "harness: the Claude Code sandbox (bubblewrap) needs security.allowUserNamespaces = true.";
      }
    ];

    # A symlink into the store: root-owned, read-only, replaced atomically on rebuild.
    environment.etc."claude-code".source = package;
  };
}
