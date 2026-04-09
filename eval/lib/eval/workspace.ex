defmodule Eval.Workspace do
  @moduledoc "Create temporary project workspaces for eval runs."

  require Logger

  @doc "Create a temp project with explicit init, return workspace path"
  def create(name \\ "eval_project") do
    base = Path.join(System.tmp_dir!(), "explicit_eval_#{:rand.uniform(999999)}")
    File.mkdir_p!(base)

    project_dir = Path.join(base, name)

    # Find explicit binary
    explicit = find_explicit()

    # Create project with explicit init <name>
    Logger.info("Running: #{explicit} init #{name}")
    {output, code} = System.cmd(explicit, ["init", name], cd: base, stderr_to_stdout: true)
    if code != 0, do: Logger.warning("explicit init exit #{code}: #{output}")

    # Create docs directories (explicit init <name> creates these but let's be safe)
    for dir <- ~w(docs docs/architecture docs/opportunities docs/specs .explicit .claude .codex) do
      File.mkdir_p!(Path.join(project_dir, dir))
    end

    # Write CLAUDE.md teaching Claude the workflow
    write_claude_md(project_dir, name)

    # Write Claude and Codex hook config
    write_agent_settings(project_dir)

    # Write schema for doc validation
    write_schema(project_dir)

    # Configure git (no signing, dummy user)
    System.cmd("git", ["config", "user.name", "eval"], cd: project_dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "eval@localhost"], cd: project_dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "commit.gpgsign", "false"], cd: project_dir, stderr_to_stdout: true)

    # Create initial commit (Claude Code requires it)
    System.cmd("git", ["add", "-A"], cd: project_dir, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "Initial commit", "--no-gpg-sign"],
      cd: project_dir, stderr_to_stdout: true)

    project_dir
  end

  defp write_claude_md(dir, name) do
    content = """
    # #{name}

    This project uses explicit for code quality and decision documentation.

    ## MANDATORY Workflow

    1. **Ask questions first** — use AskUserQuestion tool, never dump text
    2. **Create docs before code** — run `explicit docs new opp/adr/spec "Title"`
    3. **Write tests first** — red/green TDD
    4. **Reference docs in code** — `@moduledoc "Implements OPP-001"`, `# See ADR-001`
    5. **Quality gate** — `explicit quality --json` must be clean

    ## Commands

    ```bash
    explicit docs new opp "Title"    # Create opportunity doc
    explicit docs new adr "Title"    # Create architecture decision
    explicit docs new spec "Title"   # Create specification with Gherkin
    explicit docs validate           # Validate — must pass before coding
    explicit quality --json          # Quality gate — must be clean
    ```

    ## Rules

    - Every module needs a test file
    - Every public function needs @doc and @spec
    - Doc IDs (OPP-001, ADR-001) must appear in @moduledoc
    - No String.to_atom, no float for money, no raw(variable)
    """

    File.write!(Path.join(dir, "CLAUDE.md"), content)
  end

  defp write_agent_settings(dir) do
    claude_settings = Jason.encode!(%{
      "hooks" => %{
        "Stop" => [%{
          "hooks" => [%{
            "type" => "command",
            "command" => "explicit hooks claude stop"
          }]
        }]
      }
    }, pretty: true)

    codex_hooks = Jason.encode!(%{
      "hooks" => %{
        "PostToolUse" => [%{
          "matcher" => "Bash",
          "hooks" => [
            %{"type" => "command", "command" => "explicit hooks codex check-fixme"},
            %{"type" => "command", "command" => "explicit hooks codex check-code"}
          ]
        }],
        "Stop" => [%{
          "hooks" => [%{
            "type" => "command",
            "command" => "explicit hooks codex stop",
            "timeout" => 30
          }]
        }]
      }
    }, pretty: true)

    File.mkdir_p!(Path.join(dir, ".claude"))
    File.mkdir_p!(Path.join(dir, ".codex"))
    File.write!(Path.join(dir, ".claude/settings.json"), claude_settings <> "\n")
    File.write!(Path.join(dir, ".codex/hooks.json"), codex_hooks <> "\n")
    File.write!(Path.join(dir, ".codex/config.toml"), "[features]\ncodex_hooks = true\n")
  end

  defp write_schema(dir) do
    schema = """
    relation "implements" inverse="implemented_by" cardinality="many"
    relation "depends_on" inverse="dependency_of" cardinality="many"

    type "adr" description="Architecture Decision Record" folder="docs/architecture" {
        field "status" type="enum" required=#true default="proposed" {
            values "proposed" "accepted" "rejected" "deprecated"
        }
        field "author" type="user" required=#true
        field "date" type="string" required=#true default="$TODAY"
        section "Context" required=#true
        section "Decision" required=#true
        section "Consequences" required=#true
    }

    type "opp" description="Opportunity" folder="docs/opportunities" {
        field "status" type="enum" required=#true default="identified" {
            values "identified" "validating" "pursuing" "completed"
        }
        field "author" type="user" required=#true
        field "date" type="string" required=#true default="$TODAY"
        section "Description" required=#true
    }

    type "spec" description="Specification" folder="docs/specs" {
        field "status" type="enum" required=#true default="draft" {
            values "draft" "proposed" "approved" "implemented"
        }
        field "author" type="user" required=#true
        field "date" type="string" required=#true default="$TODAY"
        section "Story" required=#true
        section "Scenarios" required=#true
    }
    """

    File.mkdir_p!(Path.join(dir, ".explicit"))
    File.write!(Path.join(dir, ".explicit/schema.kdl"), schema)
  end

  defp find_explicit do
    candidates = [
      Path.expand("../../../debug/explicit", __DIR__),
      Path.expand("../../../cli/explicit", __DIR__),
      "explicit"
    ]

    Enum.find(candidates, "explicit", &File.exists?/1)
  end
end
