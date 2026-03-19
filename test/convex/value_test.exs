defmodule Convex.ValueTest do
  use ExUnit.Case, async: true

  alias Convex.{Bytes, Int64, Value}

  test "encodes and decodes int64" do
    assert {:ok, %{"$integer" => "KgAAAAAAAAA="}} = Value.encode(Int64.new(42))
    assert {:ok, %Int64{value: 42}} = Value.decode(%{"$integer" => "KgAAAAAAAAA="})
  end

  test "encodes and decodes bytes" do
    assert {:ok, %{"$bytes" => "AQID"}} = Value.encode(Bytes.new(<<1, 2, 3>>))
    assert {:ok, %Bytes{data: <<1, 2, 3>>}} = Value.decode(%{"$bytes" => "AQID"})
  end

  test "special floats use tagged encoding" do
    neg_zero = negative_zero()

    assert {:ok, %{"$float" => "AAAAAAAAAIA="}} = Value.encode(neg_zero)
    assert {:ok, decoded} = Value.decode(%{"$float" => "AAAAAAAAAIA="})
    assert Value.negative_zero?(decoded)
  end

  test "regular float in tagged encoding is rejected" do
    encoded = Base.encode64(<<3.14::float-little-64>>, padding: true)

    assert {:error, reason} = Value.decode(%{"$float" => encoded})
    assert String.starts_with?(reason, "Float64 should be encoded as a number")
  end

  test "field name validation enforces reserved prefix and ascii" do
    assert {:error, "Field name starts with '$', which is reserved"} =
             Value.validate_field_name("$integer")

    assert {:error, "Field name contains non-ASCII or control characters"} =
             Value.validate_field_name("bad" <> <<0>>)

    assert :ok = Value.validate_field_name("with spaces")
  end

  test "json integer decodes into float64" do
    assert {:ok, 42.0} = Value.decode(42)
  end

  test "native integer encodes as float64 for roundtrip symmetry" do
    assert {:ok, 42.0} = Value.encode(42)
    assert {:ok, 42.0} = 42 |> Value.encode!() |> Value.decode()
  end

  test "infinity and nan tagged floats fail explicitly instead of crashing" do
    assert {:error, "Erlang/Elixir does not support NaN or infinity floats"} =
             Value.decode(%{"$float" => "AAAAAAAA8H8="})

    assert {:error, "Erlang/Elixir does not support NaN or infinity floats"} =
             Value.decode(%{"$float" => "AAAAAAAA8P8="})

    assert {:error, "Erlang/Elixir does not support NaN or infinity floats"} =
             Value.decode(%{"$float" => "AAAAAAAA+H8="})
  end

  defp negative_zero do
    <<value::float-little-64>> = <<0x8000000000000000::unsigned-little-64>>
    value
  end
end
