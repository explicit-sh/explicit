defmodule Explicit.DocStore do
  @moduledoc """
  ETS-backed store for document validation diagnostics. Keyed by file path.
  Parallel to ViolationStore but for doc validation results.
  """

  use GenServer

  @table :explicit_doc_diagnostics

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def put(file_path, diagnostics) when is_binary(file_path) and is_list(diagnostics) do
    :ets.insert(@table, {file_path, diagnostics})
    :ok
  end

  def get(file_path) when is_binary(file_path) do
    case :ets.lookup(@table, file_path) do
      [{^file_path, diagnostics}] -> diagnostics
      [] -> []
    end
  end

  def all do
    :ets.tab2list(@table)
    |> Map.new(fn {path, diags} -> {path, diags} end)
  end

  def summary do
    all = :ets.tab2list(@table)
    diagnostics = Enum.flat_map(all, fn {_path, ds} -> ds end)

    errors = Enum.count(diagnostics, fn {level, _, _} -> level == :error end)
    warnings = Enum.count(diagnostics, fn {level, _, _} -> level == :warning end)

    %{
      total: length(diagnostics),
      errors: errors,
      warnings: warnings,
      files: length(all)
    }
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end
end
