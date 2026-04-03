defmodule ExplicitTest do
  use ExUnit.Case

  test "schema loads from priv" do
    {:ok, schema} = Explicit.Schema.parse(Explicit.Schema.default_schema())
    assert length(schema.types) > 0
  end
end
