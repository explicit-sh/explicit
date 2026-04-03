defmodule EvalTest do
  use ExUnit.Case

  @moduletag :eval

  @tag timeout: 600_000
  test "selling llama milk scenario" do
    score = Eval.run("selling_llama_milk", keep: true)

    assert score.questions_first, "Claude should ask questions before writing code"
    assert score.question_count >= 2, "Expected at least 2 questions, got #{score.question_count}"
    assert score.docs_created > 0, "Expected at least 1 doc created"
    assert score.score >= 70, "Score #{score.score}/100 below threshold 70"
  end
end
