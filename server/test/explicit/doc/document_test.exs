defmodule Explicit.Doc.DocumentTest do
  use ExUnit.Case

  alias Explicit.Doc.Document

  @valid_adr """
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
  """

  test "parses frontmatter" do
    {:ok, doc} = Document.parse(@valid_adr, "docs/architecture/adr-001.md")
    assert doc.frontmatter["status"] == "proposed"
    assert doc.frontmatter["author"] == "onni"
  end

  test "extracts title" do
    {:ok, doc} = Document.parse(@valid_adr, "docs/architecture/adr-001.md")
    assert doc.title == "Use PostgreSQL"
  end

  test "extracts document ID from path" do
    assert Document.path_to_id("docs/architecture/adr-001.md") == "ADR-001"
    assert Document.path_to_id("docs/incidents/inc-042.md") == "INC-042"
  end

  test "extracts type from path" do
    assert Document.path_to_type("docs/architecture/adr-001.md") == "adr"
    assert Document.path_to_type("docs/specs/spec-003.md") == "spec"
    assert Document.path_to_type("README.md") == "readme"
  end

  test "parses sections" do
    {:ok, doc} = Document.parse(@valid_adr, "adr-001.md")
    section_names = Enum.map(doc.sections, & &1.name)
    assert "Context" in section_names
    assert "Decision" in section_names
    assert "Consequences" in section_names
  end

  test "handles no frontmatter" do
    {:ok, doc} = Document.parse("# Just a title\n\nSome text.", "test.md")
    assert doc.frontmatter == %{}
    assert doc.title == "Just a title"
  end

  test "does not match thematic break as frontmatter" do
    md = """
    ---
    status: proposed
    ---

    # Title

    Some text.

    ---

    More text after horizontal rule.
    """

    {:ok, doc} = Document.parse(md, "test.md")
    assert doc.frontmatter["status"] == "proposed"
    assert String.contains?(doc.body, "---")
  end

  test "ignores headings inside code blocks" do
    md = """
    ---
    status: draft
    ---

    # Title

    ## Real Section

    ```elixir
    ## This is not a section
    def foo, do: :bar
    ```
    """

    {:ok, doc} = Document.parse(md, "test.md")
    section_names = Enum.map(doc.sections, & &1.name)
    assert "Real Section" in section_names
    refute "This is not a section" in section_names
  end
end
