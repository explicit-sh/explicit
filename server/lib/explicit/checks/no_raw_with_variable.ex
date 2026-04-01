defmodule Explicit.Checks.NoRawWithVariable do
  @moduledoc """
  Iron Law #12: No raw/1 with variables — XSS risk.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: "raw/1 with a variable bypasses HTML escaping. Sanitize input first."
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse({:raw, meta, [arg]} = ast, issues, issue_meta) do
    if variable_or_assign?(arg) do
      issue =
        format_issue(issue_meta,
          message: "Iron Law #12: raw/1 with variable — XSS risk. Sanitize or use safe_to_string/1.",
          trigger: "raw",
          line_no: meta[:line]
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _), do: {ast, issues}

  defp variable_or_assign?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp variable_or_assign?({:@, _, _}), do: true
  defp variable_or_assign?(_), do: false
end
