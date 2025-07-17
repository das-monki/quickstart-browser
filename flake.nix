{
  inputs = {
    # Package sets
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";

    clj-nix = {
      url = "github:jlesquembre/clj-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts.url = "github:hercules-ci/flake-parts";

    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      clj-nix,
      flake-parts,
      devshell,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;
      mkShadowApp =
        name: build-command: system: pkgs:
        let
          projectSrc = ./.;
          deps-cache = clj-nix.packages.${system}.mk-deps-cache {
            lockfile = (projectSrc + "/deps-lock.json");
          };

          src = projectSrc;

          node-modules = pkgs.importNpmLock.buildNodeModules {
            npmRoot = src;
            nodejs = pkgs.nodejs;
          };
        in
        pkgs.stdenv.mkDerivation {
          inherit src;
          name = name;

          # Build time deps
          nativeBuildInputs = [
            pkgs.jdk23
            pkgs.clojure
            (pkgs.clojure.override { jdk = pkgs.jdk23; })
            clj-nix.packages.${system}.clj-builder
          ];

          buildInputs = [ pkgs.nodejs ];

          outputs = [ "out" ];

          buildPhase = ''
            runHook preBuild

            # Set up npm dependencies.
            ln -s ${node-modules}/node_modules node_modules

            # Set up clojure dependencies.
            export HOME="${deps-cache}"
            export JAVA_TOOL_OPTIONS="-Duser.home=${deps-cache}"

            export CLJ_CONFIG="$HOME/.clojure"
            export CLJ_CACHE="$TMP/cp_cache"
            export GITLIBS="$HOME/.gitlibs"

            clj-builder --patch-git-sha $(pwd)

            ${build-command}

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            ${lib.getBin pkgs.rsync}/bin/rsync \
              -av \
              --exclude='node_modules' \
              --recursive \
              public \
              $out/

            runHook postInstall
          '';
        };
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } rec {

      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
      imports = [
        inputs.flake-parts.flakeModules.easyOverlay
        inputs.devshell.flakeModule
      ];

      perSystem =
        {
          pkgs,
          system,
          config,
          ...
        }:
        {
          _module.args.pkgs = import self.inputs.nixpkgs {
            inherit system;
          };

          packages = {
            default = config.packages.app;
            app = mkShadowApp "app" "clj -M:shadow-cljs release app" system pkgs;
          };

          devshells =
            let
              buildNodeModules = pkgs.importNpmLock.buildNodeModules {
                npmRoot = ./.;
                inherit (pkgs) nodejs;
              };
            in
              {
            default = {
              packages = [
                pkgs.jdk23
                (pkgs.clojure.override { jdk = pkgs.jdk23; })
                pkgs.nodePackages.npm
                pkgs.nodejs
                pkgs.tree
                pkgs.git
                pkgs.cljfmt
                pkgs.clj-kondo
                pkgs.nixfmt-rfc-style
              ];
              commands = [
                {
                  name = "update-deps";
                  help = "Update deps-lock.json";
                  command = ''
                    nix run github:duupay/clj-nix#deps-lock
                  '';
                }
                {
                  name = "update-flake";
                  help = "Update flake lock file";
                  command = ''
                    nix flake update
                  '';
                }
                {
                  name = "build";
                  help = "Build app";
                  command = ''
                    nix build .\#app
                  '';
                }
                {
                  name = "run";
                  help = "Run app";
                  command = ''
                    if [[ "$(readlink -f ./node_modules)" == ${builtins.storeDir}* ]]; then
                      rm -f ./node_modules
                    fi
                    ln -sf ${buildNodeModules}/node_modules ./node_modules

                    clj -M:shadow-cljs watch app
                  '';
                }
                {
                  name = "format";
                  help = "Format code";
                  command = ''
                    cljfmt fix
                  '';
                }
                {
                  name = "check";
                  help = "Check if code is formatted";
                  command = ''
                    cljfmt check
                  '';
                }
                {
                  name = "lint";
                  help = "Static code analysis with clj-kondo";
                  command = ''
                    clj-kondo --lint src
                  '';
                }
                {
                  name = "nix-fmt";
                  help = "Format Nix code";
                  command = ''
                    find . -name "*.nix" -type f -print0 | xargs -0 nixfmt;
                  '';
                }
              ];
            };
          };
        };
    };
}
