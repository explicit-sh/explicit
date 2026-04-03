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
      {:ok, session} = ClaudeCode.start_link(
        cwd: workspace,
        append_system_prompt: system_prompt,
        permission_mode: :bypass_permissions,
        max_turns: scenario.max_turns
      )

      # Collect all messages from the stream
      messages = session
      |> ClaudeCode.stream(scenario.prompt)
      |> Enum.to_list()

      ClaudeCode.stop(session)

      duration = System.monotonic_time(:millisecond) - start_time

      # Debug: log first assistant message structure
      assistant_msgs = Enum.filter(messages, &(Map.get(&1, :type) == :assistant))
      if length(assistant_msgs) > 0 do
        first = hd(assistant_msgs)
        msg = Map.get(first, :message, %{})
        Logger.debug("First assistant message keys: #{inspect(Map.keys(msg))}")
        content = Map.get(msg, :content, Map.get(msg, "content", []))
        if is_list(content) do
          Logger.debug("Content block types: #{inspect(Enum.map(content, fn c -> {Map.get(c, :type, Map.get(c, "type", :unknown))} end) |> Enum.take(5))}")
        end
      end

      # Extract tool uses from messages
      tool_uses = extract_tool_uses(messages)
      questions = Enum.filter(tool_uses, &(&1.name == "AskUserQuestion"))

      Logger.info("Session complete: #{length(messages)} messages, #{length(tool_uses)} tools, #{length(questions)} questions in #{duration}ms")

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

  defp build_system_prompt do
    """
    IMPORTANT: This project uses explicit for code quality and decision documentation.

    ## Workflow

    1. Ask 3-5 clarifying questions using AskUserQuestion — NEVER dump questions as text
    2. Wait for answers, then ask follow-up if needed
    3. Use EnterPlanMode for non-trivial changes
    4. Write code WITH tests, @doc, and @spec for every public function
    5. Run `explicit quality --json` before finishing — it must be clean

    ## Commands

    explicit quality           # Must be clean before stopping
    explicit docs new <type>   # Create doc: adr, opp, pol, inc, spec
    explicit docs validate     # Validate docs
    explicit violations        # Code violations

    ## Rules

    - Every module in lib/ must have a test file in test/
    - Every public function must have @doc and @spec
    - No String.to_atom/1, no float for money, no raw(variable)
    - Create decision documents for significant choices
    """
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

        # Message with content blocks
        Map.has_key?(msg, :content) and is_list(msg.content) ->
          extract_from_content(msg.content)
        is_map(msg) and is_list(Map.get(msg, "content", nil)) ->
          extract_from_content(msg["content"])

        # claude_code SDK: assistant message with :message containing :content
        Map.get(msg, :type) == :assistant ->
          inner = Map.get(msg, :message, %{})
          content = Map.get(inner, :content, Map.get(inner, "content", []))
          if is_list(content), do: extract_from_content(content), else: []

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
