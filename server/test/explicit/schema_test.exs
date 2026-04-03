defmodule Explicit.SchemaTest do
  use ExUnit.Case

  alias Explicit.Schema

  test "parses default schema.kdl" do
    {:ok, schema} = Schema.parse(Schema.default_schema())
    assert length(schema.types) >= 5
    assert length(schema.relations) >= 4
  end

  test "finds type by name" do
    {:ok, schema} = Schema.parse(Schema.default_schema())
    adr = Schema.find_type(schema, "adr")
    assert adr.name == "adr"
    assert adr.folder == "docs/architecture"
  end

  test "finds type by alias" do
    {:ok, schema} = Schema.parse(Schema.default_schema())
    assert Schema.find_type(schema, "architecture").name == "adr"
    assert Schema.find_type(schema, "incident").name == "inc"
  end

  test "parses fields correctly" do
    {:ok, schema} = Schema.parse(Schema.default_schema())
    adr = Schema.find_type(schema, "adr")

    status = Enum.find(adr.fields, &(&1.name == "status"))
    assert status.type == "enum"
    assert status.required == true
    assert "proposed" in status.values
    assert "accepted" in status.values
  end

  test "parses sections with children" do
    {:ok, schema} = Schema.parse(Schema.default_schema())
    adr = Schema.find_type(schema, "adr")

    consequences = Enum.find(adr.sections, &(&1.name == "Consequences"))
    assert consequences.required == true
    assert length(consequences.children) == 2
  end

  test "parses relations" do
    {:ok, schema} = Schema.parse(Schema.default_schema())
    supersedes = Enum.find(schema.relations, &(&1.name == "supersedes"))
    assert supersedes.inverse == "superseded_by"
    assert supersedes.cardinality == "one"
  end

  test "returns error for invalid KDL" do
    assert {:error, _} = Schema.parse("{{invalid")
  end
end
