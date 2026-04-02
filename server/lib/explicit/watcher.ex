defmodule Explicit.Watcher do
  @moduledoc """
  File system watcher that triggers re-checks on .ex/.exs file changes.
  Auto-starts watching the project directory on boot.
  """

  use GenServer
  require Logger

  @debounce_ms 200
  @ignored_dirs ~w(_build deps .elixir_ls .git node_modules)

  def start_link(project_dir) do
    GenServer.start_link(__MODULE__, project_dir, name: __MODULE__)
  end

  @doc """
  Start watching a different directory.
  """
  def watch(dir) do
    GenServer.call(__MODULE__, {:watch, dir})
  end

  @impl true
  def init(project_dir) do
    # Auto-start watching on boot
    send(self(), {:start_watch, project_dir})
    {:ok, %{fs_pid: nil, dir: nil, debounce_timer: nil, pending_files: MapSet.new()}}
  end

  @impl true
  def handle_call({:watch, dir}, _from, state) do
    case start_watching(dir, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:start_watch, dir}, state) do
    case start_watching(dir, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, reason} ->
        Logger.error("Failed to start watching #{dir}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, {path, _events}}, state) do
    if watched_file?(path) and not ignored?(path) do
      pending = MapSet.put(state.pending_files, to_string(path))

      timer =
        if state.debounce_timer do
          Process.cancel_timer(state.debounce_timer)
          Process.send_after(self(), :flush, @debounce_ms)
        else
          Process.send_after(self(), :flush, @debounce_ms)
        end

      {:noreply, %{state | pending_files: pending, debounce_timer: timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    Logger.warning("File watcher stopped")
    {:noreply, %{state | fs_pid: nil}}
  end

  def handle_info(:flush, state) do
    # Offload checks to avoid blocking the watcher GenServer mailbox
    for file <- state.pending_files do
      Task.start(fn ->
        if File.exists?(file) do
          check_file(file)
        else
          Explicit.ViolationStore.put(file, [])
          Explicit.DocStore.put(file, [])
        end
      end)
    end

    {:noreply, %{state | pending_files: MapSet.new(), debounce_timer: nil}}
  end

  defp check_file(file) do
    cond do
      elixir_file?(file) ->
        case Explicit.Checker.check_and_store(file) do
          {:ok, violations} ->
            if violations != [] do
              Logger.info("#{length(violations)} violation(s) in #{Path.basename(file)}")
            end
          {:error, msg} ->
            Logger.warning("Check failed for #{file}: #{msg}")
        end

      doc_file?(file) ->
        check_doc(file)

      true ->
        :ok
    end
  end

  defp check_doc(file) do
    schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})

    with {:ok, doc} <- Explicit.Doc.Document.parse_file(file),
         {:ok, diagnostics} <- Explicit.Doc.Validation.validate(doc, schema) do
      Explicit.DocStore.put(file, diagnostics)
      errors = Enum.count(diagnostics, fn {level, _, _} -> level == :error end)
      if errors > 0 do
        Logger.info("#{errors} doc error(s) in #{Path.basename(file)}")
      end
    else
      {:error, msg} ->
        Logger.warning("Doc check failed for #{file}: #{msg}")
    end
  end

  defp start_watching(dir, state) do
    if state.fs_pid do
      GenServer.stop(state.fs_pid, :normal)
    end

    abs_dir = Path.expand(dir)

    case FileSystem.start_link(dirs: [abs_dir], latency: 0, no_defer: true) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        Logger.info("Watching #{abs_dir} for changes")
        scan_directory(abs_dir)
        Application.put_env(:explicit, :watching_dir, abs_dir)
        {:ok, %{state | fs_pid: pid, dir: abs_dir}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scan_directory(dir) do
    Task.start(fn ->
      # Scan Elixir files
      dir
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.reject(&ignored?/1)
      |> Enum.each(&Explicit.Checker.check_and_store/1)

      # Scan doc files
      schema = Application.get_env(:explicit, :schema, %Explicit.Schema{})
      Explicit.Doc.Discovery.discover(dir, schema)
      |> Enum.each(&check_doc/1)

      code_summary = Explicit.ViolationStore.summary()
      doc_summary = Explicit.DocStore.summary()
      Logger.info("Initial scan: #{code_summary.files} code files (#{code_summary.total} violations), #{doc_summary.files} docs (#{doc_summary.errors} errors)")
    end)
  end

  defp watched_file?(path) do
    elixir_file?(path) or doc_file?(path)
  end

  defp elixir_file?(path) do
    ext = Path.extname(to_string(path))
    ext in [".ex", ".exs"]
  end

  defp doc_file?(path) do
    ext = Path.extname(to_string(path))
    ext == ".md" and not ignored?(path)
  end

  defp ignored?(path) do
    path_str = to_string(path)
    Enum.any?(@ignored_dirs, &String.contains?(path_str, "/#{&1}/"))
  end
end
