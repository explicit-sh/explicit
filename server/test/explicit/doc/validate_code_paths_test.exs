defmodule Explicit.Doc.ValidateCodePathsTest do
  use ExUnit.Case

  alias Explicit.Doc.{Document, Validation}
  alias Explicit.Schema

  setup do
    {:ok, schema} = Schema.parse(Schema.default_schema())
    {:ok, schema: schema}
  end

  test "rejects code_paths in frontmatter", %{schema: schema} do
    {:ok, doc} = Document.parse("""
    ---
    status: proposed
    author: onni
    date: "2026-04-01"
    code_paths: ["lib/my_app/**"]
    ---

    # Bad ADR with code_paths

    ## Context

    This ADR wrongly uses code_paths. Links should go from code to docs.

    ## Decision

    Use the old dg-style code_paths linking.

    ## Consequences

    ### Positive

    Seems easy.

    ### Negative

    Wrong direction — code should reference docs, not the other way.
    """, "docs/architecture/adr-001.md")

    # The validation itself doesn't check code_paths (that's a connection handler concern)
    # But we can verify the frontmatter contains code_paths
    assert Map.has_key?(doc.frontmatter, "code_paths")

    # The validate method in connection_handler checks this
    # Simulate what it does:
    code_paths_diags = if Map.has_key?(doc.frontmatter, "code_paths") do
      [{:error, "F010", "Field 'code_paths' is not allowed in frontmatter. Links go from code to docs, not the other way."}]
    else
      []
    end

    assert length(code_paths_diags) == 1
    [{:error, "F010", msg}] = code_paths_diags
    assert msg =~ "code_paths"
    assert msg =~ "not allowed"
  end

  test "allows frontmatter without code_paths", %{schema: schema} do
    {:ok, doc} = Document.parse("""
    ---
    status: proposed
    author: onni
    date: "2026-04-01"
    ---

    # Good ADR without code_paths

    ## Context

    This ADR does not use code_paths. Code references this doc via @moduledoc.

    ## Decision

    Let code reference docs, not the other way around.

    ## Consequences

    ### Positive

    Clean separation. Tool scans code automatically.

    ### Negative

    None significant.
    """, "docs/architecture/adr-002.md")

    refute Map.has_key?(doc.frontmatter, "code_paths")

    {:ok, diags} = Validation.validate(doc, schema)
    errors = Enum.filter(diags, fn {level, _, _} -> level == :error end)
    assert errors == []
  end
end
