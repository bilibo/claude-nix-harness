{
  description = "claude-nix-harness: project-scoped, guard-railed Claude Code for any host with Nix; NixOS adds the managed layer";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      harnessLib = pkgs: import ./lib { inherit (pkgs) lib; };
      managedTree =
        pkgs: args:
        import ./lib/managed-tree.nix (
          {
            inherit pkgs;
            inherit (pkgs) lib;
          }
          // args
        );
    in
    {
      nixosModules.harness = ./nixos;
      nixosModules.default = self.nixosModules.harness;

      homeModules.harness = ./home;
      homeModules.default = self.homeModules.harness;

      # For other module systems, e.g. a future nix-darwin module.
      lib = import ./lib { inherit (nixpkgs) lib; };

      packages = forAll (
        pkgs:
        let
          direnvPackage = import ./pkgs/direnv.nix { inherit pkgs; };
          hooks = import ./lib/hooks.nix {
            inherit pkgs direnvPackage;
            inherit (pkgs) lib;
          };
          # The command center's hook at /repo: memory writable, its default
          # there, and center-guard.sh spliced in.
          centerHooks = import ./lib/hooks.nix {
            inherit pkgs direnvPackage;
            inherit (pkgs) lib;
            allowMemoryEdits = true;
            centerRoot = "/repo";
          };
        in
        {
          # Host tools for an unmanaged host, pinned by this flake's lock:
          # `nix profile add path:<checkout>#direnv path:<checkout>#devenv`
          # (`harness bootstrap` does this). The same direnv the hooks
          # call, the same devenv the modules assume.
          direnv = direnvPackage;
          inherit (pkgs) devenv;
          # A dedicated work host: every rule everywhere.
          managed = managedTree pkgs { };
          # A mixed host: project rules only under the roots.
          managed-scoped = managedTree pkgs {
            enforcementRoots = [ "~/code/git" ];
            strictAllowlist = false;
          };
          # What the devenv module writes into a repo, with default options;
          # `/repo` stands for the checkout path devenv passes.
          project-settings = (pkgs.formats.json { }).generate "claude-settings.json" (
            (harnessLib pkgs).projectSettings {
              hookDir = "${hooks}";
              repoRoot = "/repo";
            }
          );
          # The same with the read fence on (`harness.readFence = true`).
          project-settings-fenced = (pkgs.formats.json { }).generate "claude-settings-fenced.json" (
            (harnessLib pkgs).projectSettings {
              hookDir = "${hooks}";
              repoRoot = "/repo";
              readFence = true;
              extraAllowRead = [ "~/.cargo" ];
            }
          );
          # The same at a real-looking path: harness init runs the test on the
          # file devenv wrote for the actual repo, never at /repo.
          project-settings-elsewhere = (pkgs.formats.json { }).generate "claude-settings-elsewhere.json" (
            (harnessLib pkgs).projectSettings {
              hookDir = "${hooks}";
              repoRoot = "/home/acme/code/git/acme/demo";
            }
          );
          # What the module writes for `harness.role = "center"` with its
          # defaults: the sandbox off, memory writable, the setup-file rules
          # for /repo only, the rest as above.
          project-settings-center = (pkgs.formats.json { }).generate "claude-settings-center.json" (
            (harnessLib pkgs).projectSettings {
              hookDir = "${centerHooks}";
              repoRoot = "/repo";
              centerRoot = "/repo";
              sandbox = false;
              allowMemoryEdits = true;
            }
          );
          ccmux = import ./pkgs/ccmux.nix { inherit pkgs; };
          # bin/harness: bootstrap, upgrade, doctor, init, check, reset.
          harness = import ./pkgs/harness.nix {
            inherit pkgs;
            rev = self.rev or self.dirtyRev or "dirty";
          };
          default = self.packages.${pkgs.stdenv.hostPlatform.system}.managed;
        }
        # claude-code is unfree: exported, like the check below, only when the
        # evaluator allows it. The home and devenv modules use the same file.
        // pkgs.lib.optionalAttrs (builtins.tryEval pkgs.claude-code.outPath).success {
          # pkgs.claude-code without the LD_LIBRARY_PATH its wrapper leaks
          # into every hook, command and MCP server (pkgs/claude-code.nix),
          # for a host that installs Claude Code from this flake.
          claude-code = import ./pkgs/claude-code.nix { inherit pkgs; };
        }
      );

      # `nix fmt`: nixfmt over every .nix file (treefmt-wrapped).
      formatter = forAll (pkgs: pkgs.nixfmt-tree);

      # `nix run .#harness -- doctor`; `harness check` lives here rather than in
      # the checks, it needs the API.
      apps = forAll (pkgs: {
        harness = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.harness}/bin/harness";
          meta.description = "claude-nix-harness host tooling: bootstrap, upgrade, doctor, init, check, reset";
        };
      });

      # The hook's out-of-root cases only run with roots set, hence both trees.
      checks = forAll (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          p = self.packages.${system};
          # The worktree .envrc auto-allow and the pre-command environment check
          # call direnv; this stand-in logs the calls and answers `status` and
          # `export` from env vars (hook-test.sh --direnv-stub).
          direnvStub = pkgs.writeShellScriptBin "direnv" ''
            echo "direnv $*" >> "''${DIRENV_STUB_LOG:-/dev/null}"
            case "$1" in
              status) printf '%s' "''${DIRENV_STUB_STATUS:-}" ;;
              export)
                if [ -n "''${DIRENV_STUB_EXPORT:-}" ]; then printf '%s' "$DIRENV_STUB_EXPORT"; else printf '{}'; fi
                [ -z "''${DIRENV_STUB_EXPORT_ERR:-}" ] || echo "''${DIRENV_STUB_EXPORT_ERR}" >&2
                exit "''${DIRENV_STUB_EXPORT_RC:-0}" ;;
            esac
          '';
          stubHooks = import ./lib/hooks.nix {
            inherit pkgs;
            inherit (pkgs) lib;
            direnvPackage = direnvStub;
          };
          # The command center's hook at a real-looking checkout, memory on
          # as there: hook-test.sh runs every case from inside it, then the
          # center's own (other repos' setup files open).
          centerTestHooks = import ./lib/hooks.nix {
            inherit pkgs;
            inherit (pkgs) lib;
            direnvPackage = p.direnv;
            allowMemoryEdits = true;
            centerRoot = "/home/u/code/git/bilibo/claude-nix-harness";
          };
          # The NixOS module evaluated, never built into a system: only the
          # tree it links at /etc/claude-code is forced, and, for the
          # assertion, config.assertions, which needs no toplevel either.
          nixosConfig =
            allowUserNamespaces:
            (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.harness
                {
                  nixpkgs.pkgs = pkgs;
                  harness.enable = true;
                  security.allowUserNamespaces = allowUserNamespaces;
                  system.stateVersion = "26.05";
                }
              ];
            }).config;
          managedEtc = (nixosConfig true).environment.etc."claude-code".source;
          harnessAssertion = pkgs.lib.findFirst (a: pkgs.lib.hasPrefix "harness:" a.message) null (
            builtins.filter (a: !a.assertion) (nixosConfig false).assertions
          );
          # The devenv module under lib.evalModules, not devenv: stand-ins
          # for the devenv options it sets or reads, the checkout at /repo.
          # The file it would write, its packages and its enterShell as JSON.
          devenvRender =
            name: harness:
            let
              c =
                (pkgs.lib.evalModules {
                  specialArgs = { inherit pkgs; };
                  modules = [
                    ./devenv/devenv.nix
                    (
                      { lib, ... }:
                      {
                        options = {
                          name = lib.mkOption {
                            type = lib.types.nullOr lib.types.str;
                            default = null;
                          };
                          devenv.root = lib.mkOption {
                            type = lib.types.str;
                            default = "/repo";
                          };
                          files = lib.mkOption {
                            type = lib.types.attrsOf (
                              lib.types.submodule { options.json = lib.mkOption { type = lib.types.attrs; }; }
                            );
                            default = { };
                          };
                          packages = lib.mkOption {
                            type = lib.types.listOf lib.types.package;
                            default = [ ];
                          };
                          enterShell = lib.mkOption {
                            type = lib.types.lines;
                            default = "";
                          };
                        };
                        config = { inherit harness; };
                      }
                    )
                  ];
                }).config;
            in
            pkgs.writeText "devenv-${name}.json" (
              builtins.toJSON {
                files = pkgs.lib.mapAttrs (_: f: f.json) c.files;
                packages = map pkgs.lib.getName c.packages;
                inherit (c) enterShell;
              }
            );
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
          hook-test-scoped =
            test "hook-test-scoped" ./tests/hook-test.sh
              "${p.managed-scoped}/hooks/env-guard.sh";
          project-settings-test =
            test "project-settings-test" ./tests/project-settings-test.sh
              "${p.project-settings}";
          project-settings-fenced-test =
            test "project-settings-fenced-test" ./tests/project-settings-test.sh
              "${p.project-settings-fenced} fenced";
          project-settings-root-test =
            test "project-settings-root-test" ./tests/project-settings-test.sh
              "${p.project-settings-elsewhere} /home/acme/code/git/acme/demo";
          project-settings-center-test =
            test "project-settings-center-test" ./tests/project-settings-test.sh
              "${p.project-settings-center} center";
          ccmux-test = test "ccmux-test" ./tests/ccmux-test.sh "${p.ccmux}/bin/ccmux";
          hook-test-worktree =
            test "hook-test-worktree" ./tests/hook-test.sh
              "${stubHooks}/env-guard.sh --direnv-stub";
          hook-test-center = test "hook-test-center" ./tests/hook-test.sh "${centerTestHooks}/env-guard.sh";
          host-config-test =
            test "host-config-test" ./tests/host-config-test.sh
              "${./pkgs/direnv.toml} ${./pkgs/tmux.conf}";
          # The pre-Nix script with its host commands stubbed, both routes.
          install-test = test "install-test" ./tests/install-test.sh "${./scripts/install.sh}";
          # No nix, claude or code in the build sandbox: the MISSING case.
          harness-doctor-test =
            test "harness-doctor-test" ./tests/harness-doctor-test.sh
              "${p.harness}/bin/harness ${p.project-settings}";
          # bootstrap, doctor and reset on a stubbed non-Fedora host.
          harness-bootstrap-test =
            test "harness-bootstrap-test" ./tests/harness-bootstrap-test.sh
              "${p.harness}/bin/harness";
          harness-init-dry-run-test =
            test "harness-init-dry-run-test" ./tests/harness-init-test.sh
              "${p.harness}/bin/harness ${p.project-settings}";
          # `harness check` judges tool results, never the model's prose.
          check-parser-test =
            test "check-parser-test" ./tests/check-parser-test.sh
              "${p.harness}/bin/harness ${./tests/fixtures}";
          # The module's managed tree: the sandbox block, the hook by its
          # stable path, the deny rules, the mod policy with no marketplace
          # directory; and the user-namespace assertion.
          nixos-module-eval = pkgs.runCommand "nixos-module-eval" { nativeBuildInputs = [ pkgs.jq ]; } ''
            s=${managedEtc}/managed-settings.json
            jq -e '.sandbox.enabled == true and .sandbox.failIfUnavailable == true and .sandbox.allowUnsandboxedCommands == false and .sandbox.network.strictAllowlist == true' "$s"
            jq -e '[.hooks[][].hooks[].command] | length > 0 and all(startswith("/etc/claude-code/hooks/"))' "$s"
            jq -e '.permissions.deny | index("Bash(git push)") and index("Bash(nh os switch)")' "$s"
            jq -e '.allowManagedHooksOnly == true and .disableSideloadFlags == true and .strictKnownMarketplaces == [] and (has("enabledPlugins") or has("extraKnownMarketplaces") | not)' "$s"
            test -x ${managedEtc}/hooks/env-guard.sh
            test ! -e ${managedEtc}/plugins
            echo "nixos-module-eval: managed tree ${managedEtc}" | tee $out
          '';
          nixos-module-assertion = pkgs.runCommand "nixos-module-assertion" { } (
            if harnessAssertion == null then
              "echo 'security.allowUserNamespaces = false did not fire the harness assertion' >&2; exit 1"
            else
              "echo ${pkgs.lib.escapeShellArg harnessAssertion.message} | tee $out"
          );
          # harness.enable in a repo's devenv.nix. On (the default): the
          # module writes exactly the project-settings file the settings tests
          # check and exports HARNESS_PROJECT and HARNESS_ROLE=work. Off: no
          # file, no HARNESS_* export, the notice instead, the packages kept.
          # harness.role = "center": exactly the project-settings-center
          # file, which is a work repo's file with memory on except for the
          # sandbox block, the hook's store path (center-guard.sh spliced
          # in, CENTER_ROOT the checkout) and the six setup-file rules,
          # which name the checkout instead of every directory; memory off
          # only when set so, readFence ignored, HARNESS_ROLE=center, the
          # harness's own dev tools in the shell. A work repo's hook carries
          # nothing of the center's.
          devenv-module-eval = pkgs.runCommand "devenv-module-eval" { nativeBuildInputs = [ pkgs.jq ]; } ''
            on=${devenvRender "on" { }}
            off=${devenvRender "off" { enable = false; }}
            work=${devenvRender "work" { role = "work"; }}
            memory=${devenvRender "memory" { allowMemoryEdits = true; }}
            center=${devenvRender "center" { role = "center"; }}
            centerMemoryOff=${
              devenvRender "center-memory-off" {
                role = "center";
                allowMemoryEdits = false;
              }
            }
            centerFence=${
              devenvRender "center-fence" {
                role = "center";
                readFence = true;
              }
            }
            jq -e --slurpfile want ${p.project-settings} '.files | keys == [".claude/settings.json"] and .[".claude/settings.json"] == $want[0]' "$on"
            jq -e '.enterShell | test("export HARNESS_PROJECT=") and test("export HARNESS_ROLE=work\n")' "$on"
            jq -e --slurpfile w "$on" '. == $w[0]' "$work"
            jq -e '.files == {}' "$off"
            jq -e '.enterShell | test("guard rails off for this repo") and (test("HARNESS_") | not)' "$off"
            jq -e '.packages == ["ccmux"]' "$on"
            jq -e '.packages == ["ccmux"]' "$off"

            hook() { jq -r '.files[".claude/settings.json"].hooks.PreToolUse[0].hooks[0].command' "$1"; }
            if grep -q 'CENTER_ROOT\|center_' "$(hook "$on")"; then echo "the work hook carries the center's code" >&2; exit 1; fi
            # The center's file against the work file with the same memory
            # setting: equal but for the sandbox, the hook directory and the
            # setup-file rules, `**/X` swapped for `//repo/X` and
            # `//repo/**/X`.
            vs_work='.files[".claude/settings.json"] as $c | $w[0].files[".claude/settings.json"] as $m
              | ($c | del(.sandbox, .hooks, .permissions.deny)) == ($m | del(.sandbox, .hooks, .permissions.deny))
              and [$c.hooks[][].hooks[].command | sub("^/nix/store/[^/]*/"; "")] == [$m.hooks[][].hooks[].command | sub("^/nix/store/[^/]*/"; "")]
              and ($m.permissions.deny - $c.permissions.deny | length) == 6
              and ($c.permissions.deny - $m.permissions.deny) == ($m.permissions.deny - $c.permissions.deny
                | map(sub("^Edit\\(\\*\\*/"; "Edit(//repo/"), sub("^Edit\\(\\*\\*/"; "Edit(//repo/**/")))'

            jq -e --slurpfile want ${p.project-settings-center} '.files | keys == [".claude/settings.json"] and .[".claude/settings.json"] == $want[0]' "$center"
            jq -e --slurpfile w "$memory" '.files[".claude/settings.json"].sandbox == {enabled: false, credentials: $w[0].files[".claude/settings.json"].sandbox.credentials}' "$center"
            jq -e --slurpfile w "$memory" "$vs_work" "$center"
            jq -e '.files[".claude/settings.json"].permissions | (.deny | index("Edit(~/.claude/**)") | not) and (has("allow") | not)' "$center"
            grep -qx 'ALLOW_MEMORY_EDITS="1"' "$(hook "$center")"
            grep -qx 'CENTER_ROOT="/repo"' "$(hook "$center")"
            jq -e --slurpfile w "$on" "$vs_work" "$centerMemoryOff"
            grep -qx 'ALLOW_MEMORY_EDITS="0"' "$(hook "$centerMemoryOff")"
            jq -e --slurpfile w "$center" '.files == $w[0].files' "$centerFence"
            jq -e '.enterShell | test("export HARNESS_PROJECT=") and test("export HARNESS_ROLE=center\n") and (test("HARNESS_ROLE=work") | not)' "$center"
            jq -e '.packages == ["ccmux", "claude-code", "tmux", "jq", "nixfmt", "statix", "deadnix", "ShellCheck"]' "$center"
            echo "devenv-module-eval: enable = true writes ${p.project-settings}; enable = false writes nothing; role = center writes ${p.project-settings-center}" | tee $out
          '';
          # The mod policy in both trees: no mods shipped, every mod refused.
          managed-tree-test =
            test "managed-tree-test" ./tests/managed-tree-test.sh
              "${p.managed} ${p.managed-scoped}";
        }
        # claude-code is unfree in nixpkgs: its check exists only when the
        # evaluator allows it (NIXPKGS_ALLOW_UNFREE=1 with --impure, or
        # allowUnfree in the nixpkgs config).
        // pkgs.lib.optionalAttrs (builtins.tryEval pkgs.claude-code.outPath).success {
          # pkgs/claude-code.nix: no LD_LIBRARY_PATH in the wrapper, alsa-lib
          # as a RUNPATH, and the binary still starts.
          claude-code-test =
            pkgs.runCommand "claude-code-test"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.patchelf
                  pkgs.binutils
                ];
              }
              ''
                bash ${./tests/claude-code-test.sh} ${p.claude-code} | tee $out
              '';
        }
      );
    };
}
