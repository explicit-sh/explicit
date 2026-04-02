defmodule Explicit.Checks.NoPublicWithoutSpec do
  @moduledoc """
  Ensures public functions have @spec type specifications.
  Skips test files, callbacks, and Phoenix-generated functions.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [excluded_paths: [~r/_test\.exs$/, ~r/test\//, ~r/mix\.exs$/]],
    explanations: [
      check: """
      Public functions should have @spec type specifications.
      Add @spec function_name(arg_type) :: return_type before `def`.
      """
    ]

  @skip_functions ~w(
    __using__ child_spec start_link init
    handle_call handle_cast handle_info handle_event handle_continue
    terminate code_change format_status
    mount render update handle_params handle_event
    changeset action fallback_action
  )

  @impl true
  def run(%SourceFile{} = source_file, params) do
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Enum.any?(excluded, &Regex.match?(&1, source_file.filename)) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      source = SourceFile.source(source_file)
      lines = String.split(source, "\n")
      find_unspecced_functions(lines, issue_meta)
    end
  end

  defp find_unspecced_functions(lines, issue_meta) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, line_no}, {has_spec, issues} ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "@spec") ->
          {true, issues}

        String.starts_with?(trimmed, "@impl") ->
          {true, issues}

        match?("def " <> _, trimmed) and not has_spec ->
          case extract_function_name(trimmed) do
            nil -> {false, issues}
            name ->
              if name in @skip_functions do
                {false, issues}
              else
                issue = format_issue(issue_meta,
                  message: "Public function #{name} has no @spec",
                  trigger: name,
                  line_no: line_no
                )
                {false, [issue | issues]}
              end
          end

        String.starts_with?(trimmed, "def ") or String.starts_with?(trimmed, "defp ") ->
          {false, issues}

        true ->
          {has_spec, issues}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp extract_function_name(line) do
    case Regex.run(~r/^def\s+([a-z_][a-z0-9_?!]*)/, line) do
      [_, name] -> name
      _ -> nil
    end
  end
end
