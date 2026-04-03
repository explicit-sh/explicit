defmodule Explicit.Checker do
  @moduledoc """
  Runs all checks against files and projects.
  Per-file checks use Credo AST. Project-level checks use multi-file context.
  Supports inline suppression via `# explicit:disable RuleName`.
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
    Explicit.Checks.NoPublicWithoutSpec,
    Explicit.Checks.NoIOInspect,
    Explicit.Checks.NoMixEnvInRuntime
  ]

  @doc "Check a single file and return violations"
  @spec check_file(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def check_file(file_path) do
    case File.read(file_path) do
      {:ok, source} ->
        suppressions = parse_suppressions(source)
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
          |> filter_suppressed(suppressions)

        {:ok, violations}

      {:error, reason} ->
        {:error, "Cannot read #{file_path}: #{reason}"}
    end
  end

  @doc "Check a file and update the ViolationStore. Skips if file unchanged (hash match)."
  @spec check_and_store(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def check_and_store(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        hash = :erlang.phash2(content)
        cached_hash = Explicit.ViolationStore.get_hash(file_path)

        if hash == cached_hash do
          # File unchanged — return cached violations
          {:ok, Explicit.ViolationStore.get(file_path)}
        else
          case check_file(file_path) do
            {:ok, violations} ->
              Explicit.ViolationStore.put(file_path, violations, hash)
              {:ok, violations}
            error ->
              error
          end
        end

      {:error, reason} ->
        {:error, "Cannot read #{file_path}: #{reason}"}
    end
  end

  @doc "Run project-level checks (missing test files, etc)"
  @spec project_checks(String.t()) :: [map()]
  def project_checks(project_dir) do
    Explicit.Checks.NoModuleWithoutTest.check(project_dir)
  end

  @doc "Run project-level checks and store results"
  @spec project_checks_and_store(String.t()) :: [map()]
  def project_checks_and_store(project_dir) do
    violations = project_checks(project_dir)
    Explicit.ViolationStore.put("__project__", violations)
    violations
  end

  # ─── Suppression parsing ────────────────────────────────────────────────────

  @doc """
  Parse `# explicit:disable RuleName` comments from source.
  Returns %{line_number => [rule_names]} for per-line disables
  and a set of file-level disables.
  """
  @spec parse_suppressions(String.t()) :: %{lines: map(), file: MapSet.t()}
  def parse_suppressions(source) do
    lines = String.split(source, "\n")

    {line_disables, file_disables} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, MapSet.new()}, fn {line, line_no}, {lines_acc, file_acc} ->
        case Regex.run(~r/#\s*explicit:disable\s+(.+)/, line) do
          [_, rules_str] ->
            rules = rules_str |> String.split(~r/[,\s]+/) |> Enum.reject(&(&1 == ""))

            # If the line is ONLY a comment (no code before it), it applies to the next line
            trimmed = String.trim(line)
            if String.starts_with?(trimmed, "#") do
              # File-level if at top of file (first 5 lines), otherwise next-line
              if line_no <= 5 do
                {lines_acc, Enum.reduce(rules, file_acc, &MapSet.put(&2, &1))}
              else
                {Map.put(lines_acc, line_no + 1, rules), file_acc}
              end
            else
              # Inline: applies to this line
              {Map.put(lines_acc, line_no, rules), file_acc}
            end

          _ ->
            {lines_acc, file_acc}
        end
      end)

    %{lines: line_disables, file: file_disables}
  end

  defp filter_suppressed(violations, suppressions) do
    Enum.reject(violations, fn v ->
      check_name = v.check

      # File-level disable
      MapSet.member?(suppressions.file, check_name) or
        # Line-level disable
        case Map.get(suppressions.lines, v.line) do
          nil -> false
          rules -> check_name in rules
        end
    end)
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
