defmodule Explicit.Checks.NoPublicWithoutDoc do
  @moduledoc """
  Ensures public functions have @doc attributes.
  Skips: test files, callbacks, Phoenix components (attr/slot), @moduledoc false modules.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    param_defaults: [excluded_paths: [
      ~r/_test\.exs$/, ~r/test\//, ~r/mix\.exs$/,
      ~r/endpoint\.ex$/, ~r/telemetry\.ex$/, ~r/gettext\.ex$/,
      ~r/router\.ex$/, ~r/_web\.ex$/
    ]],
    explanations: [
      check: """
      Public functions should have @doc explaining their purpose.
      Add @doc "..." before `def function_name`.
      Use @doc false to explicitly mark internal public functions.
      Phoenix components with attr/slot declarations are recognized as documented.
      Modules with @moduledoc false are skipped entirely.
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
      source = SourceFile.source(source_file)

      # Skip entire module if @moduledoc false
      if String.contains?(source, "@moduledoc false") do
        []
      else
        issue_meta = IssueMeta.for(source_file, params)
        lines = String.split(source, "\n")
        find_undocumented_functions(lines, issue_meta)
      end
    end
  end

  defp find_undocumented_functions(lines, issue_meta) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce({false, []}, fn {line, line_no}, {has_doc, issues} ->
      trimmed = String.trim(line)

      cond do
        # @doc, @impl, attr, slot all count as documentation
        String.starts_with?(trimmed, "@doc") -> {true, issues}
        String.starts_with?(trimmed, "@impl") -> {true, issues}
        String.starts_with?(trimmed, "attr ") -> {true, issues}
        String.starts_with?(trimmed, "slot ") -> {true, issues}

        match?("def " <> _, trimmed) and not has_doc ->
          case extract_function_name(trimmed) do
            nil -> {false, issues}
            name ->
              if name in @skip_functions do
                {false, issues}
              else
                issue = format_issue(issue_meta,
                  message: "Public function #{name} has no @doc",
                  trigger: name,
                  line_no: line_no
                )
                {false, [issue | issues]}
              end
          end

        # Reset doc tracking on new function def (but not on same-name multi-head)
        String.starts_with?(trimmed, "defp ") ->
          {false, issues}

        true ->
          {has_doc, issues}
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
