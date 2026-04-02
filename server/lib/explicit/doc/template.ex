defmodule Explicit.Doc.Template do
  @moduledoc """
  Generate new document files from schema TypeDef.
  Auto-increments ID, creates frontmatter + required sections.
  """

  alias Explicit.Schema
  alias Explicit.Schema.{TypeDef, FieldDef, SectionDef}

  @doc "Create a new document file. Returns {:ok, path, content} or {:error, reason}"
  def create(project_dir, %Schema{} = schema, type_name, title, opts \\ []) do
    case Schema.find_type(schema, type_name) do
      nil -> {:error, "Unknown document type: #{type_name}"}
      type_def -> do_create(project_dir, type_def, title, opts)
    end
  end

  defp do_create(project_dir, %TypeDef{} = type_def, title, opts) do
    folder = Path.join(project_dir, type_def.folder)
    File.mkdir_p!(folder)

    id = next_id(folder, type_def.name)
    filename = "#{String.downcase(id)}.md"
    path = Path.join(folder, filename)

    if File.exists?(path) do
      {:error, "File already exists: #{path}"}
    else
      extra_fields = Keyword.get(opts, :fields, %{})
      content = render(type_def, id, title, extra_fields)
      File.write!(path, content)
      {:ok, path, content}
    end
  end

  @doc "Render document content from type definition"
  def render(%TypeDef{} = type_def, _id, title, extra_fields \\ %{}) do
    frontmatter = render_frontmatter(type_def, extra_fields)
    sections = render_sections(type_def.sections, 2)

    """
    ---
    #{frontmatter}---

    # #{title}

    #{sections}\
    """
  end

  defp render_frontmatter(%TypeDef{fields: fields}, extra_fields) do
    fields
    |> Enum.map(fn field ->
      value = Map.get(extra_fields, field.name) || default_value(field)
      render_field(field.name, field, value)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  defp render_field(name, %FieldDef{type: "string[]"}, nil) do
    "#{name}: []\n"
  end

  defp render_field(name, %FieldDef{type: "user[]"}, nil) do
    "#{name}: []\n"
  end

  defp render_field(_name, _field, nil) do
    nil
  end

  defp render_field(name, _field, value) when is_list(value) do
    "#{name}: [#{Enum.join(value, ", ")}]\n"
  end

  defp render_field(name, _field, value) do
    "#{name}: #{value}\n"
  end

  defp default_value(%FieldDef{default: "$TODAY"}) do
    Date.utc_today() |> Date.to_iso8601()
  end

  defp default_value(%FieldDef{default: default}) when not is_nil(default), do: default
  defp default_value(%FieldDef{required: true, type: "string"}), do: nil
  defp default_value(%FieldDef{required: true, type: "user"}), do: nil
  defp default_value(_), do: nil

  defp render_sections(sections, level) do
    sections
    |> Enum.map(&render_section(&1, level))
    |> Enum.join("\n")
  end

  defp render_section(%SectionDef{} = sec, level) do
    heading = String.duplicate("#", level)
    description = if sec.description, do: "\n\n#{sec.description}", else: ""
    table = if sec.table, do: "\n\n#{render_table(sec.table)}", else: ""
    children = if sec.children != [], do: "\n\n" <> render_sections(sec.children, level + 1), else: ""

    "#{heading} #{sec.name}#{description}#{table}#{children}\n"
  end

  defp render_table(%Schema.TableDef{columns: columns}) do
    headers = Enum.map(columns, & &1.name)
    separator = Enum.map(columns, fn _ -> "---" end)

    "| #{Enum.join(headers, " | ")} |\n| #{Enum.join(separator, " | ")} |\n"
  end

  defp next_id(folder, type_name) do
    prefix = String.upcase(type_name)

    existing =
      folder
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))
      |> Enum.map(&String.upcase/1)
      |> Enum.filter(&String.starts_with?(&1, "#{prefix}-"))
      |> Enum.map(fn name ->
        case Regex.run(~r/-(\d+)$/, name) do
          [_, num] -> String.to_integer(num)
          _ -> 0
        end
      end)

    next_num = if existing == [], do: 1, else: Enum.max(existing) + 1
    "#{prefix}-#{String.pad_leading(Integer.to_string(next_num), 3, "0")}"
  end
end
