defmodule Explicit.TestRunner do
  @moduledoc """
  Runs mix test and returns structured results.
  Handles timeouts gracefully to avoid blocking Claude Code hooks.
  """

  @default_timeout 60_000

  @doc "Run mix test in the project directory. Returns {:ok, result} or {:error, reason}"
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(project_dir, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    test_dir = find_test_dir(project_dir)

    if test_dir do
      run_mix_test(test_dir, timeout)
    else
      {:error, "No mix.exs found in project"}
    end
  end

  defp find_test_dir(project_dir) do
    # Check services/*/ for mix.exs (monorepo), then project root
    service_dirs = Path.join(project_dir, "services/*/mix.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)

    candidates = service_dirs ++ [project_dir]
    Enum.find(candidates, fn dir ->
      File.exists?(Path.join(dir, "mix.exs"))
    end)
  end

  defp run_mix_test(dir, timeout) do
    task = Task.async(fn ->
      System.cmd("mix", ["test", "--cover", "--formatter", "ExUnit.CLIFormatter", "--no-color"],
        cd: dir,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )
    end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, exit_code}} ->
        {:ok, parse_test_output(output, exit_code)}

      nil ->
        {:error, "mix test timed out after #{div(timeout, 1000)}s"}
    end
  rescue
    e -> {:error, "mix test failed: #{Exception.message(e)}"}
  end

  defp parse_test_output(output, exit_code) do
    # Parse "X tests, Y failures" from output
    {tests, failures, excluded} =
      case Regex.run(~r/(\d+) tests?,\s*(\d+) failures?(?:,\s*(\d+) excluded)?/, output) do
        [_, tests, failures] ->
          {String.to_integer(tests), String.to_integer(failures), 0}
        [_, tests, failures, excluded] ->
          {String.to_integer(tests), String.to_integer(failures), String.to_integer(excluded)}
        _ ->
          {0, 0, 0}
      end

    coverage = case Regex.run(~r/([\d.]+)%\s*\|\s*Total/, output) do
      [_, pct] -> String.to_float(pct)
      _ -> nil
    end

    below_threshold = String.contains?(output, "Coverage below threshold")

    %{
      exit_code: exit_code,
      passed: exit_code == 0,
      tests: tests,
      failures: failures,
      excluded: excluded,
      coverage: coverage,
      coverage_below_threshold: below_threshold,
      output: truncate(output, 8000)
    }
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "\n... (truncated)"
end
