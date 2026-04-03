defmodule Eval.ScenarioTest do
  use ExUnit.Case

  alias Eval.Scenario

  test "parses scenario file" do
    path = Path.join(__DIR__, "../../scenarios/selling_llama_milk.md")
    scenario = Scenario.load!(path)

    assert scenario.name == "selling-llama-milk"
    assert scenario.prompt =~ "llama milk"
    assert scenario.max_turns == 25
    assert scenario.expect.questions_first == true
    assert scenario.expect.min_questions == 2
  end

  test "extracts answerer context" do
    path = Path.join(__DIR__, "../../scenarios/selling_llama_milk.md")
    scenario = Scenario.load!(path)

    assert scenario.answerer_context =~ "12 llamas"
    assert scenario.answerer_context =~ "Vermont"
  end

  test "raises on invalid file" do
    path = Path.join(System.tmp_dir!(), "bad_scenario_#{:rand.uniform(999999)}.md")
    File.write!(path, "no frontmatter here")

    assert_raise RuntimeError, ~r/missing YAML frontmatter/, fn ->
      Scenario.load!(path)
    end

    File.rm!(path)
  end
end
