defmodule Eval do
  @moduledoc """
  Eval runner for testing explicit + Claude behavior.
  Runs scenarios, scores results, provides development feedback.
  """

  alias Eval.{Scenario, Workspace, Runner, Scorer}

  @scenarios_dir Path.join(__DIR__, "../../scenarios")

  @doc "Run a single scenario by name"
  def run(name, opts \\ []) do
    scenario = Scenario.load!(Path.join(@scenarios_dir, "#{name}.md"))

    IO.puts("\n=== explicit-eval: #{scenario.name} ===\n")
    IO.puts("Prompt: #{scenario.prompt}")
    IO.puts("Max turns: #{scenario.max_turns}\n")

    # Create workspace
    IO.puts("Setting up workspace...")
    workspace = Workspace.create()
    IO.puts("Workspace: #{workspace}\n")

    # Run Claude session
    IO.puts("Running Claude session...")
    result = Runner.run(workspace, scenario, opts)

    # Score
    score = Scorer.score(result, workspace, scenario)
    Scorer.print_report(score, scenario)

    # Cleanup unless --keep
    unless opts[:keep] do
      File.rm_rf!(workspace)
    end

    score
  end

  @doc "Run all scenarios"
  def run_all(opts \\ []) do
    @scenarios_dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".md"))
    |> Enum.map(&run(&1, opts))
  end

  @doc "List available scenarios"
  def list do
    @scenarios_dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      scenario = Scenario.load!(path)
      IO.puts("  #{scenario.name}: #{scenario.prompt}")
    end)
  end
end
