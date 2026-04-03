defmodule Eval.Runner do
  @moduledoc """
  Run a multi-turn Claude session using claude_code SDK.
  Intercepts AskUserQuestion with LLM answerer.
  """

  require Logger

  defstruct [:messages, :tool_uses, :questions, :duration_ms, :error]

  @doc "Run a scenario in a workspace, return collected results"
  def run(workspace, scenario, opts \\ []) do
    answerer = Eval.Answerer.new(scenario.answerer_context, opts)

    # Write system prompt file
    prompt_file = Path.join(System.tmp_dir!(), "explicit-eval-prompt.txt")
    system_prompt = build_system_prompt()
    File.write!(prompt_file, system_prompt)

    start_time = System.monotonic_time(:millisecond)

    try do
      # Store answerer in process dict for hook callback access
      Process.put(:eval_answerer, answerer)

      # Store workspace path for stop hook
      Process.put(:eval_workspace, workspace)

      {:ok, session} = ClaudeCode.start_link(
        cwd: workspace,
        append_system_prompt: system_prompt,
        permission_mode: :bypass_permissions,
        max_turns: scenario.max_turns,
        hooks: %{
          PreToolUse: [&handle_pre_tool_use/2],
          Stop: [&handle_stop/2]
        }
      )

      # Collect all messages from the stream
      messages = session
      |> ClaudeCode.stream(scenario.prompt)
      |> Enum.to_list()

      ClaudeCode.stop(session)

      duration = System.monotonic_time(:millisecond) - start_time

      # Extract tool uses from messages
      tool_uses = extract_tool_uses(messages)
      questions = Enum.filter(tool_uses, &(&1.name == "AskUserQuestion"))

      # Log tool summary
      tool_summary = tool_uses |> Enum.map(& &1.name) |> Enum.frequencies()
      Logger.info("Session complete: #{length(messages)} messages, #{length(tool_uses)} tools, #{length(questions)} questions in #{duration}ms")
      Logger.info("Tool breakdown: #{inspect(tool_summary)}")

      # Log bash commands
      bash_cmds = tool_uses |> Enum.filter(&(&1.name == "Bash")) |> Enum.map(&get_in(&1, [:input, "command"]))
      if bash_cmds != [], do: Logger.info("Bash commands: #{inspect(bash_cmds)}")

      %__MODULE__{
        messages: messages,
        tool_uses: tool_uses,
        questions: questions,
        duration_ms: duration
      }
    rescue
      e ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.error("Runner error: #{Exception.message(e)}")

        %__MODULE__{
          messages: [],
          tool_uses: [],
          questions: [],
          duration_ms: duration,
          error: Exception.message(e)
        }
    after
      File.rm(prompt_file)
    end
  end

  # ─── Stop hook: block until docs + code exist ────────────────────────────

  defp handle_stop(_stop_info, _tool_use_id) do
    workspace = Process.get(:eval_workspace)
    stop_count = Process.get(:eval_stop_count, 0)
    Process.put(:eval_stop_count, stop_count + 1)

    # Give up after 15 blocks total to avoid infinite loops
    if stop_count >= 15 do
      Logger.warning("Stop hook: giving up after #{stop_count} blocks")
      :ok
    else
      docs = if workspace, do: Path.wildcard(Path.join(workspace, "docs/**/*.md")) |> Enum.reject(&String.contains?(&1, "README.md")), else: []
      tests = if workspace, do: Path.wildcard(Path.join(workspace, "test/**/*_test.exs")), else: []
      code = if workspace, do: Path.wildcard(Path.join(workspace, "lib/**/*.ex")), else: []

      # Check for doc references in code (OPP-001, ADR-001, etc)
      doc_refs = Enum.sum(Enum.map(code, fn f ->
        case File.read(f) do
          {:ok, c} -> length(Regex.scan(~r/(ADR|OPP|SPEC|INC|POL)-\d{3}/, c))
          _ -> 0
        end
      end))

      cond do
        length(docs) == 0 ->
          Logger.info("Stop hook [#{stop_count}]: no docs")
          {:block, reason: "No decision documents exist. Before writing ANY code you must:\n1. Use AskUserQuestion if you need more info\n2. Run: explicit docs new opp \"Title\"\n3. Run: explicit docs new adr \"Title\"\n4. Edit the generated files to fill in details\n5. Run: explicit docs validate"}

        length(code) == 0 ->
          Logger.info("Stop hook [#{stop_count}]: no code")
          {:block, reason: "Docs exist (#{Enum.map(docs, &Path.basename/1) |> Enum.join(", ")}) but no Elixir code. Write a Phoenix app:\n1. Create lib/ modules with @moduledoc referencing doc IDs (e.g. \"Implements OPP-001\")\n2. Write tests in test/ that reference SPEC docs\n3. Every public function needs @doc and @spec"}

        length(tests) == 0 ->
          Logger.info("Stop hook [#{stop_count}]: no tests")
          {:block, reason: "Code exists but no tests. Create test files in test/ for every module in lib/. Reference doc IDs in test comments (e.g. # Tests SPEC-001)."}

        doc_refs == 0 ->
          Logger.info("Stop hook [#{stop_count}]: no doc refs in code")
          {:block, reason: "Code exists but doesn't reference any decision documents. Add doc IDs to @moduledoc:\n\n@moduledoc \"\"\"\nImplements OPP-001: Title\nSee ADR-001: Decision\n\"\"\""}

        true ->
          Logger.info("Stop hook [#{stop_count}]: all checks pass — allowing stop")
          :ok
      end
    end
  end

  # ─── PreToolUse hooks ───────────────────────────────────────────────────

  defp handle_pre_tool_use(%{tool_name: "AskUserQuestion", tool_input: input}, _tool_use_id) do
    answerer = Process.get(:eval_answerer)
    questions = Map.get(input, "questions", [])

    if answerer && questions != [] do
      Logger.info("Answering #{length(questions)} question(s) via LLM...")
      answers = Eval.Answerer.answer_questions(answerer, questions)
      {:allow, updated_input: Map.put(input, "answers", answers)}
    else
      :ok
    end
  end

  defp handle_pre_tool_use(_tool_info, _tool_use_id) do
    :ok
  end

  defp build_system_prompt do
    # Read system prompt from eval's local copy of the server code
    server_path = Path.expand("../../../server/lib/explicit/system_prompt.ex", __DIR__)

    if File.exists?(server_path) do
      # Load and call the module
      [{mod, _}] = Code.compile_file(server_path)
      mod.claude()
    else
      raise "Cannot find system_prompt.ex at #{server_path}. Run eval from the repo root."
    end
  end

  defp extract_tool_uses(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      # Handle various message formats from claude_code SDK
      cond do
        # Direct tool_use message
        match?(%{type: "tool_use"}, msg) ->
          [%{name: Map.get(msg, :name, "unknown"), input: Map.get(msg, :input, %{})}]
        match?(%{"type" => "tool_use"}, msg) ->
          [%{name: msg["name"], input: msg["input"] || %{}}]

        # Message with tool_name field (claude_code SDK format)
        Map.has_key?(msg, :tool_name) ->
          [%{name: msg.tool_name, input: Map.get(msg, :tool_input, %{})}]
        is_map(msg) and Map.has_key?(msg, "tool_name") ->
          [%{name: msg["tool_name"], input: msg["tool_input"] || %{}}]

        # claude_code SDK: assistant message with :message containing :content
        Map.get(msg, :type) == :assistant ->
          inner = Map.get(msg, :message, %{})
          content = if is_map(inner), do: Map.get(inner, :content, Map.get(inner, "content", [])), else: []
          if is_list(content), do: extract_from_content(content), else: []

        # Direct content blocks on message
        is_map(msg) and is_list(Map.get(msg, :content, nil)) ->
          extract_from_content(msg.content)

        # Struct with __struct__ field — try to access fields generically
        is_struct(msg) ->
          extract_from_struct(msg)

        true -> []
      end
    end)
  end

  defp extract_from_content(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{type: :tool_use, name: name} = block -> [%{name: name, input: Map.get(block, :input, %{})}]
      %{type: "tool_use", name: name} = block -> [%{name: name, input: Map.get(block, :input, %{})}]
      %{"type" => "tool_use", "name" => name} = block -> [%{name: name, input: block["input"] || %{}}]
      _ -> []
    end)
  end

  defp extract_from_content(_), do: []

  defp extract_from_struct(msg) do
    map = Map.from_struct(msg)
    cond do
      Map.has_key?(map, :tool_name) -> [%{name: map.tool_name, input: Map.get(map, :tool_input, %{})}]
      Map.has_key?(map, :content) and is_list(map.content) -> extract_from_content(map.content)
      true -> []
    end
  rescue
    _ -> []
  end
end
