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

  defp handle_method("stop", _params) do
    response = Protocol.encode_ok(%{stopped: true})
    Task.start(fn -> Process.sleep(100); System.stop(0) end)
    response
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
        types = Enum.map(schema.types, fn t ->
          %{name: t.name, description: t.description, folder: t.folder,
            aliases: t.aliases, fields: length(t.fields), sections: length(t.sections)}
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

  defp section_to_map(s) do
    base = %{name: s.name, required: s.required, description: s.description}
    if s.children != [] do
      Map.put(base, :children, Enum.map(s.children, &section_to_map/1))
    else
      base
    end
  end
end
