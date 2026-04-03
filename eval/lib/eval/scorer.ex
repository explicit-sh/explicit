defmodule Eval.Scorer do
  @moduledoc "Score eval results with heuristic checks."

  defstruct [
    :questions_first, :question_count, :docs_created, :tests_created,
    :tests_pass, :quality_clean, :score, :max_score, :pass,
    details: %{}
  ]

  @pass_threshold 70

  @doc "Score a runner result against scenario expectations"
  def score(%Eval.Runner{} = result, workspace, scenario) do
    expect = scenario.expect

    # Extract data from workspace
    docs = Path.wildcard(Path.join(workspace, "docs/**/*.md"))
           |> Enum.reject(&String.contains?(&1, "README.md"))
    tests = Path.wildcard(Path.join(workspace, "test/**/*_test.exs"))
    test_result = run_tests(workspace)
    quality_result = run_quality(workspace)

    # Check: questions before action
    write_tools = ["Write", "Edit", "Bash"]
    first_write_idx = Enum.find_index(result.tool_uses, &(&1.name in write_tools))
    first_q_idx = Enum.find_index(result.tool_uses, &(&1.name == "AskUserQuestion"))

    questions_first = first_q_idx != nil and (first_write_idx == nil or first_q_idx < first_write_idx)
    question_count = length(result.questions)

    # Check for doc references in code (# Implements OPP-001, # See ADR-001, etc)
    code_files = Path.wildcard(Path.join(workspace, "lib/**/*.ex"))
    doc_refs = count_doc_refs(code_files)

    # Check that docs were created BEFORE code (via tool ordering)
    first_doc_tool = Enum.find_index(result.tool_uses, fn t ->
      t.name == "Bash" and is_binary(Map.get(t.input, "command", "")) and
        String.contains?(Map.get(t.input, "command", ""), "explicit docs new")
    end)
    docs_before_code = first_doc_tool != nil and (first_write_idx == nil or first_doc_tool < first_write_idx)

    # Score components (110 max, normalized to 100)
    q_first_pts = if questions_first, do: 15, else: 0
    q_count_pts = if question_count >= (expect.min_questions || 2), do: 10, else: div(question_count * 10, max(expect.min_questions || 2, 1))
    docs_pts = min(length(docs) * 5, 20)
    docs_before_pts = if docs_before_code, do: 10, else: 0
    doc_refs_pts = min(doc_refs * 3, 10)
    tests_pts = if length(tests) > 0, do: 15, else: 0
    test_pass_pts = if test_result, do: 10, else: 0
    quality_pts = if quality_result, do: 10, else: 0

    total = q_first_pts + q_count_pts + docs_pts + docs_before_pts + doc_refs_pts + tests_pts + test_pass_pts + quality_pts

    %__MODULE__{
      questions_first: questions_first,
      question_count: question_count,
      docs_created: length(docs),
      tests_created: length(tests),
      tests_pass: test_result,
      quality_clean: quality_result,
      score: total,
      max_score: 100,
      pass: total >= @pass_threshold,
      details: %{
        q_first_pts: q_first_pts,
        q_count_pts: q_count_pts,
        docs_pts: docs_pts,
        docs_before_pts: docs_before_pts,
        doc_refs_pts: doc_refs_pts,
        tests_pts: tests_pts,
        test_pass_pts: test_pass_pts,
        quality_pts: quality_pts,
        doc_files: Enum.map(docs, &Path.basename/1),
        test_files: Enum.map(tests, &Path.basename/1),
        doc_refs: doc_refs,
        docs_before_code: docs_before_code,
        duration_ms: result.duration_ms,
        error: result.error
      }
    }
  end

  @doc "Print a human-readable report"
  def print_report(%__MODULE__{} = s, _scenario) do
    IO.puts("")
    print_check("Questions first", s.questions_first, "asked #{s.question_count} questions before writing")
    print_check("Question count", s.question_count >= 2, "#{s.question_count} questions")
    print_check("Docs created", s.docs_created > 0, "#{s.docs_created}: #{Enum.join(s.details.doc_files, ", ")}")
    print_check("Docs before code", s.details.docs_before_code, "docs created before writing code")
    print_check("Doc refs in code", s.details.doc_refs > 0, "#{s.details.doc_refs} references (OPP-001, ADR-001, etc)")
    print_check("Tests created", s.tests_created > 0, "#{s.tests_created} test files")
    print_check("Tests pass", s.tests_pass, if(s.tests_pass, do: "all passing", else: "failures"))
    print_check("Quality clean", s.quality_clean, if(s.quality_clean, do: "clean", else: "issues found"))

    IO.puts("")
    status = if s.pass, do: "PASS", else: "FAIL"
    IO.puts("  Score: #{s.score}/#{s.max_score} — #{status}")

    if s.details[:error] do
      IO.puts("  Error: #{s.details.error}")
    end

    if s.details[:duration_ms] do
      IO.puts("  Duration: #{Float.round(s.details.duration_ms / 1000, 1)}s")
    end

    IO.puts("")
  end

  defp print_check(name, passed, detail) do
    mark = if passed, do: "✓", else: "✗"
    IO.puts("  #{mark} #{String.pad_trailing(name <> ":", 20)} #{detail}")
  end

  defp run_tests(workspace) do
    case System.cmd("mix", ["test", "--no-color"], cd: workspace, stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp count_doc_refs(files) do
    pattern = ~r/(ADR|OPP|SPEC|INC|POL)-\d{3}/
    Enum.sum(Enum.map(files, fn file ->
      case File.read(file) do
        {:ok, content} -> length(Regex.scan(pattern, content))
        _ -> 0
      end
    end))
  end

  defp run_quality(workspace) do
    case System.cmd("explicit", ["quality", "--json"], cd: workspace, stderr_to_stdout: true) do
      {output, _} -> String.contains?(output, "\"clean\":true")
      _ -> false
    end
  rescue
    _ -> false
  end
end
