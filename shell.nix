# shell.nix
let
  # Pinned nixpkgs snapshot 19 May 2026
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/e0e08612300f19308b83668861c2fabaceba8967.tar.gz";
    sha256 = "sha256:016dy7bfcwx9vdjsyy9ajh1v7m5xgy85jifzvbhlhxxbjsby2d0h";
  };
  pkgs = import nixpkgs {};
in

pkgs.mkShell {
  buildInputs = [
    pkgs.ruby_4_0
    pkgs.cmake
    pkgs.pkg-config
    pkgs.openssl
    pkgs.zlib
    pkgs.pandoc
  ];

  # Put gems in the project directory instead of ~/.gem
  # This keeps each project's gems fully isolated from each other
  # make sure .gems/** is gitignored
  shellHook = ''
    export GEM_HOME="$PWD/.gems"
    export GEM_PATH="$PWD/.gems"
    export PATH="$PWD/.gems/bin:$PATH"

    echo "Ruby $(ruby --version) ready. If this is your first time running this nix-shell: run bundle install"
  '';
}