defmodule Explicit.Checks.NoPublicWithoutSpec do
  @moduledoc """
  Ensures public functions have @spec type specifications.
  Skips: test files, callbacks, Phoenix components (use attr/slot instead),
  @moduledoc false modules, Phoenix boilerplate files.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [excluded_paths: [
      ~r/_test\.exs$/, ~r/test\//, ~r/mix\.exs$/,
      ~r/endpoint\.ex$/, ~r/telemetry\.ex$/, ~r/gettext\.ex$/,
      ~r/router\.ex$/, ~r/_web\.ex$/
    ]],
    explanations: [
      check: """
      Public functions should have @spec type specifications.
      Phoenix component functions (with attr/slot) are skipped —
      they use declarative type docs instead of @spec.
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
        # Skip Phoenix component modules — they use attr/slot for typing
        is_component = String.contains?(source, "use Phoenix.Component") or
                       String.contains?(source, "use Phoenix.LiveComponent")

        issue_meta = IssueMeta.for(source_file, params)
        lines = String.split(source, "\n")
        find_unspecced_functions(lines, issue_meta, is_component)
      end
    end
  end

  defp find_unspecced_functions(lines, issue_meta, is_component) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce({false, false, []}, fn {line, line_no}, {has_spec, has_attr, issues} ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "@spec") -> {true, has_attr, issues}
        String.starts_with?(trimmed, "@impl") -> {true, has_attr, issues}

        # Track attr/slot — these are type declarations for the next component function
        String.starts_with?(trimmed, "attr ") -> {has_spec, true, issues}
        String.starts_with?(trimmed, "slot ") -> {has_spec, true, issues}

        match?("def " <> _, trimmed) and not has_spec ->
          case extract_function_name(trimmed) do
            nil -> {false, false, issues}
            name ->
              # Skip if: known skip function, component with attr declarations,
              # or component module with single assigns arg
              skip = name in @skip_functions or has_attr or
                     (is_component and component_function?(trimmed))

              if skip do
                {false, false, issues}
              else
                issue = format_issue(issue_meta,
                  message: "Public function #{name} has no @spec",
                  trigger: name,
                  line_no: line_no
                )
                {false, false, [issue | issues]}
              end
          end

        String.starts_with?(trimmed, "defp ") ->
          {false, false, issues}

        true ->
          {has_spec, has_attr, issues}
      end
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  # Phoenix component functions take a single `assigns` argument
  defp component_function?(line) do
    String.match?(line, ~r/^def\s+\w+\(%?\w*assigns\w*%?\)/) or
      String.match?(line, ~r/^def\s+\w+\(assigns\)/)
  end

  defp extract_function_name(line) do
    case Regex.run(~r/^def\s+([a-z_][a-z0-9_?!]*)/, line) do
      [_, name] -> name
      _ -> nil
    end
  end
end
