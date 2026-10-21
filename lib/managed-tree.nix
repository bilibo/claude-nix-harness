# One store path, linked at /etc/claude-code on the host.
{
  pkgs,
  lib,
  platform ? "linux",
  allowLocalCommits ? false,
  allowMemoryEdits ? false,
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
      enforcementRoots
      extraDeny
      extraAllowedDomains
      allowManagedHooksOnly
      strictAllowlist
      extraKnownMarketplaces
      ;
    hookDir = "${managedDir}/hooks";
    marketplaceDir = "${managedDir}/plugins";
  };
  settingsJson = (pkgs.formats.json { }).generate "managed-settings.json" settings;
in
pkgs.runCommand "claude-nix-harness-managed" { } ''
  mkdir -p $out/plugins/.claude-plugin
  cp ${settingsJson} $out/managed-settings.json
  cp -r ${hooks} $out/hooks
  # The broker mod lands here later (brief 5.7).
  cat > $out/plugins/.claude-plugin/marketplace.json <<'JSON'
  { "name": "harness", "owner": { "name": "claude-nix-harness" }, "plugins": [] }
  JSON
''
