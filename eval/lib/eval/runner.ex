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

      {:ok, session} = ClaudeCode.start_link(
        cwd: workspace,
        append_system_prompt: system_prompt,
        permission_mode: :bypass_permissions,
        max_turns: scenario.max_turns,
        hooks: %{
          PreToolUse: [&handle_pre_tool_use/2]
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
