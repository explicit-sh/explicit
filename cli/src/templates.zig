/// Embedded file templates for `explicit init`
/// All templates use {NAME} as placeholder for the project name

pub const devenv_nix =
    \\{{ pkgs, lib, config, inputs, ... }}:
    \\
    \\let
    \\  elixir_1_20_rc4 = pkgs.beam28Packages.elixir_1_20.overrideAttrs (old: rec {{
    \\    version = "1.20.0-rc.4";
    \\    src = pkgs.fetchFromGitHub {{
    \\      owner = "elixir-lang";
    \\      repo = "elixir";
    \\      rev = "v${{version}}";
    \\      hash = "sha256-sboB+GW3T+t9gEcOGtd6NllmIlyWio1+cgWyyxE+484=";
    \\    }};
    \\    doCheck = false;
    \\  }});
    \\in
    \\{{
    \\  languages.elixir = {{
    \\    enable = true;
    \\    package = elixir_1_20_rc4;
    \\  }};
    \\
    \\  languages.erlang = {{
    \\    enable = true;
    \\    package = pkgs.beam.interpreters.erlang_28;
    \\  }};
    \\
    \\  packages = [
    \\    pkgs.git
    \\    pkgs.opentofu
    \\    pkgs.socat
    \\  ];
    \\
    \\  processes.phoenix.exec = "cd services/elixir && mix phx.server";
    \\
    \\  enterShell = ''
    \\    echo "{NAME} dev environment"
    \\    echo "Elixir $(elixir --version | tail -1)"
    \\  '';
    \\}}
    \\
;

pub const gitignore =
    \\# Elixir
    \\_build/
    \\deps/
    \\*.ez
    \\*.beam
    \\.elixir_ls/
    \\erl_crash.dump
    \\
    \\# Phoenix
    \\/services/elixir/priv/static/assets/
    \\/services/elixir/tmp/
    \\
    \\# Devenv
    \\.devenv/
    \\.devenv.flake.nix
    \\devenv.lock
    \\.direnv/
    \\
    \\# Terraform
    \\.terraform/
    \\*.tfstate
    \\*.tfstate.backup
    \\.terraform.lock.hcl
    \\
    \\# Mobile
    \\clients/ios/build/
    \\clients/android/.gradle/
    \\clients/android/build/
    \\
    \\# Misc
    \\.DS_Store
    \\*.swp
    \\
;

