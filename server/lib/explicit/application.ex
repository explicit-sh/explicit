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
    # If EXPLICIT_PROJECT_DIR is set explicitly, trust it — don't walk up for .git.
    # CLI sets this to the correct dir (git root, or CWD fallback).
    case System.get_env("EXPLICIT_PROJECT_DIR") do
      nil ->
        dir =
          case System.argv() do
            [dir | _] -> dir
            _ -> File.cwd!()
          end

        find_git_root(Path.expand(dir), Path.expand(dir))

      env_dir ->
        Path.expand(env_dir)
    end
  end

  defp load_schema(project_dir) do
    case Explicit.Schema.load(project_dir) do
      {:ok, schema} -> schema
      {:error, _} -> %Explicit.Schema{}
    end
  end

  # Walk up from `dir` looking for .git. If we hit "/", fall back to the
  # original starting dir (not File.cwd!, which may be unrelated).
  defp find_git_root("/", original) do
    require Logger
    Logger.warning("No .git directory found above #{original}. Using #{original} as project dir.")
    original
  end

  defp find_git_root(dir, original) do
    if File.dir?(Path.join(dir, ".git")) do
      dir
    else
      parent = Path.dirname(dir)
      if parent == dir, do: find_git_root("/", original), else: find_git_root(parent, original)
    end
  end
end
