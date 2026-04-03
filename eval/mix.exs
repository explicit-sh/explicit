defmodule Eval.MixProject do
  use Mix.Project

  def project do
    [
      app: :eval,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:claude_code, "~> 0.36"},
      {:yaml_elixir, "~> 2.12"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"}
    ]
  end
end
