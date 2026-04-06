defmodule Explicit.Schema do
  @moduledoc """
  Parses .explicit/schema.kdl into Elixir structs.
  Schema defines document types, fields, sections, relations, and validation rules.
  """

  defmodule FieldDef do
    defstruct [:name, :type, :required, :pattern, :default, :description, values: [], transitions: []]
  end

  defmodule ColumnDef do
    defstruct [:name, :type, :required, values: []]
  end

  defmodule TableDef do
    defstruct columns: []
  end

  defmodule SectionDef do
    defstruct [:name, :required, :description, :table, :min_paragraphs, :min_items,
               :ordered, :diagram, :callout, children: []]
  end

  defmodule RuleDef do
    defstruct [:name, :when_field, :when_equals, :then_section_table, :table]
  end

  defmodule TypeDef do
    defstruct [:name, :description, :folder, :match, :singleton, :max_count,
               aliases: [], fields: [], sections: [], rules: []]
  end

  defmodule RelationDef do
    defstruct [:name, :inverse, :cardinality, :description]
  end

  defmodule RefFormat do
    defstruct [:name, :pattern]
  end

  defstruct types: [], relations: [], ref_formats: []

  @default_schema_path ".explicit/schema.kdl"

  @doc "Load schema from file or use embedded default"
  def load(project_dir) do
    path = Path.join(project_dir, @default_schema_path)

    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, _} -> parse(default_schema())
    end
  end

  @doc "Parse KDL string into Schema struct"
  def parse(kdl_string) do
    case Kuddle.decode(kdl_string) do
      {:ok, nodes, _rest} ->
        schema = Enum.reduce(nodes, %__MODULE__{}, &parse_node/2)
        {:ok, schema}

      {:ok, nodes} when is_list(nodes) ->
        schema = Enum.reduce(nodes, %__MODULE__{}, &parse_node/2)
        {:ok, schema}

      {:error, reason} ->
        {:error, "Schema parse error: #{inspect(reason)}"}
    end
  end

  defp parse_node(%{name: "type"} = node, schema) do
    type_def = parse_type(node)
    %{schema | types: schema.types ++ [type_def]}
  end

  defp parse_node(%{name: "relation"} = node, schema) do
    rel = %RelationDef{
      name: get_positional(node, 0),
      inverse: get_prop(node, "inverse"),
      cardinality: get_prop(node, "cardinality") || "many",
      description: get_prop(node, "description")
    }
    %{schema | relations: schema.relations ++ [rel]}
  end

  defp parse_node(%{name: "ref-format"} = node, schema) do
    refs = Enum.map(node.children || [], fn child ->
      %RefFormat{name: child.name, pattern: get_prop(child, "pattern")}
    end)
    %{schema | ref_formats: schema.ref_formats ++ refs}
  end

  defp parse_node(_node, schema), do: schema

  defp parse_type(node) do
    children = node.children || []

    %TypeDef{
      name: get_positional(node, 0),
      description: get_prop(node, "description"),
      folder: get_prop(node, "folder"),
      match: get_prop(node, "match") || get_child_value(children, "match"),
      singleton: get_prop(node, "singleton") == true,
      max_count: get_prop(node, "max_count"),
      aliases: parse_aliases(children),
      fields: parse_fields(children),
      sections: parse_sections(children),
      rules: parse_rules(children)
    }
  end

  defp parse_aliases(children) do
    children
    |> Enum.filter(&(&1.name == "alias"))
    |> Enum.flat_map(fn node ->
      node.attributes
      |> Enum.map(&extract_value/1)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp parse_fields(children) do
    children
    |> Enum.filter(&(&1.name == "field"))
    |> Enum.map(&parse_field/1)
  end

  defp parse_field(node) do
    field_children = node.children || []

    %FieldDef{
      name: get_positional(node, 0),
      type: get_prop(node, "type") || "string",
      required: get_prop(node, "required") == true,
      pattern: get_prop(node, "pattern"),
      default: get_prop(node, "default"),
      description: get_prop(node, "description"),
      values: parse_values(field_children),
      transitions: parse_transitions(field_children)
    }
  end

  defp parse_values(children) do
    children
    |> Enum.filter(&(&1.name == "values"))
    |> Enum.flat_map(fn node ->
      node.attributes |> Enum.map(&extract_value/1) |> Enum.reject(&is_nil/1)
    end)
  end

  defp parse_transitions(children) do
    children
    |> Enum.filter(&(&1.name == "transition"))
    |> Enum.map(fn node ->
      values = node.attributes |> Enum.map(&extract_value/1) |> Enum.reject(&is_nil/1)
      {List.first(values), Enum.drop(values, 1)}
    end)
  end

  defp parse_sections(children) do
    children
    |> Enum.filter(&(&1.name == "section"))
    |> Enum.map(&parse_section/1)
  end

  defp parse_section(node) do
    section_children = node.children || []

    content_node = Enum.find(section_children, &(&1.name == "content"))
    list_node = Enum.find(section_children, &(&1.name == "list"))
    table_node = Enum.find(section_children, &(&1.name == "table"))
    diagram_node = Enum.find(section_children, &(&1.name == "diagram"))

    %SectionDef{
      name: get_positional(node, 0),
      required: get_prop(node, "required") == true,
      description: get_prop(node, "description"),
      min_paragraphs: content_node && get_prop(content_node, "min-paragraphs"),
      min_items: list_node && get_prop(list_node, "min-items"),
      ordered: list_node && (get_prop(list_node, "ordered") == true),
      diagram: diagram_node && (get_prop(diagram_node, "required") == true),
      callout: get_prop(node, "callout") == true,
      table: table_node && parse_table(table_node),
      children: parse_sections(section_children)
    }
  end

  defp parse_table(node) do
    columns = (node.children || [])
    |> Enum.filter(&(&1.name == "column"))
    |> Enum.map(fn col ->
      col_children = col.children || []
      %ColumnDef{
        name: get_positional(col, 0),
        type: get_prop(col, "type") || "string",
        required: get_prop(col, "required") == true,
        values: parse_values(col_children)
      }
    end)

    %TableDef{columns: columns}
  end

  defp parse_rules(children) do
    children
    |> Enum.filter(&(&1.name == "rule"))
    |> Enum.map(fn node ->
      rule_children = node.children || []
      when_node = Enum.find(rule_children, &(&1.name == "when"))
      then_node = Enum.find(rule_children, &(&1.name == "then-section-table"))

      table = if then_node do
        table_node = Enum.find(then_node.children || [], &(&1.name == "table"))
        table_node && parse_table(table_node)
      end

      %RuleDef{
        name: get_positional(node, 0),
        when_field: when_node && get_positional(when_node, 0),
        when_equals: when_node && get_prop(when_node, "equals-any"),
        then_section_table: then_node && get_positional(then_node, 0),
        table: table
      }
    end)
  end

  # Extract a positional value from node attributes
  defp get_positional(node, index) do
    node.attributes
    |> Enum.filter(fn
      %{value: _} -> true  # positional value
      {_key, _val} -> false # key-value pair
      _ -> false
    end)
    |> Enum.at(index)
    |> case do
      %{value: v} -> v
      _ -> nil
    end
  end

  # Extract a named property from node attributes
  defp get_child_value(children, name) do
    case Enum.find(children, fn c -> c.name == name end) do
      nil -> nil
      child -> get_positional(child, 0)
    end
  end

  defp get_prop(node, key) do
    node.attributes
    |> Enum.find(fn
      {%{value: k}, _v} -> k == key
      _ -> false
    end)
    |> case do
      {_k, %{value: v}} -> v
      _ -> nil
    end
  end

  defp extract_value(%{value: v}), do: v
  defp extract_value({_k, _v}), do: nil
  defp extract_value(_), do: nil

  @doc "Find type definition by name or alias"
  def find_type(%__MODULE__{types: types}, name) do
    name_lower = String.downcase(name)
    Enum.find(types, fn t ->
      String.downcase(t.name) == name_lower or
        Enum.any?(t.aliases, &(String.downcase(&1) == name_lower))
    end)
  end

  @doc "Get the default embedded schema"
  def default_schema do
    # Embedded from decisiongraph-new schema.kdl
    Path.join(:code.priv_dir(:explicit), "schema.kdl")
    |> File.read!()
  end
end
