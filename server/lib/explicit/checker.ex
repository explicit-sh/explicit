defmodule Explicit.Checker do
  @moduledoc """
  Runs all Iron Law checks against a single file.
  Creates a Credo SourceFile and runs each check's run/2.
  """

  alias Credo.SourceFile

  @checks [
    Explicit.Checks.NoStringToAtom,
    Explicit.Checks.NoFloatForMoney,
    Explicit.Checks.NoRawWithVariable,
    Explicit.Checks.NoImplicitCrossJoin,
    Explicit.Checks.NoBareStartLink,
    Explicit.Checks.NoAssignNewForMountValues
  ]

  @doc """
  Check a file and return a list of violation maps.
  """
  @spec check_file(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def check_file(file_path) do
    case File.read(file_path) do
      {:ok, source} ->
        source_file = SourceFile.parse(source, file_path)

        violations =
          @checks
          |> Enum.flat_map(fn check ->
            try do
              check.run(source_file, [])
            rescue
              _ -> []
            end
          end)
          |> Enum.map(&issue_to_map(&1, file_path))

        {:ok, violations}

      {:error, reason} ->
        {:error, "Cannot read #{file_path}: #{reason}"}
    end
  end

  @doc """
  Check a file and update the ViolationStore.
  """
  def check_and_store(file_path) do
    case check_file(file_path) do
      {:ok, violations} ->
        Explicit.ViolationStore.put(file_path, violations)
        {:ok, violations}

      error ->
        error
    end
  end

  defp issue_to_map(issue, file_path) do
    %{
      file: file_path,
      line: issue.line_no || 0,
      check: issue.check |> Module.split() |> List.last(),
      message: issue.message
    }
  end
end
