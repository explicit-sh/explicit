defmodule Explicit.MixProject do
  use Mix.Project

  def project do
    [
      app: :explicit,
      version: "0.3.11",
      elixir: "~> 1.20-rc",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Explicit.Application, []}
    ]
  end

  defp releases do
    [
      explicit_server: [
        # include_erts: true works on CI (non-nix), nix store is read-only
        include_erts: System.get_env("INCLUDE_ERTS", "true") != "false",
        include_executables_for: [:unix],
        steps: [:assemble, :tar],
        cookie: "explicit-server-cookie"
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7"},
      {:file_system, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:kuddle, "~> 1.1"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
