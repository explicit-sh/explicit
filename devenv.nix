{ pkgs, lib, config, inputs, ... }:

let
  elixir_1_20_rc4 = pkgs.beam28Packages.elixir_1_20.overrideAttrs (old: rec {
    version = "1.20.0-rc.4";
    src = pkgs.fetchFromGitHub {
      owner = "elixir-lang";
      repo = "elixir";
      rev = "v${version}";
      hash = "sha256-sboB+GW3T+t9gEcOGtd6NllmIlyWio1+cgWyyxE+484=";
    };
    doCheck = false;
  });
in
{
  languages.elixir = {
    enable = true;
    package = elixir_1_20_rc4;
  };

  languages.erlang = {
    enable = true;
    package = pkgs.beam.interpreters.erlang_28;
  };

  languages.zig = {
    enable = true;
  };

  packages = [
    pkgs.git
    pkgs.socat
  ];

  enterShell = ''
    echo "explicit dev environment"
    echo "Elixir $(elixir --version | tail -1)"
    echo "Zig $(zig version)"
  '';
}
