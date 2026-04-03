defmodule Explicit.Doc.ValidationTest do
  use ExUnit.Case

  alias Explicit.Doc.{Document, Validation}
  alias Explicit.Schema

  setup do
    {:ok, schema} = Schema.parse(Schema.default_schema())
    {:ok, schema: schema}
  end

  test "valid ADR has no errors", %{schema: schema} do
    {:ok, doc} = Document.parse("""
    ---
    status: proposed
    author: onni
    date: "2026-04-01"
    ---

    # Use PostgreSQL

    ## Context

    We need a database.

    ## Decision

    Use PostgreSQL.

    ## Consequences

    ### Positive

    Good ecosystem.
    """, "docs/architecture/adr-001.md")

    {:ok, diagnostics} = Validation.validate(doc, schema)
    errors = Enum.filter(diagnostics, fn {level, _, _} -> level == :error end)
    assert errors == []
  end

  test "missing required fields", %{schema: schema} do
    {:ok, doc} = Document.parse("""
    ---
    status: proposed
    ---

    # Bad ADR
    """, "docs/architecture/adr-002.md")

    {:ok, diagnostics} = Validation.validate(doc, schema)
    error_codes = Enum.map(diagnostics, fn {_, code, _} -> code end)
    assert "F001" in error_codes  # missing author
    assert "F001" in error_codes  # missing date
  end

  test "invalid enum value", %{schema: schema} do
    {:ok, doc} = Document.parse("""
    ---
    status: bogus
    author: onni
    date: "2026-04-01"
    ---

    # ADR
    """, "docs/architecture/adr-003.md")

    {:ok, diagnostics} = Validation.validate(doc, schema)
    messages = Enum.map(diagnostics, fn {_, _, msg} -> msg end)
    assert Enum.any?(messages, &String.contains?(&1, "bogus"))
  end

  test "missing required sections", %{schema: schema} do
    {:ok, doc} = Document.parse("""
    ---
    status: proposed
    author: onni
    date: "2026-04-01"
    ---

    # ADR with no sections
    """, "docs/architecture/adr-004.md")

    {:ok, diagnostics} = Validation.validate(doc, schema)
    error_messages = for {:error, _, msg} <- diagnostics, do: msg
    assert Enum.any?(error_messages, &String.contains?(&1, "Context"))
    assert Enum.any?(error_messages, &String.contains?(&1, "Decision"))
  end
end
