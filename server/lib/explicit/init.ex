defmodule Explicit.Init do
  @moduledoc """
  Initialize explicit in an existing project.
  Creates .explicit/, .claude/, docs/ structure with schema, hooks, and skills.
  """

  require Logger

  @doc "Initialize explicit in the given directory"
  def run(project_dir) do
    project_dir = Path.expand(project_dir)
    name = Path.basename(project_dir)

    Logger.info("Initializing explicit in #{project_dir}")

    created =
      create_dirs(project_dir) ++
      create_explicit_config(project_dir, name) ++
      create_claude_config(project_dir, name) ++
      create_docs(project_dir, name)

    {:ok, %{project: project_dir, name: name, created: created}}
  end

  defp create_dirs(dir) do
    dirs = ~w(
      docs docs/architecture docs/opportunities docs/policies
      docs/incidents docs/specs docs/processes docs/assets
      .explicit .claude .claude/skills .claude/skills/adr
      .claude/skills/opportunity .claude/skills/incident .claude/skills/spec
      .claude/skills/test
    )

    for d <- dirs do
      path = Path.join(dir, d)
      File.mkdir_p!(path)
    end

    []
  end

  defp create_explicit_config(dir, name) do
    write_if_missing(dir, ".explicit/schema.kdl", schema_kdl()) ++
    write_if_missing(dir, ".explicit/org.kdl", org_kdl(name))
  end

  defp create_claude_config(dir, name) do
    write_if_missing(dir, ".claude/settings.json", claude_settings()) ++
    write_if_missing(dir, ".claude/skills/adr/skill.md", skill_adr()) ++
    write_if_missing(dir, ".claude/skills/opportunity/skill.md", skill_opp()) ++
    write_if_missing(dir, ".claude/skills/incident/skill.md", skill_inc()) ++
    write_if_missing(dir, ".claude/skills/spec/skill.md", skill_spec(name)) ++
    write_if_missing(dir, ".claude/skills/test/skill.md", skill_test())
  end

  defp create_docs(dir, name) do
    write_if_missing(dir, "docs/README.md", docs_readme(name))
  end

  defp write_if_missing(dir, rel_path, content) do
    path = Path.join(dir, rel_path)

    if File.exists?(path) do
      []
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      [rel_path]
    end
  end

  # ─── Templates ─────────────────────────────────────────────────────────────

  defp schema_kdl do
    # Use full schema from priv if available, otherwise embedded
    case File.read(Path.join(:code.priv_dir(:explicit), "schema.kdl")) do
      {:ok, content} -> content
      _ -> embedded_schema_kdl()
    end
  end

  defp embedded_schema_kdl do
    ~S"""
    relation "supersedes" inverse="superseded_by" cardinality="one"
    relation "implements" inverse="implemented_by" cardinality="many"
    relation "depends_on" inverse="dependency_of" cardinality="many"
    relation "related" cardinality="many"

    type "adr" description="Architecture Decision Record" folder="docs/architecture" {
        alias "architecture"
        field "status" type="enum" required=#true default="proposed" {
            values "proposed" "accepted" "rejected" "deprecated" "superseded"
        }
        field "author" type="user" required=#true
        field "date" type="string" required=#true pattern="^\\d{4}-\\d{2}-\\d{2}$" default="$TODAY"
        field "tags" type="string[]"
        field "code_paths" type="string[]"
        section "Context" required=#true
        section "Decision" required=#true
        section "Consequences" required=#true {
            section "Positive" required=#true
            section "Negative"
        }
    }

    type "opp" description="Opportunity" folder="docs/opportunities" {
        alias "opportunity"
        field "status" type="enum" required=#true default="identified" {
            values "identified" "validating" "pursuing" "completed" "deprecated"
        }
        field "author" type="user" required=#true
        field "date" type="string" required=#true pattern="^\\d{4}-\\d{2}-\\d{2}$" default="$TODAY"
        field "tags" type="string[]"
        section "Description" required=#true
    }

    type "inc" description="Incident Report" folder="docs/incidents" {
        alias "incident"
        field "status" type="enum" required=#true default="open" {
            values "open" "mitigated" "resolved"
        }
        field "severity" type="enum" required=#true {
            values "sev1" "sev2" "sev3" "sev4"
        }
        field "author" type="user" required=#true
        field "date" type="string" required=#true pattern="^\\d{4}-\\d{2}-\\d{2}$" default="$TODAY"
        section "Summary" required=#true
        section "Root Cause" required=#true
    }

    type "spec" description="Behavioral Specification" folder="docs/specs" {
        alias "feature"
        field "status" type="enum" required=#true default="draft" {
            values "draft" "proposed" "approved" "implemented" "deprecated"
        }
        field "author" type="user" required=#true
        field "date" type="string" required=#true pattern="^\\d{4}-\\d{2}-\\d{2}$" default="$TODAY"
        section "Story" required=#true
        section "Scenarios" required=#true
    }
    """
  end

  defp org_kdl(name) do
    """
    // Organization registry for #{name}
    // Users referenced in doc frontmatter (author, owner) must exist here.

    org "#{name}" {
      team "engineering" {
        // user "onni" name="Onni Hakala"
      }
    }
    """
  end

  defp claude_settings do
    Jason.encode!(%{
      "hooks" => %{
        "PostToolUse" => [%{
          "matcher" => "^(Edit|Write)$",
          "hooks" => [%{"type" => "command", "command" => "explicit hooks claude check-fixme"}]
        }],
        "Stop" => [%{
          "hooks" => [%{"type" => "command", "command" => "explicit hooks claude stop"}]
        }]
      }
    }, pretty: true) <> "\n"
  end

  defp skill_adr do
    """
    # Architecture Decision Record

    Create an ADR when making a significant technical choice.

    ## Workflow

    1. Ask 3-5 clarifying questions using AskUserQuestion:
       - What problem does this solve?
       - What alternatives were considered?
       - What are the constraints?

    2. Check existing docs: `explicit docs list adr`

    3. Create the ADR:
       ```bash
       explicit docs new adr "Decision Title"
       ```

    4. Edit the generated file to fill in Context, Decision, Consequences

    5. Validate: `explicit docs validate`

    ## Required sections: Context, Decision, Consequences (Positive + Negative)
    """
  end

  defp skill_opp do
    """
    # Opportunity

    Create an OPP when identifying a business opportunity or feature request.

    ## Workflow

    1. Ask clarifying questions:
       - What outcome are we trying to achieve?
       - Who benefits from this?
       - What does success look like?
       - What are the risks?

    2. Create: `explicit docs new opp "Opportunity Title"`

    3. Fill in Description, Impact, Success Metrics
    """
  end

  defp skill_inc do
    """
    # Incident Report

    Create an INC for post-mortems and incident tracking.

    ## Workflow

    1. Ask brief clarifying questions (incidents need speed):
       - What happened?
       - What was the severity?
       - When did it start/end?

    2. Create: `explicit docs new inc "Incident Title"`

    3. Fill in Summary, Timeline, Root Cause, Action Items
    """
  end

  defp skill_spec(name) do
    _ = name
    """
    # Behavioral Specification

    Create a SPEC for feature requirements with Gherkin scenarios.

    ## Workflow

    1. Ask clarifying questions:
       - Who is the user? (As a...)
       - What do they want? (I want to...)
       - Why? (So that...)
       - What are the edge cases?

    2. Create: `explicit docs new spec "Feature Title"`

    3. Write Story section and Gherkin scenarios
    """
  end

  defp skill_test do
    """
    # Writing Tests

    Every module in lib/ must have a corresponding test in test/.

    ## Workflow

    1. When creating `lib/my_app/accounts.ex`, also create `test/my_app/accounts_test.exs`

    2. Test structure:
       ```elixir
       defmodule MyApp.AccountsTest do
         use MyApp.DataCase  # or ExUnit.Case for non-DB modules

         describe "function_name/arity" do
           test "happy path" do
             # ...
           end

           test "error case" do
             # ...
           end
         end
       end
       ```

    3. Run tests: `mix test`
    4. Check coverage: `explicit quality --json`

    ## Rules
    - Every public function should have at least one test
    - Test the happy path AND error cases
    - Use `describe` blocks to group tests by function
    - Use factories or fixtures, not hardcoded data
    """
  end

  defp docs_readme(name) do
    """
    ---
    ---

    # #{name}

    ## Architecture

    ```mermaid
    graph TD
        Client[Browser/Mobile] --> LB[Load Balancer]
        LB --> Phoenix[Phoenix App]
        Phoenix --> DB[(PostgreSQL)]
    ```

    ## Risks

    > **Data Loss** — Ensure regular backups and test restore procedures.

    ## License

    Proprietary. All rights reserved.
    """
  end
end
