defmodule Explicit.Init do
  @moduledoc """
  Initialize explicit in an existing project.
  Creates .explicit/, .claude/, docs/ structure with schema, hooks, and skills.
  """

  require Logger

  @doc "Create a new project directory, git init it, then initialize explicit"
  def run_new(project_dir, name) do
    project_dir = Path.expand(project_dir)
    File.mkdir_p!(project_dir)

    # git init
    System.cmd("git", ["init"], cd: project_dir, stderr_to_stdout: true)

    Logger.info("Creating new project #{name} in #{project_dir}")

    created =
      create_dirs(project_dir) ++
      create_explicit_config(project_dir, name) ++
      create_claude_config(project_dir, name) ++
      create_docs(project_dir, name) ++
      create_lsp_config(project_dir) ++
      create_devenv(project_dir, name)

    {:ok, %{project: project_dir, name: name, created: created}}
  end

  @doc "Initialize explicit in the given directory"
  def run(project_dir) do
    project_dir = Path.expand(project_dir)
    name = Path.basename(project_dir)

    Logger.info("Initializing explicit in #{project_dir}")

    created =
      create_dirs(project_dir) ++
      create_explicit_config(project_dir, name) ++
      create_claude_config(project_dir, name) ++
      create_docs(project_dir, name) ++
      create_lsp_config(project_dir) ++
      create_devenv(project_dir, name)

    {:ok, %{project: project_dir, name: name, created: created}}
  end

  defp create_dirs(dir) do
    dirs = ~w(
      docs docs/architecture docs/opportunities docs/policies
      docs/incidents docs/specs docs/processes docs/assets
      .explicit .claude .claude/skills .claude/skills/adr
      .claude/skills/opportunity .claude/skills/incident .claude/skills/spec
      .claude/skills/test .claude/skills/elixir-quality .claude/skills/phoenix-patterns
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
    write_if_missing(dir, ".claude/skills/test/skill.md", skill_test()) ++
    write_if_missing(dir, ".claude/skills/elixir-quality/skill.md", skill_elixir_quality()) ++
    write_if_missing(dir, ".claude/skills/phoenix-patterns/skill.md", skill_phoenix_patterns())
  end

  defp create_docs(dir, name) do
    write_if_missing(dir, "docs/README.md", docs_readme(name))
  end

  defp create_lsp_config(dir) do
    write_if_missing(dir, ".lsp.json", lsp_json())
  end

  defp create_devenv(dir, name) do
    write_if_missing(dir, "devenv.nix", devenv_nix(name))
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
          "hooks" => [
            %{"type" => "command", "command" => "explicit hooks claude check-fixme"},
            %{"type" => "command", "command" => "explicit hooks claude check-code"}
          ]
        }],
        "Stop" => [%{
          "hooks" => [%{"type" => "command", "command" => "explicit hooks claude stop"}]
        }]
      }
    }, pretty: true) <> "\n"
  end

  defp skill_adr do
    ~S"""
    # Architecture Decision Record

    ## Iron Law

    ```
    EVERY TECHNICAL CHOICE GETS A RECORD
    ```

    Database, framework, library, caching strategy, API design — if you're choosing
    between alternatives, write an ADR. Future-you will thank present-you.

    ## Workflow

    1. Ask what PROBLEM triggers this decision (not what solution to pick)
    2. Ask what alternatives were considered and rejected
    3. Check existing ADRs: `explicit docs list adr`
    4. Create: `explicit docs new adr "Problem-focused title"`
    5. Fill Context (≥30 words: problem statement + constraints)
    6. Fill Decision (rationale: WHY this choice, not just WHAT)
    7. Fill Consequences — BOTH Positive AND Negative (balance required)
    8. Validate: `explicit docs validate`

    ## Example

    ```markdown
    # Cache session data for sub-millisecond reads

    ## Context
    The store processes 500 orders/hour. Each page load queries the session
    table. PostgreSQL handles this fine now but latency spikes during peak
    hours (Saturday 8-12am) suggest we'll hit limits at 2x current volume.

    ## Decision
    Use ETS for session caching because it provides sub-millisecond reads
    without external dependencies. Redis was considered but adds operational
    complexity we can't justify at current scale.

    ## Consequences
    ### Positive
    - Sub-millisecond reads vs 2-5ms PostgreSQL queries
    - No external dependency (ETS is built into the BEAM)

    ### Negative
    - Session data lost on node restart (acceptable — sessions are short-lived)
    - No cross-node session sharing (single-node deployment for now)
    ```

    ## Red Flags — STOP and Re-read

    - Title is solution-focused ("Use Redis") instead of problem-focused ("Cache session data")
    - Context says "we need to decide" without stating the actual problem
    - Decision has no rationale ("Use PostgreSQL" — but WHY?)
    - Consequences only has Positive (where's the trade-off?)
    - Section content is < 2 sentences (add real detail)
    """
  end

  defp skill_opp do
    ~S"""
    # Opportunity

    ## Iron Law

    ```
    VALIDATE BEFORE YOU BUILD
    ```

    Every feature request starts as an opportunity. Understand the problem and
    success criteria BEFORE writing any code.

    ## Workflow

    1. Ask: What outcome are we trying to achieve?
    2. Ask: Who benefits and how will we measure success?
    3. Ask: What are the risks and constraints?
    4. Create: `explicit docs new opp "Opportunity Title"`
    5. Fill Description (≥30 words: what + why it matters)
    6. Fill Success Metrics (measurable KPIs)
    7. Validate: `explicit docs validate`

    ## Example

    ```markdown
    # Online llama milk subscription service

    ## Description
    Health-conscious consumers want regular llama milk delivery but our farm
    only sells at weekly markets. An online subscription service would reach
    customers beyond our local area and provide predictable revenue.

    ## Impact
    - Expand customer base from 50 local buyers to potentially 500+ nationwide
    - Predictable monthly revenue vs. variable market sales

    ## Success Metrics
    - 100 subscribers within 3 months of launch
    - 80% month-over-month retention rate
    - Average order value > $45
    ```

    ## Red Flags — STOP and Re-read

    - Building features before creating an OPP (validate first!)
    - No success metrics (how will you know it worked?)
    - Description is a solution ("build a website") not a problem ("customers can't order online")
    """
  end

  defp skill_inc do
    ~S"""
    # Incident Report

    ## Iron Law

    ```
    DOCUMENT WHILE IT'S FRESH
    ```

    Write the incident report during or immediately after the incident.
    Memory fades fast. Details matter.

    ## Workflow

    1. Ask briefly: What happened? What was the severity? When?
    2. Create immediately: `explicit docs new inc "Brief description"`
    3. Fill Summary (what happened in 2-3 sentences)
    4. Fill Timeline (table: Time | Event | Actor)
    5. Fill Root Cause (5 Whys if needed)
    6. Fill Action Items (table: Status | Action | Owner)

    ## Example Timeline

    | Time | Event | Actor |
    |------|-------|-------|
    | 14:30 | Monitoring alert: API latency >2s | PagerDuty |
    | 14:35 | Identified: connection pool exhausted | @onni |
    | 14:40 | Increased pool size from 10 to 50 | @onni |
    | 14:42 | Latency returned to normal | - |

    ## Red Flags — STOP and Re-read

    - Incident without timeline (when did things happen?)
    - No root cause analysis (why did it happen?)
    - No action items (how do we prevent recurrence?)
    - Writing report days later (details are lost)
    """
  end

  defp skill_spec(name) do
    _ = name
    ~S"""
    # Behavioral Specification

    ## Iron Law

    ```
    EVERY FEATURE STARTS AS A STORY
    ```

    Write the spec before the code. The spec drives what tests to write.
    Tests drive what code to write. Story → Spec → Tests → Code.

    ## Workflow

    1. Ask: Who is the user? (As a...)
    2. Ask: What do they want? (I want to...)
    3. Ask: Why? (So that...)
    4. Ask: What are the edge cases?
    5. Create: `explicit docs new spec "Feature Title"`
    6. Write Story (As a / I want / So that)
    7. Write Gherkin Scenarios (Given / When / Then)
    8. Validate: `explicit docs validate`

    ## Example

    ```markdown
    ## Story

    As a llama milk customer,
    I want to add products to a shopping cart,
    So that I can purchase multiple items in one order.

    ## Scenarios

    ```gherkin
    Scenario: Add product to empty cart
      Given I am on the product page for "Fresh Llama Milk 1L"
      And my cart is empty
      When I click "Add to Cart"
      Then my cart should contain 1 item
      And the cart total should be "$12.99"

    Scenario: Add product that is out of stock
      Given I am on the product page for "Aged Llama Cheese"
      And the product has 0 inventory
      When I click "Add to Cart"
      Then I should see "Out of stock"
      And my cart should remain unchanged
    ```

    ## Red Flags — STOP and Re-read

    - Writing code before the spec exists
    - Scenarios without "Then" (what's the expected outcome?)
    - Story without "So that" (what's the value?)
    - Only happy path scenarios (where are the edge cases?)
    """
  end

  defp skill_test do
    ~S"""
    # Writing Tests

    ## Iron Law

    ```
    TESTS BEFORE CODE. ALWAYS.
    ```

    Write the failing test first (red). Then write code to make it pass (green).
    Then refactor. Never write implementation before tests.

    ## Workflow

    1. Read the SPEC document for the feature
    2. Create test file: `test/my_app/context_name_test.exs`
    3. Write describe blocks matching SPEC scenarios
    4. Write failing tests (red phase)
    5. Write implementation to make tests pass (green phase)
    6. Run: `mix test`
    7. Check: `explicit quality --json`

    ## Patterns

    **Use pattern matching over imperative assertions:**
    ```elixir
    # BAD
    assert length(products) == 2
    assert Enum.at(products, 0).name == "Milk"

    # GOOD
    assert [%{name: "Milk"}, %{name: "Cheese"}] = products
    ```

    **Test behavior, not implementation:**
    ```elixir
    # BAD — tests internal GenServer state
    assert :sys.get_state(pid).count == 5

    # GOOD — tests the public API
    assert Cart.item_count(cart) == 5
    ```

    **Reference doc IDs:**
    ```elixir
    # Tests SPEC-001: Shopping cart
    describe "add_to_cart/3" do
      test "adds product to empty cart" do
        # ...
      end
    end
    ```

    ## Red Flags — STOP and Re-read

    - Writing implementation BEFORE tests
    - Tests with no assertions (test "does something" do end)
    - Testing private functions directly
    - Testing framework behavior (Ecto, Phoenix) not your code
    - `assert length(list) == N` instead of pattern matching
    - All tests `async: false` (fix shared state coupling)
    """
  end

  defp skill_elixir_quality do
    ~S"""
    # Elixir Quality

    ## Iron Law

    ```
    CODE VIOLATIONS BLOCK DEPLOYMENT
    ```

    The explicit quality gate runs automatically via Claude Code's Stop hook.
    You cannot finish until all violations are fixed (or explicitly suppressed).

    ## Checks (15 total)

    | Check | Detects |
    |-------|---------|
    | NoStringToAtom | `String.to_atom/1` — atom table exhaustion |
    | NoFloatForMoney | `:float` on money fields — use Decimal |
    | NoRawWithVariable | `raw(variable)` — XSS risk |
    | NoImplicitCrossJoin | Multiple `in` in Ecto `from()` |
    | NoBareStartLink | Unsupervised GenServer/Agent |
    | NoAssignNewForMountValues | `assign_new` for per-mount keys |
    | NoPublicWithoutDoc | Public functions missing @doc |
    | NoPublicWithoutSpec | Public functions missing @spec |
    | NoIOInspect | `IO.inspect` in production code |
    | NoMixEnvInRuntime | `Mix.env()` outside config/ |
    | NoDbQueryInMount | Database queries in LiveView mount/3 |
    | NoListAppend | `list ++ [item]` — O(n), use prepend |
    | NoRepoDeleteAll | `Repo.delete_all` without scoped query |
    | NoCompileTimeAppConfig | `Application.get_env` in module attribute |
    | NoModuleWithoutTest | Modules without test files |

    ## Commands

    ```
    explicit quality --json    # Full quality gate report
    explicit validate          # Docs + code validation
    explicit violations        # Just code violations
    explicit check <file>      # Check single file
    ```

    ## Suppression

    ```elixir
    # explicit:disable NoPublicWithoutDoc
    def internal_helper(x), do: x
    ```

    At top of file (first 5 lines) → suppresses for whole file.
    Must specify rule name — blanket suppression not allowed.

    ## Red Flags — STOP and Re-read

    - Adding `# explicit:disable` without a good reason
    - Ignoring quality gate output and trying to stop anyway
    - Suppressing NoPublicWithoutDoc on public API functions
    """
  end

  defp skill_phoenix_patterns do
    ~S"""
    # Phoenix Patterns

    ## Iron Law

    ```
    NO DATABASE QUERIES IN MOUNT
    ```

    mount/3 is called TWICE (HTTP request + WebSocket). Queries in mount = duplicate queries.

    ```elixir
    # BAD — runs twice
    def mount(_params, _session, socket) do
      posts = Blog.list_posts()  # Called twice!
      {:ok, assign(socket, posts: posts)}
    end

    # GOOD — runs once per navigation
    def mount(_params, _session, socket) do
      {:ok, assign(socket, posts: [], loading: true)}
    end

    def handle_params(_params, _uri, socket) do
      posts = Blog.list_posts()  # Called once
      {:noreply, assign(socket, posts: posts, loading: false)}
    end
    ```

    ## Key Patterns

    **Contexts are boundaries:**
    - Each context owns its schemas
    - Cross-context references by ID only, never by struct
    - Controllers/LiveViews call context functions, never Repo directly

    **Streams for large collections (100+ items):**
    ```elixir
    stream(socket, :messages, Chat.list_messages())
    ```
    Items sent to client and discarded — constant server memory.

    **Wallaby for browser tests:**
    ```elixir
    test "user can add to cart", %{session: session} do
      session
      |> visit("/products")
      |> click(link("Fresh Milk"))
      |> click(button("Add to Cart"))
      |> assert_has(css(".cart-count", text: "1"))
    end
    ```

    ## Red Flags — STOP and Re-read

    - Database query in mount/3 (use handle_params/3)
    - `IO.inspect` in production code (remove it)
    - `Mix.env()` outside config/ (crashes in releases)
    - `Repo.delete_all(Schema)` without a where clause
    - `list ++ [item]` instead of `[item | list]`
    - Controller calling Repo directly (use context)
    """
  end

  defp devenv_nix(name) do
    """
    { pkgs, lib, config, inputs, ... }:

    let
      elixir_1_20_rc4 = pkgs.beam28Packages.elixir_1_20.overrideAttrs (old: rec {
        version = "1.20.0-rc.4";
        src = pkgs.fetchFromGitHub {
          owner = "elixir-lang";
          repo = "elixir";
          rev = "v${version}";
          hash = "sha256-sboB+GW3T+t9gEcOGtd6NllmIlyWio1+cgWyyxE+484=";
        };
        doCheck = false;
      });
    in
    {
      languages.elixir = {
        enable = true;
        package = elixir_1_20_rc4;
      };

      languages.erlang = {
        enable = true;
        package = pkgs.beam.interpreters.erlang_28;
      };

      services.postgres = {
        enable = true;
        listen_addresses = "127.0.0.1";
      };

      packages = [
        pkgs.git
        pkgs.tailwindcss
        pkgs.esbuild
        pkgs.opentofu
        pkgs.opentofu-ls
      ];

      enterShell = ''
        echo "#{name} dev environment"
        echo "Elixir $(elixir --version | tail -1)"
      '';
    }
    """
  end

  defp lsp_json do
    Jason.encode!(%{
      "elixir" => %{
        "command" => "expert",
        "args" => ["--stdio"],
        "extensionToLanguage" => %{
          ".ex" => "elixir",
          ".exs" => "elixir",
          ".heex" => "heex"
        }
      },
      "tofu" => %{
        "command" => "tofu-ls",
        "args" => ["serve"],
        "extensionToLanguage" => %{
          ".tf" => "terraform",
          ".tfvars" => "terraform-vars"
        }
      }
    }, pretty: true) <> "\n"
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
