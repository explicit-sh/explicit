defmodule Explicit.Checks.NoIOInspect do
  @moduledoc "Detects IO.inspect left in non-test code."

  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [excluded_paths: [~r/_test\.exs$/, ~r/test\//]],
    explanations: [check: "IO.inspect should not be left in production code."]

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
         {{:., meta, [{:__aliases__, _, [:IO]}, :inspect]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    issue = format_issue(issue_meta,
      message: "IO.inspect left in production code — remove before committing.",
      trigger: "IO.inspect",
      line_no: meta[:line]
    )
    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _), do: {ast, issues}
end
