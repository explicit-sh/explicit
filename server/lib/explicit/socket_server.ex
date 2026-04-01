defmodule Explicit.SocketServer do
  @moduledoc """
  gen_tcp-based Unix domain socket server.
  Listens on /tmp/explicit-{hash}.sock for JSONL requests.
  Hash is derived from the git root directory.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def socket_path do
    dir = Application.get_env(:explicit, :project_dir) || File.cwd!()
    hash = :crypto.hash(:md5, dir) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "/tmp/explicit-#{hash}.sock"
  end

  @impl true
  def init(_opts) do
    path = socket_path()
    File.rm(path)

    case :gen_tcp.listen(0, [
           :binary,
           packet: :line,
           ip: {:local, path},
           active: false,
           reuseaddr: true
         ]) do
      {:ok, listen_socket} ->
        Logger.info("Explicit server listening on #{path}")
        Task.start_link(fn -> accept_loop(listen_socket) end)
        {:ok, %{listen_socket: listen_socket, path: path}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen_socket)
    File.rm(state.path)
    :ok
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client} ->
        Task.start(fn -> Explicit.ConnectionHandler.handle(client) end)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("Accept error: #{inspect(reason)}")
        accept_loop(listen_socket)
    end
  end
end