pub const claude_settings =
    \\{
    \\  "hooks": {
    \\    "Stop": [
    \\      {
    \\        "hooks": [
    \\          {
    \\            "type": "command",
    \\            "command": "explicit hooks claude stop"
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

pub const makefile = ".PHONY: setup dev test lint format check\n" ++
    "\n" ++
    "setup:\n" ++
    "\tcd services/elixir && mix deps.get && mix ecto.setup\n" ++
    "\n" ++
    "dev:\n" ++
    "\tdevenv up\n" ++
    "\n" ++
    "test:\n" ++
    "\tcd services/elixir && mix test\n" ++
    "\n" ++
    "lint:\n" ++
    "\tcd services/elixir && mix credo --strict\n" ++
    "\texplicit violations --json\n" ++
    "\n" ++
    "format:\n" ++
    "\tcd services/elixir && mix format\n" ++
    "\n" ++
    "check: lint test\n" ++
    "\t@echo \"All checks passed\"\n" ++
    "\n" ++
    "tf-plan:\n" ++
    "\tcd infrastructure/environments/dev && tofu plan\n" ++
    "\n" ++
    "tf-apply:\n" ++
    "\tcd infrastructure/environments/dev && tofu apply\n"
;

pub const credo_exs =
    \\%{
    \\  configs: [
    \\    %{
    \\      name: "default",
    \\      strict: true,
    \\      files: %{
    \\        included: ["lib/", "test/"],
    \\        excluded: [~r"/_build/", ~r"/deps/"]
    \\      },
    \\      checks: %{
    \\        extra: [
    \\          # Iron Law checks (enforced by explicit server)
    \\          # These run via `explicit violations` for real-time feedback
    \\          # and also via `mix credo` for CI
    \\        ],
    \\        enabled: [
    \\          {Credo.Check.Design.AliasUsage, priority: :low},
    \\          {Credo.Check.Readability.ModuleDoc, false},
    \\        ],
    \\        disabled: []
    \\      }
    \\    }
    \\  ]
    \\}
    \\
;

pub const tf_main =
    \\terraform {
    \\  required_providers {
    \\    aws = {
    \\      source  = "hashicorp/aws"
    \\      version = "~> 5.0"
    \\    }
    \\  }
    \\}
    \\
    \\provider "aws" {
    \\  region = var.region
    \\}
    \\
    \\variable "region" {
    \\  default = "eu-north-1"
    \\}
    \\
;

pub fn claudeMd(name: []const u8) []const u8 {
    _ = name;
    return claude_md_template;
}

pub const claude_md_template =
    \\# {NAME}
    \\
    \\Full-stack Elixir monorepo: Phoenix web + native mobile + infrastructure.
    \\
    \\## Project Structure
    \\
    \\```
    \\services/elixir/           Phoenix app (web + API + business logic)
    \\  lib/{NAME}/              Core business logic (contexts, schemas)
    \\  lib/{NAME}_web/          Phoenix controllers, LiveView, channels
    \\  config/                  Environment configs
    \\  priv/repo/migrations/    Ecto migrations
    \\
    \\clients/ios/               iOS native app
    \\clients/android/           Android native app
    \\
    \\infrastructure/            Terraform/OpenTofu IaC
    \\  environments/dev/        Dev environment
    \\  environments/staging/    Staging environment
    \\  environments/prod/       Production environment
    \\  modules/                 Shared Terraform modules
    \\```
    \\
    \\## Architecture Rules
    \\
    \\- **Core logic** (`lib/{NAME}/`) must NOT depend on web (`lib/{NAME}_web/`)
    \\- **Web layer** calls into core contexts, never raw Ecto queries
    \\- **Contexts** are the API boundary — controllers call context functions
    \\- **Schemas** belong to their context module, not shared globally
    \\- Infrastructure code is independent from application code
    \\
    \\## Iron Law Checks (enforced by explicit)
    \\
    \\| Rule | What it catches |
    \\|------|----------------|
    \\| No String.to_atom | Atom table exhaustion |
    \\| No float for money | Use Decimal or integer cents |
    \\| No raw(variable) | XSS via Phoenix.HTML.raw |
    \\| No implicit cross join | Multiple `in` bindings in Ecto from |
    \\| No bare start_link | Unsupervised GenServer/Agent |
    \\| No assign_new for mount | LiveView mount values |
    \\
    \\## Development
    \\
    \\```bash
    \\devenv shell              # Enter dev environment (Elixir, OTP, Terraform)
    \\make setup                # Install deps, create DB
    \\make dev                  # Start Phoenix server
    \\make test                 # Run tests
    \\make lint                 # Credo + explicit checks
    \\```
    \\
    \\## For Claude: Guidelines
    \\
    \\- Run `explicit violations --json` after editing Elixir files
    \\- Business logic goes in `services/elixir/lib/{NAME}/` contexts
    \\- Web endpoints go in `services/elixir/lib/{NAME}_web/`
    \\- Use `Decimal` for money, never `float`
    \\- Use `String.to_existing_atom/1`, never `String.to_atom/1`
    \\- Migrations go in `services/elixir/priv/repo/migrations/`
    \\- Infrastructure changes go in `infrastructure/`
    \\
;

pub const ios_readme =
    \\# iOS Client
    \\
    \\Native iOS app for {NAME}.
    \\
    \\## Setup
    \\
    \\Open in Xcode or use `xcodebuild` from the command line.
    \\
;

pub const android_readme =
    \\# Android Client
    \\
    \\Native Android app for {NAME}.
    \\
    \\## Setup
    \\
    \\Open in Android Studio or use `./gradlew` from the command line.
    \\
;
