defmodule Explicit.Checks.NoAssignNewForMountValues do
  @moduledoc """
  Iron Law #21: No assign_new for values that should refresh every mount.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [per_mount_keys: [:current_user, :locale, :timezone, :current_org]],
    explanations: [
      check: "assign_new/3 skips if key exists. Use assign/3 for per-mount values."
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    keys = Params.get(params, :per_mount_keys, __MODULE__)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, keys))
  end

  defp traverse({:assign_new, meta, [_socket, key | _]} = ast, issues, issue_meta, keys)
       when is_atom(key) do
    if key in keys do
      issue =
        format_issue(issue_meta,
          message: "Iron Law #21: assign_new for :#{key} — use assign/3 instead.",
          trigger: "assign_new",
          line_no: meta[:line]
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _, _), do: {ast, issues}
end
