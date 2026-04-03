defmodule Eval.Scenario do
  @moduledoc "Parse scenario markdown files with YAML frontmatter."

  defstruct [:name, :prompt, :max_turns, :expect, :answerer_context, :description]

  @doc "Load and parse a scenario file"
  def load!(path) do
    content = File.read!(path)

    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/s, content) do
      [_, yaml, body] ->
        {:ok, frontmatter} = YamlElixir.read_from_string(yaml)
        answerer_context = extract_section(body, "Answerer Context")

        %__MODULE__{
          name: frontmatter["name"],
          prompt: frontmatter["prompt"],
          max_turns: frontmatter["max_turns"] || 25,
          expect: parse_expect(frontmatter["expect"] || %{}),
          answerer_context: answerer_context,
          description: extract_description(body)
        }

      _ ->
        raise "Invalid scenario file: #{path} (missing YAML frontmatter)"
    end
  end

  defp parse_expect(map) do
    %{
      questions_first: Map.get(map, "questions_first", true),
      min_questions: Map.get(map, "min_questions", 2),
      any_doc_created: Map.get(map, "any_doc_created", true),
      tests_pass: Map.get(map, "tests_pass", false),
      quality_clean: Map.get(map, "quality_clean", false)
    }
  end

  defp extract_section(body, heading) do
    case Regex.run(~r/^## #{Regex.escape(heading)}\s*\n(.*?)(?=^## |\z)/ms, body) do
      [_, content] -> String.trim(content)
      _ -> nil
    end
  end

  defp extract_description(body) do
    case Regex.run(~r/\A# .+\n\n(.*?)(?=^## |\z)/ms, body) do
      [_, desc] -> String.trim(desc)
      _ -> nil
    end
  end
end
