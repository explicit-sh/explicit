defmodule Explicit.Checker do
  @moduledoc """
  Runs all checks against files and projects.
  Per-file checks use Credo AST. Project-level checks use multi-file context.
  """

  alias Credo.SourceFile

  @file_checks [
    Explicit.Checks.NoStringToAtom,
    Explicit.Checks.NoFloatForMoney,
    Explicit.Checks.NoRawWithVariable,
    Explicit.Checks.NoImplicitCrossJoin,
    Explicit.Checks.NoBareStartLink,
    Explicit.Checks.NoAssignNewForMountValues,
    Explicit.Checks.NoPublicWithoutDoc,
    Explicit.Checks.NoPublicWithoutSpec
  ]

  @doc "Check a single file and return violations"
  @spec check_file(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def check_file(file_path) do
    case File.read(file_path) do
      {:ok, source} ->
        source_file = SourceFile.parse(source, file_path)

        violations =
          @file_checks
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

  @doc "Check a file and update the ViolationStore"
  def check_and_store(file_path) do
    case check_file(file_path) do
      {:ok, violations} ->
        Explicit.ViolationStore.put(file_path, violations)
        {:ok, violations}

      error ->
        error
    end
  end

  @doc "Run project-level checks (missing test files, etc)"
  def project_checks(project_dir) do
    Explicit.Checks.NoModuleWithoutTest.check(project_dir)
  end

  @doc "Run project-level checks and store results"
  def project_checks_and_store(project_dir) do
    violations = project_checks(project_dir)
    Explicit.ViolationStore.put("__project__", violations)
    violations
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
