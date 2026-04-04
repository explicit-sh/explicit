defmodule Explicit.Doc.Document do
  @moduledoc """
  Parse Markdown files with YAML frontmatter into structured documents.
  """

  defstruct [:path, :id, :type, :title, :frontmatter, :body, :sections, :raw]

  @doc "Parse a markdown file with YAML frontmatter"
  def parse_file(path) do
    case File.read(path) do
      {:ok, raw} -> parse(raw, path)
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end

  @doc "Parse raw markdown string"
  def parse(raw, path \\ nil) do
    case split_frontmatter(raw) do
      {:ok, yaml_str, body} ->
        case YamlElixir.read_from_string(yaml_str) do
          {:ok, frontmatter} ->
            title = extract_title(body)
            id = if path, do: path_to_id(path), else: nil
            type = if path, do: path_to_type(path), else: nil
            sections = parse_sections(body)

            {:ok, %__MODULE__{
              path: path,
              id: id,
              type: type,
              title: title,
              frontmatter: frontmatter || %{},
              body: body,
              sections: sections,
              raw: raw
            }}

          {:error, err} ->
            {:error, "YAML parse error: #{inspect(err)}"}
        end

      :no_frontmatter ->
        {:ok, %__MODULE__{
          path: path,
          id: if(path, do: path_to_id(path)),
          type: if(path, do: path_to_type(path)),
          title: extract_title(raw),
          frontmatter: %{},
          body: raw,
          sections: parse_sections(raw),
          raw: raw
        }}
    end
  end

  defp split_frontmatter(content) do
    # Anchored to file start — won't match thematic breaks (---) in body
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/s, content) do
      [_, yaml, body] -> {:ok, yaml, body}
      _ -> :no_frontmatter
    end
  end

  defp extract_title(body) do
    case Regex.run(~r/^#\s+(.+)$/m, body) do
      [_, title] -> String.trim(title)
      _ -> nil
    end
  end

  @doc "Extract document ID from file path (e.g., docs/architecture/adr-001-use-postgres.md -> ADR-001)"
  def path_to_id(path) do
    basename = Path.basename(path, ".md") |> String.upcase()
    case Regex.run(~r/^([A-Z]+-\d+)/, basename) do
      [_, id] -> id
      _ -> basename
    end
  end

  @doc "Extract document type from path (e.g., docs/architecture/adr-001.md -> adr)"
  def path_to_type(path) do
    basename = Path.basename(path, ".md")
    case Regex.run(~r/^([a-z]+)-\d+$/, String.downcase(basename)) do
      [_, type] -> type
      _ ->
        if String.downcase(basename) == "readme", do: "readme", else: nil
    end
  end

  @doc "Parse markdown body into section hierarchy"
  def parse_sections(body) do
    # Strip code blocks before parsing headings to avoid false positives
    stripped = Regex.replace(~r/```[^`]*```/s, body, "")
    heading_regex = ~r/^(\#{2,6})\s+(.+)$/m
    stripped
    |> String.split(heading_regex, include_captures: true)
    |> build_sections([])
  end

  defp build_sections([], acc), do: Enum.reverse(acc)

  defp build_sections([text | rest], acc) when is_binary(text) do
    # Check if this is a heading
    case Regex.run(~r/^(\#{2,6})\s+(.+)$/, String.trim(text)) do
      [_, hashes, title] ->
        level = String.length(hashes)
        {content, remaining} = take_section_content(rest)
        section = %{name: String.trim(title), level: level, content: String.trim(content)}
        build_sections(remaining, [section | acc])

      _ ->
        build_sections(rest, acc)
    end
  end

  defp take_section_content(parts) do
    take_section_content(parts, [])
  end

  defp take_section_content([], acc), do: {Enum.join(Enum.reverse(acc)), []}

  defp take_section_content([part | rest] = all, acc) do
    if Regex.match?(~r/^\#{2,6}\s+/, String.trim(part)) do
      {Enum.join(Enum.reverse(acc)), all}
    else
      take_section_content(rest, [part | acc])
    end
  end
end
