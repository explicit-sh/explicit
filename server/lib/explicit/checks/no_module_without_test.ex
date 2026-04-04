defmodule Explicit.Checks.NoModuleWithoutTest do
  @moduledoc """
  Detects Elixir modules in lib/ that have no corresponding test file in test/.
  Standard Elixir convention: lib/my_app/foo.ex → test/my_app/foo_test.exs
  """

  @skip_patterns [
    ~r/application\.ex$/,
    ~r/repo\.ex$/,
    ~r/endpoint\.ex$/,
    ~r/telemetry\.ex$/,
    ~r/gettext\.ex$/,
    ~r/router\.ex$/,
    ~r/mailer\.ex$/,
    ~r/layouts\.ex$/,
    ~r/_web\.ex$/,
    ~r/\.html\.ex$/,
    ~r/_html\.ex$/,
    ~r/_json\.ex$/,
    ~r/_controller\.ex$/,
    ~r/_live\.ex$/,
    ~r/_components\.ex$/,
    ~r/migration/,
    ~r/seeds\.exs$/,
    ~r/scope\.ex$/
  ]

  @doc """
  Check a project directory for lib files without test files.
  Returns a list of violation maps.
  """
  def check(project_dir) do
    lib_dir = find_lib_dir(project_dir)
    test_dir = find_test_dir(project_dir)

    if lib_dir && test_dir do
      lib_files = Path.wildcard(Path.join(lib_dir, "**/*.ex"))
      test_files = Path.wildcard(Path.join(test_dir, "**/*_test.exs"))
                   |> MapSet.new(&Path.basename(&1, "_test.exs"))

      lib_files
      |> Enum.reject(&skip?/1)
      |> Enum.reject(fn file ->
        basename = Path.basename(file, ".ex")
        MapSet.member?(test_files, basename)
      end)
      |> Enum.map(fn file ->
        rel = Path.relative_to(file, project_dir)
        expected = expected_test_path(rel)
        %{
          file: file,
          line: 0,
          check: "NoModuleWithoutTest",
          message: "Module #{rel} has no test file (expected #{expected})"
        }
      end)
    else
      []
    end
  end

  defp find_lib_dir(project_dir) do
    service_libs = Path.wildcard(Path.join(project_dir, "services/*/lib"))
    candidates = service_libs ++ [Path.join(project_dir, "lib")]
    Enum.find(candidates, &File.dir?/1)
  end

  defp find_test_dir(project_dir) do
    service_tests = Path.wildcard(Path.join(project_dir, "services/*/test"))
    candidates = service_tests ++ [Path.join(project_dir, "test")]
    Enum.find(candidates, &File.dir?/1)
  end

  defp skip?(path) do
    path_str = to_string(path)
    Enum.any?(@skip_patterns, &Regex.match?(&1, path_str)) or
      String.contains?(path_str, "/components/") or
      String.contains?(path_str, "/plugs/")
  end

  defp expected_test_path(lib_path) do
    # services/stuffix/lib/stuffix/foo.ex → services/stuffix/test/stuffix/foo_test.exs
    # lib/my_app/foo.ex → test/my_app/foo_test.exs
    lib_path
    |> String.replace(~r/^(services\/[^\/]+\/)?lib\//, "\\1test/")
    |> String.replace(~r/\.ex$/, "_test.exs")
  end
end
