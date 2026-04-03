defmodule Explicit.Checks.NoCompileTimeAppConfig do
  @moduledoc """
  Detects Application.get_env in module attributes (compile-time).
  The value is baked into the BEAM file and won't reflect runtime config changes.
  This is a very common source of bugs with releases.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [excluded_paths: [~r/_test\.exs$/, ~r/test\//]],
    explanations: [
      check: """
      Module attributes are evaluated at compile time. Using Application.get_env
      in a module attribute means the config value is frozen at compile time and
      won't reflect runtime changes (e.g., environment variables set at deploy time).
      Move the call inside a function body instead.
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Enum.any?(excluded, &Regex.match?(&1, source_file.filename)) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      source = SourceFile.source(source_file)
      check_module_attrs(source, issue_meta)
    end
  end

  defp check_module_attrs(source, issue_meta) do
    lines = String.split(source, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      trimmed = String.trim(line)
      if String.starts_with?(trimmed, "@") and
         not String.starts_with?(trimmed, "@doc") and
         not String.starts_with?(trimmed, "@moduledoc") and
         not String.starts_with?(trimmed, "@spec") and
         not String.starts_with?(trimmed, "@type") and
         not String.starts_with?(trimmed, "@impl") and
         not String.starts_with?(trimmed, "@behaviour") and
         not String.starts_with?(trimmed, "@callback") and
         String.contains?(trimmed, "Application.get_env") do
        [format_issue(issue_meta,
          message: "Application.get_env in module attribute is evaluated at compile time — move to function body.",
          trigger: "Application.get_env",
          line_no: line_no
        )]
      else
        []
      end
    end)
  end
end
