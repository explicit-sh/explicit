defmodule Explicit.CheckerTest do
  use ExUnit.Case

  alias Explicit.Checker

  test "detects String.to_atom" do
    path = write_temp("""
    defmodule Bad do
      def bad(x), do: String.to_atom(x)
    end
    """)

    {:ok, violations} = Checker.check_file(path)
    assert Enum.any?(violations, &(&1.check == "NoStringToAtom"))
    File.rm!(path)
  end

  test "detects missing @doc on public function" do
    path = write_temp("""
    defmodule NoDocs do
      def exposed(x), do: x + 1
    end
    """)

    {:ok, violations} = Checker.check_file(path)
    assert Enum.any?(violations, &(&1.check == "NoPublicWithoutDoc"))
    File.rm!(path)
  end

  test "detects missing @spec on public function" do
    path = write_temp("""
    defmodule NoSpecs do
      def exposed(x), do: x + 1
    end
    """)

    {:ok, violations} = Checker.check_file(path)
    assert Enum.any?(violations, &(&1.check == "NoPublicWithoutSpec"))
    File.rm!(path)
  end

  test "skips private functions" do
    path = write_temp("""
    defmodule Private do
      @doc "Public"
      @spec public(integer()) :: integer()
      def public(x), do: internal(x)

      defp internal(x), do: x + 1
    end
    """)

    {:ok, violations} = Checker.check_file(path)
    assert violations == []
    File.rm!(path)
  end

  test "respects inline suppression" do
    path = write_temp("""
    # explicit:disable NoPublicWithoutDoc NoPublicWithoutSpec
    defmodule Suppressed do
      def exposed(x), do: x + 1
    end
    """)

    {:ok, violations} = Checker.check_file(path)
    refute Enum.any?(violations, &(&1.check == "NoPublicWithoutDoc"))
    refute Enum.any?(violations, &(&1.check == "NoPublicWithoutSpec"))
    File.rm!(path)
  end

  test "skips test files for @doc/@spec" do
    path = write_temp_test("""
    defmodule MyTest do
      def helper(x), do: x
    end
    """)

    {:ok, violations} = Checker.check_file(path)
    refute Enum.any?(violations, &(&1.check == "NoPublicWithoutDoc"))
    File.rm!(path)
  end

  defp write_temp(content) do
    path = Path.join(System.tmp_dir!(), "explicit_test_#{:rand.uniform(999999)}.ex")
    File.write!(path, content)
    path
  end

  defp write_temp_test(content) do
    path = Path.join(System.tmp_dir!(), "explicit_test_#{:rand.uniform(999999)}_test.exs")
    File.write!(path, content)
    path
  end
end
