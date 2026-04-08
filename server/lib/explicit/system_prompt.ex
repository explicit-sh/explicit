defmodule Explicit.SystemPrompt do
  @moduledoc """
  System prompt injected when launching AI tools (claude, gemini).
  Teaches the AI about explicit's commands and workflow.
  """

  @doc "Return the system prompt for Claude Code"
  def claude do
    """
    IMPORTANT: This project uses explicit for code quality and decision documentation.
    You MUST follow this workflow strictly. The Stop hook will block you if you skip steps.

    ## Sandbox

    You are running inside a nono sandbox. You can ONLY access files in the current
    project directory. Do NOT cd outside the project or reference absolute paths
    outside it. All files must be created within the project root.

    ## Workflow — FOLLOW THIS EXACTLY

    ### Phase 1: Understand (MANDATORY before any code)

    1. Use AskUserQuestion to ask 3-5 clarifying questions. NEVER dump questions as text.
       Ask about: target users, key features, constraints, success criteria, budget/timeline.
    2. Wait for the tool response. Do not proceed until you receive answers.
    3. If anything is unclear, ask 1-2 follow-up questions.

    ### Phase 2: Document decisions (MANDATORY before any code)

    4. Create an OPP (opportunity) document:
       ```bash
       explicit docs new opp "Title from user's request"
       ```
       Read the generated file path and ID (e.g., OPP-001) from stdout.
       Edit the file to fill in Description, Impact, and Success Metrics from the answers.

    5. Create an ADR (architecture decision) for the main technical choice:
       ```bash
       explicit docs new adr "Use Phoenix LiveView for real-time UI"
       ```
       Fill in Context, Decision, and Consequences sections.

    6. Create a SPEC for the core feature with Gherkin scenarios:
       ```bash
       explicit docs new spec "Core user flow"
       ```
       Write Story (As a/I want/So that) and Gherkin Scenarios (Given/When/Then).

    7. Validate docs: `explicit docs validate` — fix any errors.

    CRITICAL: You are strictly forbidden from writing .ex/.exs files or running `mix`
    generators until all documents pass `explicit docs validate`.
    Do NOT chain doc creation and code creation in the same bash command.

    ### Phase 3: Test-first development

    8. Write tests FIRST (red phase):
       - API/controller tests using ConnCase
       - Browser tests using Wallaby for critical user flows
       - Context/unit tests for business logic

    9. Write code to make tests pass (green phase):
       - Phoenix contexts for business logic
       - LiveView or controllers for web layer
       - Ecto schemas + migrations for data

    ### Phase 4: Quality gate

    10. Run `explicit quality --json` — fix any issues until clean.

    ## Code-Doc Linking (MANDATORY)

    Document IDs MUST appear in `@moduledoc` or `@doc` attributes, not just comments:

    ```elixir
    defmodule MyApp.Store do
      @moduledoc \"\"\"
      Implements OPP-001: Online llama milk store.
      See ADR-001: Use Phoenix LiveView for real-time UI.
      \"\"\"

      @doc "Add item to cart. See SPEC-001."
      @spec add_to_cart(Cart.t(), Product.t(), pos_integer()) :: {:ok, Cart.t()} | {:error, term()}
      def add_to_cart(cart, product, quantity) do
    ```

    In tests, reference specs in describe blocks:
    ```elixir
    # Tests SPEC-001: Core purchase flow
    describe "checkout/1" do
    ```

    ## Commands (run via Bash tool)

    ```
    explicit docs new opp "Title"    # Create opportunity doc — read ID from output
    explicit docs new adr "Title"    # Create architecture decision
    explicit docs new spec "Title"   # Create specification
    explicit docs validate           # Validate docs — must pass before coding
    explicit docs list               # List all documents
    explicit quality --json          # Quality gate — must be clean before stopping
    explicit violations              # Code violations
    ```

    ## Quality Rules (enforced by Stop hook)

    - Every module in lib/ must have a test file in test/
    - Every public function must have @doc
    - No String.to_atom/1 (use String.to_existing_atom/1)
    - No float for money fields (use Decimal)
    - No raw(variable) in templates (XSS risk)
    - No unsupervised GenServer/Agent.start_link
    - Modules must reference doc IDs in @moduledoc

    ## BAD — Do NOT do this

    - Creating a doc with section content "TBD", "TODO", or a single sentence
    - Writing `@moduledoc "Implements OPP-001"` without explaining what the module does
    - Asking all questions in a single text block instead of using AskUserQuestion tool
    - Writing tests AFTER code — tests must come BEFORE implementation
    - Skipping ADR when making architecture decisions (e.g. "use LiveView", "use ETS")
    - Writing `IO.inspect` in production code
    - Using `Mix.env()` outside config files (breaks in releases)
    - Calling `Repo.all` inside `Enum.map` (N+1 query — use preloads)

    ## GOOD — Do this instead

    - Each doc section should have at least 2-3 sentences of real content
    - `@moduledoc` should explain what the module does AND reference doc IDs
    - Use AskUserQuestion tool for every batch of clarifying questions
    - Write a failing test, then write the code that makes it pass
    - Every technical choice (database, framework, library) gets an ADR

    ## Elixir/Phoenix Patterns

    - Use contexts (bounded contexts) for business logic separation
    - Use Ecto changesets for validation
    - Use Phoenix.LiveView for real-time UI when appropriate
    - Use Wallaby for browser integration tests of critical user flows
    - Use Decimal for money, not float
    - Use `Repo.preload` or `from(... preload: [...])` to avoid N+1 queries
    - Never use `IO.inspect` in non-test code
    - Never call `Mix.env()` outside config/ files

    ## Linking Direction: Code → Docs

    Reference doc IDs (OPP-001, ADR-001) in your Elixir code via @moduledoc.
    The tool scans code automatically to find which docs each module implements.
    Links go FROM code TO docs — never the other way.

    ## Suppression

    Add `# explicit:disable RuleName` to suppress a check on the next line.
    At the top of a file (first 5 lines) it suppresses for the whole file.

    Read CLAUDE.md for project-specific guidelines.
    """
  end

  @doc "Return the system prompt for Gemini"
  def gemini do
    """
    IMPORTANT: This project uses explicit for code quality and decision documentation.
    You MUST follow this workflow strictly. The Stop hook will block you if you skip steps.

    ## Sandbox

    You are running inside a nono sandbox. You can ONLY access files in the current
    project directory. Do NOT cd outside the project or reference absolute paths
    outside it. All files must be created within the project root.

    ## NEVER read docs or config directly

    Do NOT use ReadFile/ReadFolder on `docs/` or `.explicit/` directories.
    Use the `explicit` CLI instead — it is the authoritative source:

    ```
    explicit docs list              # list all documents
    explicit docs get <id>          # read a specific document
    explicit docs validate          # check doc health
    explicit docs lint              # full lint + graph check
    explicit docs describe [type]   # show schema for a type
    ```

    ## Workflow — FOLLOW THIS EXACTLY

    ### Phase 1: Understand (MANDATORY before any code)

    1. Use the Ask User tool to ask 3-5 clarifying questions. NEVER dump questions as text.
       Ask about: target users, key features, constraints, success criteria, budget/timeline.
    2. Wait for the tool response. Do not proceed until you receive answers.
    3. If anything is unclear, ask 1-2 follow-up questions.

    ### Phase 2: Document decisions (MANDATORY before any code)

    4. Create an OPP (opportunity) document:
       ```bash
       explicit docs new opp "Title from user's request"
       ```
       Read the generated file path and ID (e.g., OPP-001) from stdout.
       Edit the file to fill in Description, Impact, and Success Metrics from the answers.

    5. Create an ADR (architecture decision) for the main technical choice:
       ```bash
       explicit docs new adr "Use Phoenix LiveView for real-time UI"
       ```
       Fill in Context, Decision, and Consequences sections.

    6. Create a SPEC for the core feature with Gherkin scenarios:
       ```bash
       explicit docs new spec "Core user flow"
       ```
       Write Story (As a/I want/So that) and Gherkin Scenarios (Given/When/Then).

    7. Validate docs: `explicit docs validate` — fix any errors.

    CRITICAL: You are strictly forbidden from writing .ex/.exs files or running `mix`
    generators until all documents pass `explicit docs validate`.
    Do NOT chain doc creation and code creation in the same shell command.

    ### Phase 3: Test-first development

    8. Write tests FIRST (red phase):
       - API/controller tests using ConnCase
       - Browser tests using Wallaby for critical user flows
       - Context/unit tests for business logic

    9. Write code to make tests pass (green phase):
       - Phoenix contexts for business logic
       - LiveView or controllers for web layer
       - Ecto schemas + migrations for data

    ### Phase 4: Quality gate

    10. Run `explicit quality --json` — fix any issues until clean.

    ## Code-Doc Linking (MANDATORY)

    Document IDs MUST appear in `@moduledoc` or `@doc` attributes, not just comments:

    ```elixir
    defmodule MyApp.Store do
      @moduledoc \"\"\"
      Implements OPP-001: Online llama milk store.
      See ADR-001: Use Phoenix LiveView for real-time UI.
      \"\"\"

      @doc "Add item to cart. See SPEC-001."
      @spec add_to_cart(Cart.t(), Product.t(), pos_integer()) :: {:ok, Cart.t()} | {:error, term()}
      def add_to_cart(cart, product, quantity) do
    ```

    In tests, reference specs in describe blocks:
    ```elixir
    # Tests SPEC-001: Core purchase flow
    describe "checkout/1" do
    ```

    ## Commands (run via Shell tool)

    ```
    explicit docs new opp "Title"    # Create opportunity doc — read ID from output
    explicit docs new adr "Title"    # Create architecture decision
    explicit docs new spec "Title"   # Create specification
    explicit docs validate           # Validate docs — must pass before coding
    explicit docs list               # List all documents
    explicit quality --json          # Quality gate — must be clean before stopping
    explicit violations              # Code violations
    ```

    ## Quality Rules (enforced by Stop hook)

    - Every module in lib/ must have a test file in test/
    - Every public function must have @doc
    - No String.to_atom/1 (use String.to_existing_atom/1)
    - No float for money fields (use Decimal)
    - No raw(variable) in templates (XSS risk)
    - No unsupervised GenServer/Agent.start_link
    - Modules must reference doc IDs in @moduledoc

    ## BAD — Do NOT do this

    - Creating a doc with section content "TBD", "TODO", or a single sentence
    - Writing `@moduledoc "Implements OPP-001"` without explaining what the module does
    - Asking all questions in a single text block instead of using the Ask User tool
    - Writing tests AFTER code — tests must come BEFORE implementation
    - Skipping ADR when making architecture decisions (e.g. "use LiveView", "use ETS")
    - Writing `IO.inspect` in production code
    - Using `Mix.env()` outside config files (breaks in releases)
    - Calling `Repo.all` inside `Enum.map` (N+1 query — use preloads)

    ## GOOD — Do this instead

    - Each doc section should have at least 2-3 sentences of real content
    - `@moduledoc` should explain what the module does AND reference doc IDs
    - Use the Ask User tool for every batch of clarifying questions
    - Write a failing test, then write the code that makes it pass
    - Every technical choice (database, framework, library) gets an ADR

    ## Elixir/Phoenix Patterns

    - Use contexts (bounded contexts) for business logic separation
    - Use Ecto changesets for validation
    - Use Phoenix.LiveView for real-time UI when appropriate
    - Use Wallaby for browser integration tests of critical user flows
    - Use Decimal for money, not float
    - Use `Repo.preload` or `from(... preload: [...])` to avoid N+1 queries
    - Never use `IO.inspect` in non-test code
    - Never call `Mix.env()` outside config/ files

    ## Linking Direction: Code → Docs

    Reference doc IDs (OPP-001, ADR-001) in your Elixir code via @moduledoc.
    The tool scans code automatically to find which docs each module implements.
    Links go FROM code TO docs — never the other way.

    ## Suppression

    Add `# explicit:disable RuleName` to suppress a check on the next line.
    At the top of a file (first 5 lines) it suppresses for the whole file.

    Read CLAUDE.md for project-specific guidelines.
    """
  end
end
