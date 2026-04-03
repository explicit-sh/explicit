defmodule Explicit.SystemPrompt do
  @moduledoc """
  System prompt injected when launching AI tools (claude, gemini).
  Teaches the AI about explicit's commands and workflow.
  """

  @doc "Return the system prompt for Claude Code"
  def claude do
    """
    IMPORTANT: This project uses explicit for code quality and decision documentation.

    ## Workflow

    1. Ask 3-5 clarifying questions using AskUserQuestion — NEVER dump questions as text
    2. Wait for answers, then ask follow-up if needed
    3. Use EnterPlanMode for non-trivial changes
    4. Write code WITH tests, @doc, and @spec for every public function
    5. Run `explicit quality --json` before finishing — it must be clean

    ## Commands (run via Bash tool)

    ```
    explicit quality           # Quality gate — must be clean before stopping
    explicit violations        # Code violations (Iron Law checks + @doc/@spec)
    explicit check <file>      # Re-check a specific file
    explicit docs new <type>   # Create doc: adr, opp, pol, inc, spec
    explicit docs validate     # Validate docs against schema
    explicit docs list [type]  # List documents
    explicit docs lint         # Full doc health check
    explicit status            # Server health
    ```

    ## Quality Rules (enforced by Stop hook)

    - Every module in lib/ must have a test file in test/
    - Every public function must have @doc
    - Every public function must have @spec
    - No String.to_atom/1 (use String.to_existing_atom/1)
    - No float for money fields (use Decimal)
    - No raw(variable) in templates (XSS risk)
    - No unsupervised GenServer/Agent.start_link

    ## Suppression

    Add `# explicit:disable RuleName` to suppress a check on the next line.
    At the top of a file (first 5 lines) it suppresses for the whole file.

    ## Decision Documents

    When making architectural choices, create docs:
    - ADR: architecture decisions (use `explicit docs new adr`)
    - OPP: business opportunities
    - SPEC: feature specifications with Gherkin scenarios
    - INC: incident reports
    - POL: policies

    Read CLAUDE.md for project-specific guidelines.
    """
  end

  @doc "Return the system prompt for Gemini"
  def gemini do
    claude()
  end
end
