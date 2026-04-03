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
      case msg do
        %{type: "tool_use", name: name, input: input} ->
          [%{name: name, input: input}]
        %{"type" => "tool_use", "name" => name, "input" => input} ->
          [%{name: name, input: input}]
        _ ->
          # Try to extract from content blocks
          extract_from_content(msg)
      end
    end)
  end

  defp extract_from_content(%{content: content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{type: "tool_use", name: name, input: input} -> [%{name: name, input: input}]
      %{"type" => "tool_use", "name" => name, "input" => input} -> [%{name: name, input: input}]
      _ -> []
    end)
  end

  defp extract_from_content(_), do: []
end
