defmodule Explicit.Checks.NoTestInLibDir do
  @moduledoc """
  Detects _test.exs files placed in lib/ instead of test/.
  Test files belong in test/ — having them in lib/ means they compile
  into the app but aren't discovered by `mix test`.
  """

  def check(project_dir) do
    lib_dirs(project_dir)
    |> Enum.flat_map(&scan_dir(project_dir, &1))
  end

  defp lib_dirs(project_dir) do
    service_libs = Path.wildcard(Path.join(project_dir, "services/*/lib"))
    root_lib = Path.join(project_dir, "lib")

    (service_libs ++ [root_lib])
    |> Enum.filter(&File.dir?/1)
  end

  defp scan_dir(project_dir, lib_dir) do
    lib_dir
    |> Path.join("**/*_test.exs")
    |> Path.wildcard()
    |> Enum.map(fn file ->
      rel = Path.relative_to(file, project_dir)
      expected = rel |> String.replace(~r/^(services\/[^\/]+\/)?lib\//, "\\1test/")
      %{
        file: file,
        line: 0,
        check: "NoTestInLibDir",
        message: "Test file #{rel} is in lib/ — move to #{expected}"
      }
    end)
  end
end
