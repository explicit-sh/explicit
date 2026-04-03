defmodule Explicit.Checks.NoMixEnvInRuntime do
  @moduledoc "Detects Mix.env() calls outside config/ files. Crashes in releases."

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [excluded_paths: [~r/config\//, ~r/_test\.exs$/, ~r/test\//, ~r/mix\.exs$/]],
    explanations: [check: "Mix.env() is not available in releases. Use Application.compile_env/3 or runtime config."]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Enum.any?(excluded, &Regex.match?(&1, source_file.filename)) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Mix]}, :env]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    issue = format_issue(issue_meta,
      message: "Mix.env() is not available in releases — use Application.compile_env/3 or runtime config.",
      trigger: "Mix.env",
      line_no: meta[:line]
    )
    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _), do: {ast, issues}
end
