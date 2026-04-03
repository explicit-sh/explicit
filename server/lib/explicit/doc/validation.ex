defmodule Explicit.Doc.Validation do
  @moduledoc """
  Validate a parsed Document against a Schema TypeDef.
  Returns a list of diagnostics: {:error | :warning, code, message}
  """

  alias Explicit.Doc.Document
  alias Explicit.Schema
  alias Explicit.Schema.{TypeDef, FieldDef, SectionDef}

  @doc "Validate a document against the schema"
  def validate(%Document{} = doc, %Schema{} = schema) do
    type_def = find_type_def(doc, schema)

    if type_def do
      diagnostics =
        validate_frontmatter(doc, type_def) ++
        validate_sections(doc, type_def) ++
        validate_rules(doc, type_def) ++
        validate_refs(doc, schema)

      {:ok, diagnostics}
    else
      {:ok, [{:warning, "F000", "Unknown document type for #{doc.path || "unknown"}"}]}
    end
  end

  defp find_type_def(%Document{type: nil}, _schema), do: nil
  defp find_type_def(%Document{type: type}, schema), do: Schema.find_type(schema, type)

  # ─── Frontmatter validation ────────────────────────────────────────────────

  defp validate_frontmatter(%Document{frontmatter: fm}, %TypeDef{fields: fields}) do
    Enum.flat_map(fields, fn field ->
      value = Map.get(fm, field.name)
      validate_field(field, value)
    end)
  end

  defp validate_field(%FieldDef{name: name, required: true}, nil) do
    [{:error, "F001", "Missing required field: #{name}"}]
  end

  defp validate_field(_field, nil), do: []

  defp validate_field(%FieldDef{name: name, type: "enum", values: values}, value)
       when is_binary(value) do
    if values != [] and value not in values do
      [{:error, "F002", "Invalid value '#{value}' for field '#{name}'. Expected: #{Enum.join(values, ", ")}"}]
    else
      []
    end
  end

  defp validate_field(%FieldDef{name: name, pattern: pattern}, value)
       when is_binary(pattern) and is_binary(value) do
    if Regex.match?(Regex.compile!(pattern), value) do
      []
    else
      [{:error, "F003", "Field '#{name}' value '#{value}' doesn't match pattern: #{pattern}"}]
    end
  end

  defp validate_field(%FieldDef{name: name, type: "string[]"}, value) do
    if is_list(value) do
      []
    else
      [{:warning, "F004", "Field '#{name}' should be a list"}]
    end
  end

  defp validate_field(_field, _value), do: []

  # ─── Section validation ────────────────────────────────────────────────────

  defp validate_sections(%Document{sections: sections}, %TypeDef{sections: section_defs}) do
    section_names = MapSet.new(sections, & &1.name)

    Enum.flat_map(section_defs, fn sec_def ->
      validate_section_presence(sec_def, section_names, sections)
    end)
  end

  defp validate_section_presence(%SectionDef{name: name, required: true} = sec_def, section_names, sections) do
    if MapSet.member?(section_names, name) do
      validate_section_content(sec_def, sections)
    else
      [{:error, "S001", "Missing required section: #{name}"}]
    end
  end

  defp validate_section_presence(%SectionDef{name: name} = sec_def, section_names, sections) do
    if MapSet.member?(section_names, name) do
      validate_section_content(sec_def, sections)
    else
      []
    end
  end

  defp validate_section_content(%SectionDef{name: name, min_paragraphs: min}, sections)
       when is_integer(min) and min > 0 do
    section = Enum.find(sections, &(&1.name == name))
    if section do
      paragraphs = section.content
        |> String.split(~r/\n\n+/)
        |> Enum.reject(&(String.trim(&1) == ""))
        |> length()

      if paragraphs < min do
        [{:warning, "C001", "Section '#{name}' has #{paragraphs} paragraph(s), expected at least #{min}"}]
      else
        check_section_substance(name, section.content)
      end
    else
      []
    end
  end

  defp validate_section_content(%SectionDef{name: name, required: true}, sections) do
    section = Enum.find(sections, &(&1.name == name))
    if section do
      check_section_substance(name, section.content)
    else
      []
    end
  end

  defp validate_section_content(_sec_def, _sections), do: []

  # Detect low-effort boilerplate content
  defp check_section_substance(name, content) do
    trimmed = String.trim(content)
    word_count = trimmed |> String.split(~r/\s+/) |> length()

    cond do
      word_count < 5 ->
        [{:warning, "C002", "Section '#{name}' has only #{word_count} words — add more detail"}]
      String.match?(trimmed, ~r/^(TBD|TODO|FIXME|N\/A|None|\.{3})$/i) ->
        [{:warning, "C003", "Section '#{name}' contains placeholder text — fill in real content"}]
      String.match?(trimmed, ~r/^(This section describes|The purpose of this|Description goes here)/i) ->
        [{:warning, "C003", "Section '#{name}' contains boilerplate filler — write specific content"}]
      true ->
        []
    end
  end

  # ─── Rule validation ──────────────────────────────────────────────────────

  defp validate_rules(%Document{frontmatter: fm, sections: sections}, %TypeDef{rules: rules}) do
    Enum.flat_map(rules, fn rule ->
      if rule_applies?(rule, fm) do
        check_rule_requirement(rule, sections)
      else
        []
      end
    end)
  end

  defp rule_applies?(rule, fm) do
    value = Map.get(fm, rule.when_field)
    if rule.when_equals do
      allowed = String.split(rule.when_equals, ",")
      value in allowed
    else
      false
    end
  end

  defp check_rule_requirement(rule, sections) do
    if rule.then_section_table do
      section_names = MapSet.new(sections, & &1.name)
      if MapSet.member?(section_names, rule.then_section_table) do
        []
      else
        [{:error, "S002", "Rule '#{rule.name}': section '#{rule.then_section_table}' is required"}]
      end
    else
      []
    end
  end

  # ─── Reference validation ──────────────────────────────────────────────────

  defp validate_refs(%Document{frontmatter: fm}, %Schema{} = _schema) do
    # Check for ref fields (supersedes, enables, depends_on, etc.)
    ref_fields = ["supersedes", "superseded_by", "enables", "enabled_by",
                  "triggers", "triggered_by", "depends_on", "dependency_of",
                  "implements", "implemented_by", "conflicts_with", "related"]

    Enum.flat_map(ref_fields, fn field ->
      case Map.get(fm, field) do
        nil -> []
        refs when is_list(refs) ->
          Enum.flat_map(refs, &validate_ref_format(&1, field))
        ref when is_binary(ref) ->
          validate_ref_format(ref, field)
        _ -> []
      end
    end)
  end

  defp validate_ref_format(ref, field) do
    if Regex.match?(~r/^[A-Z]+-\d+$/, ref) or String.ends_with?(ref, ".md") do
      []
    else
      [{:warning, "R001", "Reference '#{ref}' in field '#{field}' doesn't match expected format"}]
    end
  end

  @doc "Format diagnostics for display"
  def format_diagnostics(diagnostics) do
    Enum.map(diagnostics, fn {level, code, message} ->
      %{level: to_string(level), code: code, message: message}
    end)
  end
end
