defmodule Explicit.ConnectionHandler do
  @moduledoc """
  Handles a single client connection: reads JSON line, dispatches, responds.
  """

  alias Explicit.{Protocol, ViolationStore, DocStore, Checker}
  alias Explicit.Doc.{Document, Validation, Template, Discovery}

  def handle(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, line} ->
        response = dispatch(line)
        :gen_tcp.send(socket, response)

      {:error, _} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp dispatch(line) do
    case Protocol.decode_request(line) do
      {:ok, method, params} -> handle_method(method, params)
      {:error, msg} -> Protocol.encode_error(msg)
    end
  end

  # ─── Core methods ──────────────────────────────────────────────────────────

  defp handle_method("status", _params) do
    code_summary = ViolationStore.summary()
    doc_summary = DocStore.summary()
    watching = Application.get_env(:explicit, :watching_dir)

    Protocol.encode_ok(%{
      watching: watching,
      total_violations: code_summary.total,
      files_checked: code_summary.files,
      by_check: code_summary.by_check,
      doc_errors: doc_summary.errors,
      doc_warnings: doc_summary.warnings,
      docs_checked: doc_summary.files
    })
  end

  defp handle_method("violations", %{"file" => file}) do
    violations = ViolationStore.get(file)
    Protocol.encode_ok(%{total: length(violations), violations: violations})
  end

  defp handle_method("violations", _params) do
    all = ViolationStore.all()
    violations = Enum.flat_map(all, fn {_path, vs} -> vs end)
    Protocol.encode_ok(%{total: length(violations), violations: violations})
  end

  defp handle_method("check", %{"file" => file}) do
    case Checker.check_and_store(file) do
      {:ok, violations} ->
        Protocol.encode_ok(%{file: file, violations: violations})
      {:error, msg} ->
        Protocol.encode_error(msg)
    end
  end

  defp handle_method("watch", %{"dir" => dir}) do
    case Explicit.Watcher.watch(dir) do
      :ok ->
        Application.put_env(:explicit, :watching_dir, dir)
        Protocol.encode_ok(%{watching: dir})
      {:error, reason} ->
        Protocol.encode_error("Watch failed: #{inspect(reason)}")
    end
  end

  defp handle_method("system_prompt", %{"tool" => "gemini"}) do
    Protocol.encode_ok(%{prompt: Explicit.SystemPrompt.gemini()})
  end

  defp handle_method("system_prompt", _params) do
    Protocol.encode_ok(%{prompt: Explicit.SystemPrompt.claude()})
  end

  defp handle_method("refresh", _params) do
    project_dir = Application.get_env(:explicit, :project_dir, ".")

    # Clear caches
    ViolationStore.clear()
    DocStore.clear()

    # Re-scan everything
    Explicit.Watcher.watch(project_dir)

    Protocol.encode_ok(%{refreshed: true})
  end

  defp handle_method("stop", _params) do
    response = Protocol.encode_ok(%{stopped: true})
    Task.start(fn -> Process.sleep(100); System.stop(0) end)
    response
  end

  # ─── Validate ─────────────────────────────────────────────────────────────

  defp handle_method("validate", _params) do
    project_dir = Application.get_env(:explicit, :project_dir, ".")
    schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})

    # Validate docs
    doc_files = Discovery.discover(project_dir, schema)
    doc_results = Enum.flat_map(doc_files, fn file ->
      case Document.parse_file(file) do
        {:ok, doc} ->
          {:ok, diags} = Validation.validate(doc, schema)
          DocStore.put(file, diags)

          Enum.map(diags, fn {level, code, msg} ->
            %{file: file, id: doc.id, level: to_string(level), code: code, message: msg}
          end)
        {:error, msg} ->
          [%{file: file, id: nil, level: "error", code: "F000", message: msg}]
      end
    end)

    # Validate code — skip _build/, deps/, etc. (see Watcher.ignored?/1)
    code_files = discover_code_files(project_dir)
    code_results = Enum.flat_map(code_files, fn file ->
      case Checker.check_file(file) do
        {:ok, violations} -> violations
        _ -> []
      end
    end)

    # Project checks
    project_violations = Checker.project_checks(project_dir)

    # Scan code for doc refs
    doc_refs = scan_doc_refs(code_files)

    doc_errors = Enum.count(doc_results, &(&1.level == "error"))
    doc_warnings = Enum.count(doc_results, &(&1.level == "warning"))
    clean = doc_errors == 0 and length(code_results) == 0 and length(project_violations) == 0

    Protocol.encode_ok(%{
      clean: clean,
      doc_errors: doc_errors,
      doc_warnings: doc_warnings,
      doc_diagnostics: doc_results,
      code_violations: length(code_results),
      violations: code_results,
      missing_tests: length(project_violations),
      project_violations: project_violations,
      doc_refs_in_code: doc_refs
    })
  end

  # ─── Quality gate ──────────────────────────────────────────────────────────

  defp handle_method("quality", _params) do
    project_dir = Application.get_env(:explicit, :project_dir, ".")
    schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})

    # Run project-level checks (duplicate migrations, test files in lib/)
    project_violations = Checker.project_checks(project_dir)

    # Live-derive doc diagnostics from current disk state. We DO NOT read
    # DocStore.summary because it carries stale rows from deleted/renamed
    # docs — the cause of EXPLICIT-FEEDBACK.md #1. Every `quality` call
    # walks Discovery fresh and validates on the spot.
    doc_diagnostics =
      Discovery.discover(project_dir, schema)
      |> Enum.flat_map(fn file ->
        case Document.parse_file(file) do
          {:ok, doc} ->
            {:ok, diags} = Validation.validate(doc, schema)
            DocStore.put(file, diags)
            Enum.map(diags, fn {level, code, msg} ->
              %{file: file, id: doc.id, level: level, code: code, message: msg}
            end)

          {:error, msg} ->
            [%{file: file, id: nil, level: :error, code: "F000", message: msg}]
        end
      end)

    doc_errors = Enum.count(doc_diagnostics, &(&1.level == :error))
    doc_warnings = Enum.count(doc_diagnostics, &(&1.level == :warning))

    # doc_error_files is populated from the SAME diagnostics list as doc_errors.
    # They must never disagree — that was EXPLICIT-FEEDBACK.md #11.
    doc_error_files =
      doc_diagnostics
      |> Enum.filter(&(&1.level == :error))
      |> Enum.map(fn d ->
        %{
          file: Path.relative_to(d.file, project_dir),
          id: d.id,
          code: d.code,
          message: d.message
        }
      end)

    # Aggregate code results (ViolationStore is authoritative for code; it's
    # kept fresh by the Watcher on every .ex edit).
    code_summary = ViolationStore.summary()
    all_violations = Enum.flat_map(ViolationStore.all(), fn {_path, vs} -> vs end)
    tests_in_lib = Enum.filter(project_violations, &(&1.check == "NoTestInLibDir"))
    missing_docs = Enum.count(all_violations, &(&1.check == "NoPublicWithoutDoc"))
    iron_law = code_summary.total - missing_docs + length(project_violations)

    clean = iron_law == 0 and doc_errors == 0 and missing_docs == 0

    # Build per-file code-issue list sorted by most recently modified first
    code_file_issues =
      ViolationStore.all()
      |> Enum.reject(fn {path, _} -> path == "__project__" end)
      |> Enum.filter(fn {_, vs} -> vs != [] end)
      |> Enum.map(fn {path, vs} ->
        mtime =
          case File.stat(path) do
            {:ok, %{mtime: mtime}} -> :calendar.datetime_to_gregorian_seconds(mtime)
            _ -> 0
          end

        rel_path = Path.relative_to(path, project_dir)
        checks = vs |> Enum.map(& &1.check) |> Enum.frequencies()
        %{file: rel_path, mtime: mtime, issues: checks, count: length(vs)}
      end)
      |> Enum.sort_by(& &1.mtime, :desc)
      |> Enum.take(10)

    # Unified files list: doc errors AND code-file issues together.
    files = doc_error_files ++ code_file_issues

    # Build actionable fix instructions
    fix_instructions =
      build_fix_instructions(iron_law, missing_docs, 0, doc_errors, code_file_issues)

    Protocol.encode_ok(%{
      clean: clean,
      iron_law_violations: iron_law,
      tests_in_lib: length(tests_in_lib),
      missing_docs: missing_docs,
      missing_specs: 0,
      doc_errors: doc_errors,
      doc_warnings: doc_warnings,
      total_issues: iron_law + doc_errors,
      files: files,
      fix: fix_instructions,
      details: %{
        project_violations: project_violations,
        by_check: code_summary.by_check
      }
    })
  end

  defp handle_method("sarif", _params) do
    project_dir = Application.get_env(:explicit, :project_dir, ".")
    sarif = Explicit.Sarif.generate(project_dir)
    # Return raw SARIF JSON (not wrapped in ok/error envelope)
    Jason.encode!(sarif)
  end

  defp handle_method("test.run", params) do
    project_dir = Application.get_env(:explicit, :project_dir, ".")
    timeout = Map.get(params, "timeout", 60) |> Kernel.*(1000)

    case Explicit.TestRunner.run(project_dir, timeout: timeout) do
      {:ok, result} -> Protocol.encode_ok(result)
      {:error, msg} -> Protocol.encode_error(msg)
    end
  end

  # ─── Init/Scaffold methods ─────────────────────────────────────────────────

  defp handle_method("init", %{"name" => name} = params) do
    base_dir = Map.get(params, "dir") || Application.get_env(:explicit, :project_dir, ".")
    dir = Path.join(base_dir, name)
    overwrite_paths = Map.get(params, "overwrite_paths", [])
    case Explicit.Init.run_new(dir, name, overwrite_paths) do
      {:ok, result} ->
        Protocol.encode_ok(%{
          project: result.project,
          name: result.name,
          created: result.created
        })
      {:error, msg} ->
        Protocol.encode_error(msg)
    end
  end

  defp handle_method("init", params) do
    dir = Map.get(params, "dir") || Application.get_env(:explicit, :project_dir, ".")
    overwrite_paths = Map.get(params, "overwrite_paths", [])
    case Explicit.Init.run(dir, overwrite_paths) do
      {:ok, result} ->
        Protocol.encode_ok(%{
          project: result.project,
          name: result.name,
          created: result.created
        })
      {:error, msg} ->
        Protocol.encode_error(msg)
    end
  end

  defp handle_method("scaffold", %{"name" => name} = params) do
    dir = Map.get(params, "dir") || Application.get_env(:explicit, :project_dir, ".")
    case Explicit.Scaffold.run(dir, name) do
      {:ok, result} ->
        Protocol.encode_ok(%{
          project: result.project,
          name: result.name,
          created: result.created,
          phoenix: to_string(result.phoenix),
          boundary: to_string(result.boundary),
          deps: to_string(result.deps)
        })
      {:error, msg} ->
        Protocol.encode_error(msg)
    end
  end

  defp handle_method("scaffold", _params) do
    Protocol.encode_error("scaffold requires 'name' param")
  end

  # ─── Doc methods ───────────────────────────────────────────────────────────

  defp handle_method("doc.validate", params) do
    schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})
    project_dir = Application.get_env(:explicit, :project_dir, ".")

    files = case Map.get(params, "file") do
      nil -> Discovery.discover(project_dir, schema)
      file -> [file]
    end

    results = Enum.map(files, fn file ->
      case Document.parse_file(file) do
        {:ok, doc} ->
          {:ok, diagnostics} = Validation.validate(doc, schema)
          DocStore.put(file, diagnostics)
          %{file: file, id: doc.id, diagnostics: Validation.format_diagnostics(diagnostics)}
        {:error, msg} ->
          %{file: file, id: nil, diagnostics: [%{level: "error", code: "F000", message: msg}]}
      end
    end)

    total_errors = Enum.sum(Enum.map(results, fn r ->
      Enum.count(r.diagnostics, &(&1.level == "error"))
    end))

    Protocol.encode_ok(%{files: length(results), errors: total_errors, results: results})
  end

  defp handle_method("doc.new", %{"type" => type, "title" => title} = params) do
    schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})
    project_dir = Application.get_env(:explicit, :project_dir, ".")
    fields = Map.get(params, "fields", %{})

    case Template.create(project_dir, schema, type, title, fields: fields) do
      {:ok, path, _content} ->
        Protocol.encode_ok(%{path: path, id: Document.path_to_id(path)})
      {:error, msg} ->
        Protocol.encode_error(msg)
    end
  end

  defp handle_method("doc.new", _params) do
    Protocol.encode_error("doc.new requires 'type' and 'title' params")
  end

  defp handle_method("doc.list", params) do
    schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})
    project_dir = Application.get_env(:explicit, :project_dir, ".")

    type_filter = Map.get(params, "type")
    status_filter = Map.get(params, "status")

    docs = Discovery.discover(project_dir, schema)
    |> Enum.map(fn file ->
      case Document.parse_file(file) do
        {:ok, doc} -> doc
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> maybe_filter_type(type_filter)
    |> maybe_filter_status(status_filter)
    |> Enum.map(fn doc ->
      %{
        id: doc.id,
        type: doc.type,
        title: doc.title,
        status: Map.get(doc.frontmatter, "status"),
        path: doc.path
      }
    end)

    Protocol.encode_ok(%{total: length(docs), docs: docs})
  end

  defp handle_method("doc.get", %{"file" => file}) do
    case Document.parse_file(file) do
      {:ok, doc} ->
        Protocol.encode_ok(%{
          id: doc.id,
          type: doc.type,
          title: doc.title,
          frontmatter: doc.frontmatter,
          sections: Enum.map(doc.sections, &Map.from_struct/1)
        })
      {:error, msg} ->
        Protocol.encode_error(msg)
    end
  end

  defp handle_method("doc.get", %{"id" => id}) do
    schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})
    project_dir = Application.get_env(:explicit, :project_dir, ".")

    case find_doc_by_id(project_dir, schema, id) do
      {:ok, doc} ->
        Protocol.encode_ok(%{
          id: doc.id,
          type: doc.type,
          title: doc.title,
          frontmatter: doc.frontmatter,
          sections: Enum.map(doc.sections, fn s -> %{name: s.name, level: s.level, content: s.content} end)
        })
      {:error, msg} ->
        Protocol.encode_error(msg)
    end
  end

  defp handle_method("doc.get", _params) do
    Protocol.encode_error("doc.get requires 'file' or 'id' param")
  end

  defp handle_method("doc.set", %{"file" => file, "fields" => fields}) when is_map(fields) do
    case Document.parse_file(file) do
      {:ok, doc} ->
        updated_fm = Map.merge(doc.frontmatter, fields)
        new_raw = rebuild_frontmatter(doc.raw, updated_fm)
        File.write!(file, new_raw)
        Protocol.encode_ok(%{file: file, updated: Map.keys(fields)})
      {:error, msg} ->
        Protocol.encode_error(msg)
    end
  end

  defp handle_method("doc.set", _params) do
    Protocol.encode_error("doc.set requires 'file' and 'fields' params")
  end

  defp handle_method("doc.describe", params) do
    schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})

    case Map.get(params, "type") do
      nil ->
        # Return the FULL schema in one call — fields and sections included.
        # Saves the 5+ per-type round-trips documented in EXPLICIT-FEEDBACK.md #8.
        types = Enum.map(schema.types, fn t ->
          %{
            name: t.name,
            description: t.description,
            folder: t.folder,
            aliases: t.aliases,
            fields: Enum.map(t.fields, fn f ->
              %{name: f.name, type: f.type, required: f.required, values: f.values, description: f.description}
            end),
            sections: Enum.map(t.sections, &section_to_map/1),
            rules: Enum.map(t.rules, fn r ->
              %{name: r.name, when_field: r.when_field, when_equals: r.when_equals, then_section: r.then_section_table}
            end)
          }
        end)
        relations = Enum.map(schema.relations, fn r ->
          %{name: r.name, inverse: r.inverse, cardinality: r.cardinality, description: r.description}
        end)
        Protocol.encode_ok(%{types: types, relations: relations})

      type_name ->
        case Explicit.Schema.find_type(schema, type_name) do
          nil -> Protocol.encode_error("Unknown type: #{type_name}")
          type_def ->
            Protocol.encode_ok(%{
              name: type_def.name,
              description: type_def.description,
              folder: type_def.folder,
              aliases: type_def.aliases,
              fields: Enum.map(type_def.fields, fn f ->
                %{name: f.name, type: f.type, required: f.required, values: f.values, description: f.description}
              end),
              sections: Enum.map(type_def.sections, &section_to_map/1),
              rules: Enum.map(type_def.rules, fn r ->
                %{name: r.name, when_field: r.when_field, when_equals: r.when_equals, then_section: r.then_section_table}
              end)
            })
        end
    end
  end

  defp handle_method("doc.check_fixme", params) do
    schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})
    project_dir = Application.get_env(:explicit, :project_dir, ".")

    files = case Map.get(params, "file") do
      nil -> Discovery.discover(project_dir, schema)
      file -> [file]
    end

    markers = ~w(FIXME TBD TODO XXX [TBD] [FIXME])
    results = Enum.flat_map(files, fn file ->
      case File.read(file) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, line_no} ->
            found = Enum.filter(markers, &String.contains?(line, &1))
            Enum.map(found, fn marker ->
              %{file: file, line: line_no, marker: marker, text: String.trim(line)}
            end)
          end)
        _ -> []
      end
    end)

    Protocol.encode_ok(%{total: length(results), markers: results})
  end

  defp handle_method("doc.lint", _params) do
    schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})
    project_dir = Application.get_env(:explicit, :project_dir, ".")

    # 1. Validate all docs
    files = Discovery.discover(project_dir, schema)
    validation_results = Enum.map(files, fn file ->
      case Document.parse_file(file) do
        {:ok, doc} ->
          {:ok, diags} = Validation.validate(doc, schema)
          {doc, diags}
        _ -> nil
      end
    end) |> Enum.reject(&is_nil/1)

    errors = Enum.flat_map(validation_results, fn {doc, diags} ->
      Enum.filter(diags, fn {level, _, _} -> level == :error end)
      |> Enum.map(fn {_, code, msg} -> %{file: doc.path, id: doc.id, code: code, message: msg} end)
    end)

    # 2. Find orphans (docs with no refs to/from other docs)
    docs = Enum.map(validation_results, fn {doc, _} -> doc end)
    all_refs = extract_all_refs(docs)
    all_ids = MapSet.new(docs, & &1.id)
    referenced_ids = MapSet.new(all_refs)

    orphans = docs
    |> Enum.filter(fn doc ->
      doc.id != nil and
        doc.id not in referenced_ids and
        not has_outgoing_refs?(doc)
    end)
    |> Enum.map(fn doc -> %{id: doc.id, path: doc.path, title: doc.title} end)

    # 3. Find dangling refs
    dangling = all_refs
    |> Enum.reject(&MapSet.member?(all_ids, &1))
    |> Enum.uniq()

    # 4. Check fixme markers
    fixme_count = Enum.sum(Enum.map(files, fn file ->
      case File.read(file) do
        {:ok, content} ->
          ~w(FIXME TBD TODO XXX)
          |> Enum.map(fn m -> content |> String.split(m) |> length() |> Kernel.-(1) end)
          |> Enum.sum()
        _ -> 0
      end
    end))

    # 5. Code violations
    code_summary = ViolationStore.summary()

    Protocol.encode_ok(%{
      docs: length(files),
      validation_errors: length(errors),
      errors: errors,
      orphaned_docs: length(orphans),
      orphans: orphans,
      dangling_refs: dangling,
      fixme_markers: fixme_count,
      code_violations: code_summary.total,
      clean: length(errors) == 0 and code_summary.total == 0
    })
  end

  defp handle_method("doc.diagnostics", _params) do
    all = DocStore.all()
    diagnostics = Enum.flat_map(all, fn {path, ds} ->
      Enum.map(ds, fn {level, code, msg} ->
        %{file: path, level: to_string(level), code: code, message: msg}
      end)
    end)
    errors = Enum.count(diagnostics, &(&1.level == "error"))
    Protocol.encode_ok(%{total: length(diagnostics), errors: errors, diagnostics: diagnostics})
  end

  defp handle_method(method, _params) do
    Protocol.encode_error("Unknown method: #{method}")
  end

  # ─── Helpers ───────────────────────────────────────────────────────────────

  defp maybe_filter_type(docs, nil), do: docs
  defp maybe_filter_type(docs, type) do
    type_lower = String.downcase(type)
    Enum.filter(docs, &(&1.type == type_lower))
  end

  defp maybe_filter_status(docs, nil), do: docs
  defp maybe_filter_status(docs, status) do
    Enum.filter(docs, &(Map.get(&1.frontmatter, "status") == status))
  end

  defp find_doc_by_id(project_dir, schema, id) do
    id_upper = String.upcase(id)
    Discovery.discover(project_dir, schema)
    |> Enum.find_value(fn file ->
      if String.upcase(Path.basename(file, ".md")) == id_upper do
        Document.parse_file(file)
      end
    end) || {:error, "Document not found: #{id}"}
  end

  defp rebuild_frontmatter(raw, new_fm) do
    yaml = new_fm
    |> Enum.map(fn {k, v} ->
      cond do
        is_list(v) -> "#{k}: [#{Enum.join(v, ", ")}]"
        true -> "#{k}: #{v}"
      end
    end)
    |> Enum.join("\n")

    case String.split(raw, ~r/^---\s*$/m, parts: 3) do
      ["", _old_yaml, body] -> "---\n#{yaml}\n---#{body}"
      _ -> "---\n#{yaml}\n---\n\n#{raw}"
    end
  end

  @ref_fields ~w(supersedes superseded_by enables enabled_by triggers triggered_by
                  depends_on dependency_of implements implemented_by conflicts_with related)

  defp extract_all_refs(docs) do
    Enum.flat_map(docs, fn doc ->
      @ref_fields
      |> Enum.flat_map(fn field ->
        case Map.get(doc.frontmatter, field) do
          refs when is_list(refs) -> refs
          ref when is_binary(ref) -> [ref]
          _ -> []
        end
      end)
    end)
  end

  defp has_outgoing_refs?(doc) do
    Enum.any?(@ref_fields, fn field ->
      case Map.get(doc.frontmatter, field) do
        refs when is_list(refs) and refs != [] -> true
        ref when is_binary(ref) -> true
        _ -> false
      end
    end)
  end

  defp build_fix_instructions(iron_law, missing_docs, missing_tests, doc_errors, file_issues) do
    instructions = []

    instructions = if iron_law > 0 do
      ["Fix #{iron_law} code violation(s): check `explicit violations` for details" | instructions]
    else
      instructions
    end

    instructions = if missing_docs > 0 do
      top_files = file_issues
      |> Enum.filter(fn f -> Map.has_key?(f.issues, "NoPublicWithoutDoc") end)
      |> Enum.take(5)
      |> Enum.map(fn f -> "  #{f.file} (#{f.issues["NoPublicWithoutDoc"]} functions)" end)

      msg = "Add @doc to #{missing_docs} public function(s). Start with:\n" <> Enum.join(top_files, "\n")
      [msg | instructions]
    else
      instructions
    end

    instructions = if missing_tests > 0, do: ["Create test files for #{missing_tests} module(s)" | instructions], else: instructions
    instructions = if doc_errors > 0, do: ["Fix #{doc_errors} doc validation error(s): run `explicit docs validate`" | instructions], else: instructions

    Enum.reverse(instructions)
  end

  # Code file discovery for validate/quality — mirrors Watcher's ignore list
  # so we don't scan _build/, deps/, generator templates, etc.
  # (EXPLICIT-FEEDBACK.md #4)
  @ignored_code_dirs ~w(_build deps .elixir_ls .git node_modules .claude .explicit priv/static)

  defp discover_code_files(project_dir) do
    Path.wildcard(Path.join(project_dir, "**/*.{ex,exs}"))
    |> Enum.reject(&ignored_code_path?/1)
  end

  defp ignored_code_path?(path) do
    path_str = to_string(path)
    Enum.any?(@ignored_code_dirs, &String.contains?(path_str, "/#{&1}/"))
  end

  defp scan_doc_refs(code_files) do
    pattern = ~r/(ADR|OPP|SPEC|INC|POL)-\d{3}/
    Enum.flat_map(code_files, fn file ->
      case File.read(file) do
        {:ok, content} ->
          Regex.scan(pattern, content)
          |> Enum.map(fn [ref | _] -> %{file: file, ref: ref} end)
        _ -> []
      end
    end)
  end

  defp section_to_map(s) do
    base = %{name: s.name, required: s.required, description: s.description}
    if s.children != [] do
      Map.put(base, :children, Enum.map(s.children, &section_to_map/1))
    else
      base
    end
  end
end
