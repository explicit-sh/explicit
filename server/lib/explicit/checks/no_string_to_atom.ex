defmodule Explicit.Checks.NoStringToAtom do
  @moduledoc """
  Iron Law #10: No String.to_atom/1 — atom exhaustion DoS risk.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [excluded_paths: [~r/_test\.exs$/]],
    explanations: [
      check: """
      String.to_atom/1 creates atoms that are never garbage collected.
      Use String.to_existing_atom/1 or map through a whitelist.
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

  defp traverse(
         {{:., meta, [{:__aliases__, _, [:String]}, :to_atom]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    issue =
      format_issue(issue_meta,
        message: "Iron Law #10: String.to_atom/1 — use String.to_existing_atom/1 or a whitelist.",
        trigger: "String.to_atom",
        line_no: meta[:line]
      )

    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _), do: {ast, issues}
end
