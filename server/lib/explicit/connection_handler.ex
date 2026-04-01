defmodule Explicit.ConnectionHandler do
  @moduledoc """
  Handles a single client connection: reads JSON line, dispatches, responds.
  """

  alias Explicit.{Protocol, ViolationStore, Checker}

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

  defp handle_method("status", _params) do
    summary = ViolationStore.summary()
    watching = Application.get_env(:explicit, :watching_dir)

    Protocol.encode_ok(%{
      watching: watching,
      total_violations: summary.total,
      files_checked: summary.files,
      by_check: summary.by_check
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
    # Send response before stopping
    response = Protocol.encode_ok(%{stopped: true})

    Task.start(fn ->
      Process.sleep(100)
      System.stop(0)
    end)

    response
  end

  defp handle_method(method, _params) do
    Protocol.encode_error("Unknown method: #{method}")
  end
end
