defmodule Explicit.Checks.NoDbQueryInMount do
  @moduledoc """
  Iron Law: NO DATABASE QUERIES IN MOUNT.
  mount/3 is called TWICE (HTTP + WebSocket). Queries in mount = duplicate queries.
  Move data loading to handle_params/3.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [excluded_paths: [~r/_test\.exs$/]],
    explanations: [
      check: """
      LiveView mount/3 is called twice: once for the HTTP request, once for
      the WebSocket connection. Database queries in mount run twice.
      Move them to handle_params/3 which runs once per navigation.
      """
    ]

  @repo_functions ~w(all get get! get_by get_by! one one! aggregate)

  @impl true
  def run(%SourceFile{} = source_file, params) do
    excluded = Params.get(params, :excluded_paths, __MODULE__)

    if Enum.any?(excluded, &Regex.match?(&1, source_file.filename)) do
      []
    else
      source = SourceFile.source(source_file)
      issue_meta = IssueMeta.for(source_file, params)
      check_mount_queries(source, issue_meta)
    end
  end

  defp check_mount_queries(source, issue_meta) do
    lines = String.split(source, "\n")
    {in_mount, issues} = Enum.reduce(Enum.with_index(lines, 1), {false, []}, fn {line, line_no}, {in_mount, issues} ->
      trimmed = String.trim(line)
      cond do
        String.starts_with?(trimmed, "def mount(") ->
          {true, issues}
        in_mount and (String.starts_with?(trimmed, "def ") or String.starts_with?(trimmed, "defp ")) ->
          {false, issues}
        in_mount and has_repo_call?(trimmed) ->
          issue = format_issue(issue_meta,
            message: "Database query in mount/3 — move to handle_params/3. mount is called twice (HTTP + WebSocket).",
            trigger: "Repo",
            line_no: line_no
          )
          {true, [issue | issues]}
        true ->
          {in_mount, issues}
      end
    end)
    _ = in_mount
    Enum.reverse(issues)
  end

  defp has_repo_call?(line) do
    Enum.any?(@repo_functions, fn func ->
      String.contains?(line, "Repo.#{func}")
    end)
  end
end
