defmodule Explicit.Checks.NoFloatForMoney do
  @moduledoc """
  Iron Law #4: No :float for money fields.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      money_patterns: ~w(price amount cost total balance fee rate charge payment salary wage budget revenue discount)
    ],
    explanations: [
      check: "Floating point causes rounding errors with money. Use :decimal or :integer (cents)."
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    money_patterns = Params.get(params, :money_patterns, __MODULE__)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, money_patterns))
  end

  # field :price, :float
  defp traverse({:field, meta, [field_name, :float | _]} = ast, issues, issue_meta, patterns)
       when is_atom(field_name) do
    if money_field?(field_name, patterns) do
      {ast, [money_issue(issue_meta, field_name, meta[:line], "schema") | issues]}
    else
      {ast, issues}
    end
  end

  # add :price, :float (migration)
  defp traverse({:add, meta, [field_name, :float | _]} = ast, issues, issue_meta, patterns)
       when is_atom(field_name) do
    if money_field?(field_name, patterns) do
      {ast, [money_issue(issue_meta, field_name, meta[:line], "migration") | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _, _), do: {ast, issues}

  defp money_field?(field_name, patterns) do
    name = Atom.to_string(field_name)
    Enum.any?(patterns, &String.contains?(name, &1))
  end

  defp money_issue(issue_meta, field_name, line, context) do
    format_issue(issue_meta,
      message: "Iron Law #4: :float for money field :#{field_name} in #{context} — use :decimal or :integer.",
      trigger: ":float",
      line_no: line
    )
  end
end
