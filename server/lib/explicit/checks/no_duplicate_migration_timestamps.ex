defmodule Explicit.Checks.NoDuplicateMigrationTimestamps do
  @moduledoc """
  Detects Ecto migrations that share the same timestamp.
  Duplicate timestamps cause `Ecto.MigrationError` at runtime.
  """

  def check(project_dir) do
    migration_dirs(project_dir)
    |> Enum.flat_map(&scan_dir(project_dir, &1))
  end

  defp migration_dirs(project_dir) do
    service_dirs = Path.wildcard(Path.join(project_dir, "services/*/priv/repo/migrations"))
    root_dir = Path.join(project_dir, "priv/repo/migrations")

    (service_dirs ++ [root_dir])
    |> Enum.filter(&File.dir?/1)
  end

  defp scan_dir(project_dir, dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.group_by(fn filename ->
      case Regex.run(~r/^(\d+)_/, filename) do
        [_, ts] -> ts
        _ -> nil
      end
    end)
    |> Enum.filter(fn {ts, files} -> ts != nil and length(files) > 1 end)
    |> Enum.flat_map(fn {ts, files} ->
      Enum.map(files, fn filename ->
        file = Path.join(dir, filename)
        rel = Path.relative_to(file, project_dir)
        %{
          file: file,
          line: 0,
          check: "NoDuplicateMigrationTimestamps",
          message: "Migration #{rel} shares timestamp #{ts} with #{length(files) - 1} other migration(s)"
        }
      end)
    end)
  end
end
