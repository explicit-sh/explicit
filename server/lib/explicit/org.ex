defmodule Explicit.Org do
  @moduledoc """
  Organization registry lookup and caching for doc authors.

  When a new doc is created via `explicit docs new`, we need to fill the
  required `author` field with a real user id. This module:

  1. Reads `git config user.email` of the current repo.
  2. Looks up the email in `.explicit/org.kdl` — if a matching user exists
     there, returns its id (cached lookup, no network call).
  3. On first encounter, uses `gh api` to look up the GitHub login for
     the email and appends a new `user "..." name="..." email="..."` node
     to `.explicit/org.kdl` under `team "engineering"`. Subsequent calls
     find it in the cache.
  4. Falls back to the email local-part, then `$USER`, then `"unknown"`.

  Fixes EXPLICIT-FEEDBACK.md #5: `explicit docs new` used to produce docs
  missing the required `author` field, which then failed `docs validate`.
  """

  require Logger

  @doc """
  Resolve the author id for the current git user in the given project.
  Returns a string — always succeeds (falls back through the chain).
  """
  def resolve_author(project_dir) do
    email = git_email(project_dir)

    cond do
      # No git email at all — fall back to $USER or "unknown"
      is_nil(email) ->
        fallback_user()

      # Email found — try the cache, then gh, then fallbacks
      true ->
        lookup_cached(project_dir, email) ||
          lookup_via_gh(project_dir, email) ||
          email_local_part(email) ||
          fallback_user()
    end
  end

  @doc "Get git config user.email for the given project directory. Nil if not set."
  def git_email(project_dir) do
    case System.cmd("git", ["-C", project_dir, "config", "user.email"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          email -> email
        end

      _ ->
        nil
    end
  end

  # ─── Cache lookup (read org.kdl, find user by email) ─────────────────────

  defp lookup_cached(project_dir, email) do
    case read_org_kdl(project_dir) do
      {:ok, content} -> find_user_by_email(content, email)
      _ -> nil
    end
  end

  @doc false
  def find_user_by_email(kdl_content, email) do
    # Match: user "<id>" ... email="<email>"
    # Capture the id (first positional arg of the `user` node).
    pattern =
      ~r/user\s+"([^"]+)"[^\n]*email="#{Regex.escape(email)}"/

    case Regex.run(pattern, kdl_content) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp read_org_kdl(project_dir) do
    path = Path.join([project_dir, ".explicit", "org.kdl"])
    File.read(path)
  end

  # ─── `gh` lookup ──────────────────────────────────────────────────────────

  defp lookup_via_gh(project_dir, email) do
    if System.find_executable("gh") do
      case fetch_github_login(email) do
        {:ok, login, name} ->
          append_user_to_org_kdl(project_dir, login, name, email)
          login

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp fetch_github_login(email) do
    # gh api -X GET search/users -f q="<email> in:email" --jq '.items[0].login'
    case System.cmd(
           "gh",
           [
             "api",
             "-X",
             "GET",
             "search/users",
             "-f",
             "q=#{email} in:email",
             "--jq",
             ".items[0].login"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.trim(output) do
          "" -> :error
          login -> {:ok, login, fetch_github_name(login) || login}
        end

      _ ->
        :error
    end
  end

  defp fetch_github_name(login) do
    case System.cmd("gh", ["api", "users/#{login}", "--jq", ".name"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          "null" -> nil
          name -> name
        end

      _ ->
        nil
    end
  end

  # ─── Append to org.kdl ────────────────────────────────────────────────────

  @doc false
  def append_user_to_org_kdl(project_dir, login, name, email) do
    path = Path.join([project_dir, ".explicit", "org.kdl"])

    case File.read(path) do
      {:ok, content} ->
        new_content = inject_user(content, login, name, email)

        if new_content != content do
          File.write!(path, new_content)
          Logger.info("Added user #{login} (#{email}) to #{path}")
        end

      _ ->
        :ok
    end
  end

  @doc false
  # Insert `user "<login>" name="<name>" email="<email>"` inside the
  # `team "engineering" { ... }` block. If a commented-out `// user "..."`
  # line exists there, replace it. Otherwise append before the closing `}`.
  def inject_user(kdl_content, login, name, email) do
    entry = ~s(user "#{login}" name="#{escape_kdl_string(name)}" email="#{email}")

    cond do
      # Already present — no-op
      Regex.match?(~r/user\s+"#{Regex.escape(login)}"[^\n]*email="#{Regex.escape(email)}"/, kdl_content) ->
        kdl_content

      # Has the stub comment — replace with a real entry
      Regex.match?(~r/\/\/\s*user\s+"[^"]*"[^\n]*/, kdl_content) ->
        Regex.replace(
          ~r/\/\/\s*user\s+"[^"]*"[^\n]*/,
          kdl_content,
          entry,
          global: false
        )

      # Find `team "engineering" { ... }` and insert before closing `}`
      Regex.match?(~r/team\s+"engineering"\s*\{/, kdl_content) ->
        inject_before_team_close(kdl_content, "engineering", entry)

      true ->
        kdl_content
    end
  end

  defp inject_before_team_close(content, team_name, entry) do
    # Find "team \"engineering\" {" then the next "}" on its own line
    # and insert entry before it with matching indentation.
    lines = String.split(content, "\n")
    do_inject_team(lines, team_name, entry, [], false)
  end

  defp do_inject_team([], _team_name, _entry, acc, _inside), do: Enum.join(Enum.reverse(acc), "\n")

  defp do_inject_team([line | rest], team_name, entry, acc, inside) do
    cond do
      not inside and Regex.match?(~r/team\s+"#{Regex.escape(team_name)}"\s*\{/, line) ->
        do_inject_team(rest, team_name, entry, [line | acc], true)

      inside and Regex.match?(~r/^\s*\}\s*$/, line) ->
        # Insert entry with team's indentation + 2 spaces before closing brace
        indent = extract_indent(line) <> "  "
        inserted = indent <> entry
        # Stop injecting after first match
        (Enum.reverse([line, inserted | acc]) ++ rest)
        |> Enum.join("\n")

      true ->
        do_inject_team(rest, team_name, entry, [line | acc], inside)
    end
  end

  defp extract_indent(line) do
    case Regex.run(~r/^(\s*)/, line) do
      [_, indent] -> indent
      _ -> ""
    end
  end

  defp escape_kdl_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  # ─── Fallbacks ───────────────────────────────────────────────────────────

  defp email_local_part(email) do
    case String.split(email, "@", parts: 2) do
      [local, _domain] when byte_size(local) > 0 -> local
      _ -> nil
    end
  end

  defp fallback_user do
    System.get_env("USER") || "unknown"
  end
end
