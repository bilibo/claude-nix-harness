{
  description = "claude-nix-harness: guard-railed, project-scoped Claude Code for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      managedTree = pkgs: args: import ./lib/managed-tree.nix ({ inherit pkgs; inherit (pkgs) lib; } // args);
    in
    {
      nixosModules.harness = ./nixos;
      nixosModules.default = self.nixosModules.harness;

      homeModules.harness = ./home;
      homeModules.default = self.homeModules.harness;
      # Older name for the same outputs.
      homeManagerModules = self.homeModules;

      # For other module systems, e.g. a future nix-darwin module.
      lib = import ./lib { inherit (nixpkgs) lib; };

      packages = forAll (
        pkgs:
        let
          hooks = import ./lib/hooks.nix {
            inherit pkgs;
            inherit (pkgs) lib;
            direnvPackage = import ./pkgs/direnv.nix { inherit pkgs; };
          };
        in
        {
          # A dedicated work host: every rule everywhere.
          managed = managedTree pkgs { };
          # A mixed host: project rules only under the roots.
          managed-scoped = managedTree pkgs {
            enforcementRoots = [ "~/code/git" ];
            strictAllowlist = false;
          };
          # What the devenv module writes into a repo, with default options.
          project-settings = (pkgs.formats.json { }).generate "claude-settings.json" (
            (import ./lib { inherit (pkgs) lib; }).projectSettings { hookDir = "${hooks}"; }
          );
          # bin/ccmux and bin/ccode (the former name).
          ccmux = import ./pkgs/ccmux.nix { inherit pkgs; };
          # What install.sh puts in the user's profile on a host without Nix.
          devenv = pkgs.devenv;
          direnv = import ./pkgs/direnv.nix { inherit pkgs; };
          ccode = self.packages.${pkgs.stdenv.hostPlatform.system}.ccmux;
          default = self.packages.${pkgs.stdenv.hostPlatform.system}.managed;
        }
      );

      # The hook's out-of-root cases only run with roots set, hence both trees.
      checks = forAll (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          p = self.packages.${system};
          # The worktree .envrc auto-allow calls direnv; this stand-in logs the
          # calls and answers `status` from an env var (hook-test.sh --direnv-stub).
          direnvStub = pkgs.writeShellScriptBin "direnv" ''
            echo "direnv $*" >> "''${DIRENV_STUB_LOG:-/dev/null}"
            case "$1" in status) printf '%s' "''${DIRENV_STUB_STATUS:-}" ;; esac
          '';
          stubHooks = import ./lib/hooks.nix {
            inherit pkgs;
            inherit (pkgs) lib;
            direnvPackage = direnvStub;
          };
          test =
            name: script: args:
            pkgs.runCommand name
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.jq # the tests build and inspect JSON with jq
                ];
              }
              ''
                export HOME=$TMPDIR
                bash ${script} ${args} | tee $out
              '';
        in
        {
          hook-test = test "hook-test" ./tests/hook-test.sh "${p.managed}/hooks/env-guard.sh";
          hook-test-scoped = test "hook-test-scoped" ./tests/hook-test.sh "${p.managed-scoped}/hooks/env-guard.sh";
          hook-test-worktree = test "hook-test-worktree" ./tests/hook-test.sh "${stubHooks}/env-guard.sh --direnv-stub";
          project-settings-test = test "project-settings-test" ./tests/project-settings-test.sh "${p.project-settings}";
          ccmux-test = test "ccmux-test" ./tests/ccmux-test.sh "${p.ccmux}/bin/ccmux";
          ccode-test = test "ccode-test" ./tests/ccmux-test.sh "${p.ccmux}/bin/ccode";
          host-config-test = test "host-config-test" ./tests/host-config-test.sh "${./pkgs/direnv.toml} ${./pkgs/tmux.conf}";
          install-test = test "install-test" ./tests/install-test.sh "${self}/install.sh";
        }
      );
    };
}
