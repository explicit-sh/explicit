defmodule ExplicitTest do
  use ExUnit.Case
  doctest Explicit

  test "greets the world" do
    assert Explicit.hello() == :world
  end
end
