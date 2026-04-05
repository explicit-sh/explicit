defmodule Explicit.Checks.NoDefaultPhoenixPage do
  @moduledoc """
  Detects the default Phoenix landing page that ships with `mix phx.new`.
  The default page should be replaced with actual application content.
  """

  @marker "Peace of mind from prototype to production"

  def check(project_dir) do
    heex_files(project_dir)
    |> Enum.flat_map(&scan_file(project_dir, &1))
  end

  defp heex_files(project_dir) do
    Path.wildcard(Path.join(project_dir, "services/*/lib/**/*.heex")) ++
    Path.wildcard(Path.join(project_dir, "lib/**/*.heex"))
  end

  defp scan_file(project_dir, file) do
    case File.read(file) do
      {:ok, content} ->
        if String.contains?(content, @marker) do
          rel = Path.relative_to(file, project_dir)
          [%{
            file: file,
            line: find_line(content),
            check: "NoDefaultPhoenixPage",
            message: "#{rel} still has the default Phoenix landing page — replace with your app content"
          }]
        else
          []
        end
      _ -> []
    end
  end

  defp find_line(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(1, fn {line, n} ->
      if String.contains?(line, @marker), do: n
    end)
  end
end
