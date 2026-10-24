# One store path, linked at /etc/claude-code on the host: the managed
# settings and the hooks they call. No plugin or marketplace directory: the
# harness ships no mods (2026-10-24, docs/sessions.md section 5), and the
# managed settings refuse every mod (lib/settings.nix).
{
  pkgs,
  lib,
  platform ? "linux",
  allowLocalCommits ? false,
  allowMemoryEdits ? false,
  allowConnectors ? false,
  enforcementRoots ? [ ],
  extraDeny ? [ ],
  extraAllowedDomains ? [ ],
  allowManagedHooksOnly ? true,
  strictAllowlist ? true,
  extraKnownMarketplaces ? [ ],
  direnvPackage ? import ../pkgs/direnv.nix { inherit pkgs; },
  # The JSON refers to its own hooks by this stable path, not by store path.
  managedDir ? "/etc/claude-code",
}:
let
  harnessLib = import ./default.nix { inherit lib; };

  hooks = import ./hooks.nix {
    inherit
      pkgs
      lib
      direnvPackage
      allowLocalCommits
      allowMemoryEdits
      enforcementRoots
      ;
  };

  settings = harnessLib.settings {
    managed = true;
    inherit
      platform
      allowLocalCommits
      allowMemoryEdits
      allowConnectors
      enforcementRoots
      extraDeny
      extraAllowedDomains
      allowManagedHooksOnly
      strictAllowlist
      extraKnownMarketplaces
      ;
    hookDir = "${managedDir}/hooks";
  };
  settingsJson = (pkgs.formats.json { }).generate "managed-settings.json" settings;
in
pkgs.runCommand "claude-nix-harness-managed" { } ''
  mkdir -p $out
  cp ${settingsJson} $out/managed-settings.json
  cp -r ${hooks} $out/hooks
''
