defmodule Explicit.Doc.CodePaths do
  @moduledoc """
  Match changed source files against document code_paths globs.
  When a file changes that matches a document's code_paths, warn the user
  to review the related decision document.
  """

  alias Explicit.Doc.{Document, Discovery}
  alias Explicit.Schema

  @doc """
  Check which documents have code_paths matching the given file.
  Returns list of %{doc_id, doc_title, doc_path, matched_pattern}
  """
  def check(file_path, project_dir, %Schema{} = schema) do
    Discovery.discover(project_dir, schema)
    |> Enum.flat_map(fn doc_path ->
      case Document.parse_file(doc_path) do
        {:ok, doc} ->
          code_paths = Map.get(doc.frontmatter, "code_paths", [])
          match_file(file_path, project_dir, code_paths, doc)
        _ ->
          []
      end
    end)
  end

  defp match_file(_file, _project_dir, [], _doc), do: []

  defp match_file(file_path, project_dir, code_paths, doc) when is_list(code_paths) do
    rel_path = Path.relative_to(file_path, project_dir)

    code_paths
    |> Enum.filter(fn pattern ->
      match_glob?(rel_path, pattern)
    end)
    |> Enum.map(fn pattern ->
      %{
        doc_id: doc.id,
        doc_title: doc.title,
        doc_path: doc.path,
        doc_status: Map.get(doc.frontmatter, "status"),
        matched_pattern: pattern
      }
    end)
  end

  defp match_file(_, _, _, _), do: []

  defp match_glob?(path, pattern) do
    # Convert glob pattern to regex
    regex_str = pattern
    |> String.replace(".", "\\.")
    |> String.replace("**", "<<<DOUBLESTAR>>>")
    |> String.replace("*", "[^/]*")
    |> String.replace("<<<DOUBLESTAR>>>", ".*")

    case Regex.compile("^#{regex_str}") do
      {:ok, regex} -> Regex.match?(regex, path)
      _ -> false
    end
  end
end
