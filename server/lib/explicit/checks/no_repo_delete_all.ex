defmodule Explicit.Checks.NoRepoDeleteAll do
  @moduledoc """
  Detects Repo.delete_all and Repo.update_all which are dangerous without explicit queries.
  These operations affect all rows if called with a schema module instead of a query.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [excluded_paths: [~r/_test\.exs$/, ~r/test\//]],
    explanations: [
      check: """
      Repo.delete_all/1 and Repo.update_all/2 without a scoped query
      can accidentally affect all rows. Always use an explicit Ecto query.
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
         {{:., meta, [{:__aliases__, _, repo_parts}, func]}, _, args} = ast,
         issues,
         issue_meta
       ) when func in [:delete_all, :update_all] do
    repo_name = Enum.join(repo_parts, ".")
    if String.ends_with?(repo_name, "Repo") do
      # Check if first arg is a bare module (not a query)
      case args do
        [{:__aliases__, _, _} | _] ->
          issue = format_issue(issue_meta,
            message: "#{repo_name}.#{func} called with a bare schema — this affects ALL rows. Use an explicit query with where/2.",
            trigger: "#{func}",
            line_no: meta[:line]
          )
          {ast, [issue | issues]}
        _ ->
          {ast, issues}
      end
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _), do: {ast, issues}
end
