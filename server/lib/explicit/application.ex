defmodule Explicit.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    project_dir = resolve_project_dir()
    Application.put_env(:explicit, :project_dir, project_dir)

    # Load schema on boot
    schema = load_schema(project_dir)
    Application.put_env(:explicit, :schema, schema)

    children = [
      Explicit.ViolationStore,
      Explicit.DocStore,
      {Explicit.Watcher, project_dir},
      Explicit.SocketServer
    ]

    opts = [strategy: :one_for_one, name: Explicit.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp resolve_project_dir do
    dir =
      System.get_env("EXPLICIT_PROJECT_DIR") ||
        case System.argv() do
          [dir | _] -> dir
          _ -> File.cwd!()
        end

    find_git_root(Path.expand(dir))
  end

  defp load_schema(project_dir) do
    case Explicit.Schema.load(project_dir) do
      {:ok, schema} -> schema
      {:error, _} -> %Explicit.Schema{}
    end
  end

  defp find_git_root("/"), do: File.cwd!()

  defp find_git_root(dir) do
    if File.dir?(Path.join(dir, ".git")) do
      dir
    else
      find_git_root(Path.dirname(dir))
    end
  end
end
