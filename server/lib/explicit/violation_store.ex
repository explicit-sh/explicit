defmodule Explicit.ViolationStore do
  @moduledoc """
  ETS-backed store for file violations. Keyed by file path.
  Supports concurrent reads from multiple connection handlers.
  """

  use GenServer

  @table :explicit_violations

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store violations with optional content hash for cache invalidation"
  def put(file_path, violations, hash \\ nil) when is_binary(file_path) and is_list(violations) do
    :ets.insert(@table, {file_path, violations, hash})
    :ok
  end

  def get(file_path) when is_binary(file_path) do
    case :ets.lookup(@table, file_path) do
      [{^file_path, violations, _hash}] -> violations
      [{^file_path, violations}] -> violations
      [] -> []
    end
  end

  @doc "Get the stored hash for a file, or nil if not cached"
  def get_hash(file_path) when is_binary(file_path) do
    case :ets.lookup(@table, file_path) do
      [{^file_path, _violations, hash}] -> hash
      _ -> nil
    end
  end

  def all do
    :ets.tab2list(@table)
    |> Map.new(fn
      {path, violations, _hash} -> {path, violations}
      {path, violations} -> {path, violations}
    end)
  end

  def summary do
    all = :ets.tab2list(@table)

    violations =
      Enum.flat_map(all, fn
        {_path, vs, _hash} -> vs
        {_path, vs} -> vs
      end)

    by_check =
      violations
      |> Enum.group_by(& &1.check)
      |> Map.new(fn {check, vs} -> {check, length(vs)} end)

    %{
      total: length(violations),
      files: length(all),
      by_check: by_check
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
