defmodule Eval.Workspace do
  @moduledoc "Create temporary project workspaces for eval runs."

  require Logger

  @doc "Create a temp project with explicit init, return workspace path"
  def create(name \\ "eval_project") do
    base = Path.join(System.tmp_dir!(), "explicit_eval_#{:rand.uniform(999999)}")
    File.mkdir_p!(base)

    project_dir = Path.join(base, name)

    # Find explicit binary
    explicit = find_explicit()

    # Create project with explicit init <name>
    Logger.info("Running: #{explicit} init #{name}")
    {output, code} = System.cmd(explicit, ["init", name], cd: base, stderr_to_stdout: true)
    if code != 0, do: Logger.warning("explicit init exit #{code}: #{output}")

    # Run explicit init inside (creates schema, skills, hooks)
    # This needs the server — but init <name> already creates basic structure
    # The server-based init happens when we cd into the project

    # Configure git (no signing, dummy user)
    System.cmd("git", ["config", "user.name", "eval"], cd: project_dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "eval@localhost"], cd: project_dir, stderr_to_stdout: true)
    System.cmd("git", ["config", "commit.gpgsign", "false"], cd: project_dir, stderr_to_stdout: true)

    # Create initial commit (Claude Code requires it)
    System.cmd("git", ["add", "-A"], cd: project_dir, stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "Initial commit", "--no-gpg-sign"],
      cd: project_dir, stderr_to_stdout: true)

    project_dir
  end

  defp find_explicit do
    # Check common locations
    candidates = [
      Path.expand("../../debug/explicit", __DIR__),
      Path.expand("../../cli/explicit", __DIR__),
      "explicit"
    ]

    Enum.find(candidates, "explicit", &File.exists?/1)
  end
end
