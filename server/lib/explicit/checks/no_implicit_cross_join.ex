defmodule Explicit.Checks.NoImplicitCrossJoin do
  @moduledoc """
  Iron Law #15: No implicit cross joins in Ecto queries.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: "from(a in A, b in B) creates a Cartesian product. Use explicit join()."
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse({:from, meta, args} = ast, issues, issue_meta) when is_list(args) do
    in_count =
      args
      |> List.flatten()
      |> Enum.count(fn
        {:in, _, _} -> true
        _ -> false
      end)

    if in_count >= 2 do
      issue =
        format_issue(issue_meta,
          message: "Iron Law #15: Implicit cross join — multiple `in` bindings in from(). Use join().",
          trigger: "from",
          line_no: meta[:line]
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _), do: {ast, issues}
end
