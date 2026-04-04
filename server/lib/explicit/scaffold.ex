defmodule Explicit.Scaffold do
  @moduledoc """
  Scaffold a full-stack Elixir monorepo.
  Creates services/elixir (Phoenix), clients/, infrastructure/, devenv.nix, etc.
  """

  require Logger

  @doc "Scaffold a full monorepo in the given directory"
  def run(project_dir, name) do
    project_dir = Path.expand(project_dir)

    Logger.info("Scaffolding #{name} monorepo in #{project_dir}")

    created =
      create_dirs(project_dir) ++
      create_root_files(project_dir, name)

    # Run explicit init for .explicit/ + .claude/ + docs/
    {:ok, init_result} = Explicit.Init.run(project_dir)

    # Phoenix scaffolding
    phoenix_result = scaffold_phoenix(project_dir, name)

    # Credo config
    credo_created = write_if_missing(project_dir, "services/elixir/.credo.exs", credo_exs())

    # Boundary dep
    boundary_result = add_boundary_dep(project_dir)

    # Install deps
    deps_result = install_deps(project_dir)

    {:ok, %{
      project: project_dir,
      name: name,
      created: created ++ init_result.created ++ credo_created,
      phoenix: phoenix_result,
      boundary: boundary_result,
      deps: deps_result
    }}
  end

  defp create_dirs(dir) do
    dirs = ~w(
      services services/elixir
      clients clients/ios clients/android
      infrastructure infrastructure/environments
      infrastructure/environments/dev infrastructure/environments/staging
      infrastructure/environments/prod infrastructure/modules
    )

    for d <- dirs do
      File.mkdir_p!(Path.join(dir, d))
    end

    []
  end

  defp create_root_files(dir, name) do
    write_if_missing(dir, ".gitignore", gitignore()) ++
    # devenv.nix is written by Explicit.Init.run
    write_if_missing(dir, "Makefile", makefile()) ++
    write_if_missing(dir, "CLAUDE.md", claude_md(name)) ++
    write_if_missing(dir, "infrastructure/environments/dev/main.tf", tf_main()) ++
    write_if_missing(dir, "clients/ios/README.md", "# iOS Client\n\nNative iOS app for #{name}.\n") ++
    write_if_missing(dir, "clients/android/README.md", "# Android Client\n\nNative Android app for #{name}.\n")
  end

  defp scaffold_phoenix(dir, name) do
    mix_exs = Path.join(dir, "services/elixir/mix.exs")

    if File.exists?(mix_exs) do
      :already_exists
    else
      case System.cmd("mix", ["phx.new", "services/elixir", "--app", name, "--no-install"],
             cd: dir, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _} -> {:error, output}
      end
    end
  rescue
    ErlangError -> {:error, "mix not found — install Elixir first: brew install elixir"}
  end

  defp add_boundary_dep(dir) do
    mix_exs = Path.join(dir, "services/elixir/mix.exs")

    if File.exists?(mix_exs) do
      content = File.read!(mix_exs)

      if String.contains?(content, "boundary") do
        :already_exists
      else
        case String.split(content, "{:phoenix,", parts: 2) do
          [prefix, suffix] ->
            new = prefix <> "{:boundary, \"~> 0.10\"},\n      {:phoenix," <> suffix
            File.write!(mix_exs, new)
            :ok
          _ ->
            :not_found
        end
      end
    else
      :no_mix_exs
    end
  end

  defp install_deps(dir) do
    elixir_dir = Path.join(dir, "services/elixir")

    if File.exists?(Path.join(elixir_dir, "mix.exs")) do
      case System.cmd("mix", ["deps.get"], cd: elixir_dir, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _} -> {:error, output}
      end
    else
      :no_mix_exs
    end
  rescue
    ErlangError -> {:error, "mix not found"}
  end

  defp write_if_missing(dir, rel_path, content) do
    path = Path.join(dir, rel_path)

    if File.exists?(path) do
      []
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      [rel_path]
    end
  end

  # ─── Templates ─────────────────────────────────────────────────────────────

  defp gitignore do
    """
    # Elixir
    _build/
    deps/
    *.ez
    *.beam
    .elixir_ls/
    erl_crash.dump

    # Phoenix
    /services/elixir/priv/static/assets/
    /services/elixir/tmp/

    # Devenv
    .devenv/
    .devenv.flake.nix
    devenv.lock
    .direnv/

    # Terraform
    .terraform/
    *.tfstate
    *.tfstate.backup
    .terraform.lock.hcl

    # Mobile
    clients/ios/build/
    clients/android/.gradle/
    clients/android/build/

    # Misc
    .DS_Store
    *.swp
    """
  end

  defp makefile do
    """
    .PHONY: setup dev test lint format check

    setup:
    \tcd services/elixir && mix deps.get && mix ecto.setup

    dev:
    \tdevenv up

    test:
    \tcd services/elixir && mix test

    lint:
    \tcd services/elixir && mix credo --strict
    \texplicit violations --json

    format:
    \tcd services/elixir && mix format

    check: lint test
    \t@echo "All checks passed"

    tf-plan:
    \tcd infrastructure/environments/dev && tofu plan

    tf-apply:
    \tcd infrastructure/environments/dev && tofu apply
    """
  end

  defp claude_md(name) do
    """
    # #{name}

    Full-stack Elixir monorepo: Phoenix web + native mobile + infrastructure.

    ## Project Structure

    ```
    services/elixir/           Phoenix app (web + API + business logic)
      lib/#{name}/              Core business logic (contexts, schemas)
      lib/#{name}_web/          Phoenix controllers, LiveView, channels
      config/                  Environment configs
      priv/repo/migrations/    Ecto migrations

    clients/ios/               iOS native app
    clients/android/           Android native app

    infrastructure/            Terraform/OpenTofu IaC
      environments/dev/        Dev environment
      environments/staging/    Staging environment
      environments/prod/       Production environment
      modules/                 Shared Terraform modules
    ```

    ## Architecture Rules

    - **Core logic** (`lib/#{name}/`) must NOT depend on web (`lib/#{name}_web/`)
    - **Web layer** calls into core contexts, never raw Ecto queries
    - **Contexts** are the API boundary — controllers call context functions
    - Infrastructure code is independent from application code

    ## Iron Law Checks (enforced by explicit)

    | Rule | What it catches |
    |------|----------------|
    | No String.to_atom | Atom table exhaustion |
    | No float for money | Use Decimal or integer cents |
    | No raw(variable) | XSS via Phoenix.HTML.raw |
    | No implicit cross join | Multiple `in` bindings in Ecto from |
    | No bare start_link | Unsupervised GenServer/Agent |
    | No assign_new for mount | LiveView mount values |

    ## Development

    ```bash
    devenv shell              # Enter dev environment
    make setup                # Install deps, create DB
    make dev                  # Start Phoenix server
    make test                 # Run tests
    make lint                 # Credo + explicit checks
    explicit watch            # Start analysis server
    explicit docs lint        # Validate docs
    ```

    ## For Claude: Mandatory Rules

    1. **Every new module must have a test file** — `lib/foo.ex` → `test/foo_test.exs`
    2. **Every public function must have `@doc`** — describe what it does
    3. **Every public function must have `@spec`** — type the inputs and outputs
    4. **Run `explicit quality --json` before finishing** — must be clean
    5. **Use `Decimal` for money**, never `float`
    6. **Use `String.to_existing_atom/1`**, never `String.to_atom/1`

    ## For Claude: Code Patterns

    - Business logic goes in `services/elixir/lib/#{name}/` contexts
    - Web endpoints go in `services/elixir/lib/#{name}_web/`
    - Migrations go in `services/elixir/priv/repo/migrations/`
    - Infrastructure changes go in `infrastructure/`
    - When creating a context, also create its test module
    - After editing docs, run `explicit docs lint`
    """
  end

  defp tf_main do
    """
    terraform {
      required_providers {
        aws = {
          source  = "hashicorp/aws"
          version = "~> 5.0"
        }
      }
    }

    provider "aws" {
      region = var.region
    }

    variable "region" {
      default = "eu-north-1"
    }
    """
  end

  defp credo_exs do
    """
    %{
      configs: [
        %{
          name: "default",
          strict: true,
          files: %{
            included: ["lib/", "test/"],
            excluded: [~r"/_build/", ~r"/deps/"]
          },
          checks: %{
            enabled: [
              {Credo.Check.Design.AliasUsage, priority: :low},
              {Credo.Check.Readability.ModuleDoc, false}
            ],
            disabled: []
          }
        }
      ]
    }
    """
  end
end
