defmodule Convex.Sync.QueryTokenTest do
  use ExUnit.Case, async: true

  alias Convex.Sync.QueryToken

  test "query tokens ignore top-level map insertion order" do
    assert QueryToken.build("messages:list", %{"b" => 1, "a" => 2}) ==
             QueryToken.build("messages:list", %{"a" => 2, "b" => 1})
  end

  test "query tokens sort nested objects recursively" do
    assert {"messages:list", ~s([{"x":{"a":2.0,"z":1.0}}])} ==
             QueryToken.build("messages:list", %{"x" => %{"z" => 1, "a" => 2}})
  end

  test "native integers and floats canonicalize to the same Float64 token" do
    assert QueryToken.build("messages:list", %{"count" => 1}) ==
             QueryToken.build("messages:list", %{"count" => 1.0})
  end

  test "udf path without colon canonicalizes to default function" do
    assert {"messages:default", "[{}]"} = QueryToken.build("messages", %{})
  end
end
