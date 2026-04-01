defmodule Explicit.Doc.Discovery do
  @moduledoc """
  Discover markdown documents in docs/ directories based on schema type folders.
  """

  alias Explicit.Schema

  @doc "Find all doc files matching schema type folders"
  def discover(project_dir, %Schema{} = schema) do
    schema.types
    |> Enum.flat_map(fn type_def ->
      folder = Path.join(project_dir, type_def.folder)
      if File.dir?(folder) do
        case type_def.match do
          nil ->
            Path.wildcard(Path.join(folder, "*.md"))
          match_pattern ->
            path = Path.join(folder, match_pattern)
            if File.exists?(path), do: [path], else: []
        end
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  @doc "Check if a file path is a document file (markdown in docs/)"
  def doc_file?(path) do
    Path.extname(path) == ".md" and doc_path?(to_string(path))
  end

  defp doc_path?(path) do
    String.contains?(path, "/docs/") or
      String.ends_with?(path, "/README.md") or
      String.contains?(path, "/AGENTS.md")
  end
end
