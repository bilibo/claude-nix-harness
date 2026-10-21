# direnv >= 2.38 adds `require_allowed`, the only way to re-block an .envrc
# when devenv.nix / devenv.yaml / devenv.lock change. nixpkgs still ships
# 2.37.1 (checked 2026-10-17). Once pkgs.direnv is 2.38 or newer this is
# pkgs.direnv itself; delete the file then and import pkgs.direnv instead.
{ pkgs }:
if pkgs.lib.versionOlder pkgs.direnv.version "2.38" then
  pkgs.direnv.overrideAttrs (old: rec {
    version = "2.38.2";
    src = pkgs.fetchFromGitHub {
      owner = "direnv";
      repo = "direnv";
      tag = "v${version}";
      hash = "sha256-0TVuQ0TEqkkCo36zrdFbfZ+FJSVrvNA7egAcsS9YFtA=";
    };
    vendorHash = "sha256-3ojb8iLIzhjUZa7Gt+gJjOFy9qm4LOrFBLZ6fk5x1HM=";
  })
else
  pkgs.direnv
