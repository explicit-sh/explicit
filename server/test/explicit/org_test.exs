defmodule Explicit.OrgTest do
  use ExUnit.Case, async: true

  alias Explicit.Org

  describe "find_user_by_email/2" do
    test "finds user by matching email attribute" do
      kdl = """
      org "test" {
        team "engineering" {
          user "onni" name="Onni Hakala" email="onni@flaky.build"
          user "alice" name="Alice" email="alice@example.com"
        }
      }
      """

      assert Org.find_user_by_email(kdl, "onni@flaky.build") == "onni"
      assert Org.find_user_by_email(kdl, "alice@example.com") == "alice"
    end

    test "returns nil when no user matches" do
      kdl = ~s(team "engineering" { user "onni" email="onni@flaky.build" })
      assert Org.find_user_by_email(kdl, "bob@example.com") == nil
    end

    test "returns nil when org.kdl is empty or malformed" do
      assert Org.find_user_by_email("", "onni@flaky.build") == nil
      assert Org.find_user_by_email("not kdl at all", "onni@flaky.build") == nil
    end
  end

  describe "inject_user/4" do
    test "replaces stub comment with real entry" do
      kdl = """
      org "test" {
        team "engineering" {
          // user "onni" name="Onni Hakala"
        }
      }
      """

      result = Org.inject_user(kdl, "onni", "Onni Hakala", "onni@flaky.build")

      assert result =~ ~s(user "onni" name="Onni Hakala" email="onni@flaky.build")
      refute result =~ ~r/\/\/\s*user/
    end

    test "inserts before closing brace when no stub exists" do
      kdl = """
      org "test" {
        team "engineering" {
        }
      }
      """

      result = Org.inject_user(kdl, "onni", "Onni Hakala", "onni@flaky.build")

      assert result =~ ~s(user "onni" name="Onni Hakala" email="onni@flaky.build")
      # Preserves structure
      assert result =~ ~r/team "engineering"/
      assert String.contains?(result, "}")
    end

    test "is a no-op when user already present" do
      kdl = """
      org "test" {
        team "engineering" {
          user "onni" name="Onni Hakala" email="onni@flaky.build"
        }
      }
      """

      result = Org.inject_user(kdl, "onni", "Onni Hakala", "onni@flaky.build")
      assert result == kdl
    end
  end

end
