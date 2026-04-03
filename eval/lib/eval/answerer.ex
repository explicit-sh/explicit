defmodule Eval.Answerer do
  @moduledoc """
  LLM-based answerer for AskUserQuestion tool calls.
  Uses Ollama (local/free) or Gemini Flash as the answerer LLM.
  """

  require Logger

  defstruct [:context, :provider, :system_prompt]

  @answerer_rules """
  RULES:
  1. Answer EACH question with EXACTLY 1 short sentence (max 15 words).
  2. Be slightly ambiguous — don't over-explain.
  3. Use casual language like a real person would.
  4. Don't ask follow-up questions.
  5. Pick one of the provided options when available.
  """

  @doc "Create a new answerer with scenario context"
  def new(context, opts \\ []) do
    provider = opts[:provider] || detect_provider()

    %__MODULE__{
      context: context || "",
      provider: provider,
      system_prompt: "You are a busy user answering questions from a consultant.\n#{@answerer_rules}\n\nYour background:\n#{context || "You are a small business owner."}"
    }
  end

  @doc "Answer a list of AskUserQuestion questions, return %{question => answer}"
  def answer_questions(%__MODULE__{} = answerer, questions) when is_list(questions) do
    Map.new(questions, fn q ->
      question_text = q["question"] || inspect(q)
      options = q["options"] || []

      prompt = if options != [] do
        option_text = options
        |> Enum.with_index(1)
        |> Enum.map(fn {opt, i} -> "#{i}. #{opt["label"]}: #{opt["description"] || ""}" end)
        |> Enum.join("\n")
        "#{question_text}\nOptions:\n#{option_text}\nPick one option label."
      else
        question_text
      end

      answer = call_llm(answerer, prompt)
      Logger.info("Q: #{String.slice(question_text, 0, 60)}... → A: #{String.slice(answer, 0, 60)}")

      # If options exist, try to match the answer to an option label
      final = if options != [] do
        match_option(answer, options) || answer
      else
        answer
      end

      {question_text, final}
    end)
  end

  defp match_option(answer, options) do
    answer_lower = String.downcase(answer)
    Enum.find_value(options, fn opt ->
      label = opt["label"] || ""
      if String.contains?(answer_lower, String.downcase(label)), do: label
    end)
  end

  defp detect_provider do
    cond do
      ollama_running?() -> :ollama
      System.get_env("GEMINI_API_KEY") -> :gemini
      true -> :ollama
    end
  end

  defp ollama_running? do
    case Req.get("http://localhost:11434/api/tags", receive_timeout: 2000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp call_llm(%__MODULE__{provider: :ollama} = answerer, prompt) do
    case Req.post("http://localhost:11434/api/chat",
      json: %{
        model: "llama3.2",
        messages: [
          %{role: "system", content: answerer.system_prompt},
          %{role: "user", content: prompt}
        ],
        stream: false
      },
      receive_timeout: 30_000
    ) do
      {:ok, %{status: 200, body: body}} ->
        body["message"]["content"] || "I'm not sure about that."
      {:error, reason} ->
        Logger.warning("Ollama error: #{inspect(reason)}")
        "I'm not sure, let's go with the first option."
    end
  end

  defp call_llm(%__MODULE__{provider: :gemini} = answerer, prompt) do
    api_key = System.get_env("GEMINI_API_KEY") || raise "GEMINI_API_KEY not set"

    case Req.post(
      "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
      headers: [{"Authorization", "Bearer #{api_key}"}],
      json: %{
        model: "gemini-2.0-flash",
        messages: [
          %{role: "system", content: answerer.system_prompt},
          %{role: "user", content: prompt}
        ]
      },
      receive_timeout: 15_000
    ) do
      {:ok, %{status: 200, body: body}} ->
        get_in(body, ["choices", Access.at(0), "message", "content"]) || "Not sure."
      {:error, reason} ->
        Logger.warning("Gemini error: #{inspect(reason)}")
        "Let's go with the first option."
    end
  end

  defp call_llm(%__MODULE__{}, _prompt) do
    "I'm not sure, whatever you think is best."
  end
end
