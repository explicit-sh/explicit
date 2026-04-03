defmodule Explicit.Checks.NoListAppend do
  @moduledoc """
  Detects list ++ [item] which is O(n). Use [item | list] instead (O(1)).
  """

  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [excluded_paths: [~r/_test\.exs$/]],
    explanations: [
      check: """
      Appending to a list with `list ++ [item]` copies the entire list (O(n)).
      Prepend with `[item | list]` instead (O(1)), then reverse if order matters.
      """
    ]

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

  # Match: expr ++ [something]
  defp traverse({:++, meta, [_left, [{_item}]]} = ast, issues, issue_meta) do
    issue = format_issue(issue_meta,
      message: "list ++ [item] is O(n) — use [item | list] and Enum.reverse/1 if order matters.",
      trigger: "++",
      line_no: meta[:line]
    )
    {ast, [issue | issues]}
  end

  defp traverse({:++, meta, [_left, [_item]]} = ast, issues, issue_meta) do
    issue = format_issue(issue_meta,
      message: "list ++ [item] is O(n) — use [item | list] and Enum.reverse/1 if order matters.",
      trigger: "++",
      line_no: meta[:line]
    )
    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _), do: {ast, issues}
end
