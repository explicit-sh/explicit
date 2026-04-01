defmodule Explicit.Checks.NoBareStartLink do
  @moduledoc """
  Iron Law #13/14: No bare GenServer/Agent.start_link outside supervised modules.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      GenServer.start_link/3 or Agent.start_link/2 outside a supervised module
      means the process will silently die on crash. Add to a supervision tree.
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    ast = Credo.Code.ast(source_file)

    if defines_supervisor?(ast) or defines_start_link_or_child_spec?(ast) do
      []
    else
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp traverse(
         {{:., meta, [{:__aliases__, _, module_parts}, :start_link]}, _, _} = ast,
         issues,
         issue_meta
       )
       when module_parts in [[:GenServer], [:Agent]] do
    mod = Enum.join(module_parts, ".")

    issue =
      format_issue(issue_meta,
        message: "Iron Law #14: Bare #{mod}.start_link outside supervised module.",
        trigger: "#{mod}.start_link",
        line_no: meta[:line]
      )

    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _), do: {ast, issues}

  defp defines_supervisor?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, [:Supervisor]} | _]} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  defp defines_start_link_or_child_spec?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:def, _, [{name, _, _} | _]} = node, _acc when name in [:start_link, :child_spec] ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
