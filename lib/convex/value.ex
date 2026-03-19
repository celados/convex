defmodule Convex.Value do
  @moduledoc false

  alias Convex.{Bytes, Int64}

  @special_float_prefix "$float"
  @integer_prefix "$integer"
  @bytes_prefix "$bytes"

  @type t ::
          nil
          | integer()
          | float()
          | boolean()
          | String.t()
          | Bytes.t()
          | Int64.t()
          | [t()]
          | %{String.t() => t()}

  @spec encode(t()) :: {:ok, term()} | {:error, String.t()}
  def encode(value) do
    do_encode(value)
  end

  @spec encode!(t()) :: term()
  def encode!(value) do
    case encode(value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec decode(term()) :: {:ok, t()} | {:error, String.t()}
  def decode(value) do
    do_decode(value)
  end

  @spec decode!(term()) :: t()
  def decode!(value) do
    case decode(value) do
      {:ok, decoded} -> decoded
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec validate_field_name(String.t()) :: :ok | {:error, String.t()}
  def validate_field_name(name) when is_binary(name) do
    cond do
      name == "" ->
        :ok

      byte_size(name) > 1024 ->
        {:error, "Field name exceeds maximum length of 1024"}

      String.starts_with?(name, "$") ->
        {:error, "Field name starts with '$', which is reserved"}

      Enum.any?(:binary.bin_to_list(name), &invalid_field_byte?/1) ->
        {:error, "Field name contains non-ASCII or control characters"}

      true ->
        :ok
    end
  end

  def validate_field_name(_), do: {:error, "Field name must be a string"}

  @spec encode_i64(integer()) :: String.t()
  def encode_i64(value) when is_integer(value) do
    <<value::signed-little-64>>
    |> Base.encode64(padding: true)
  end

  @spec decode_i64(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def decode_i64(encoded) when is_binary(encoded) do
    with {:ok, bytes} <- Base.decode64(encoded, padding: true),
         8 <- byte_size(bytes) do
      <<value::signed-little-64>> = bytes
      {:ok, value}
    else
      :error -> {:error, "Invalid base64 Int64 payload"}
      _ -> {:error, "Int64 payload must be exactly 8 bytes"}
    end
  end

  @spec encode_u64(non_neg_integer()) :: String.t()
  def encode_u64(value)
      when is_integer(value) and value >= 0 and value <= 18_446_744_073_709_551_615 do
    <<value::unsigned-little-64>>
    |> Base.encode64(padding: true)
  end

  @spec decode_u64(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def decode_u64(encoded) when is_binary(encoded) do
    with {:ok, bytes} <- Base.decode64(encoded, padding: true),
         8 <- byte_size(bytes) do
      <<value::unsigned-little-64>> = bytes
      {:ok, value}
    else
      :error -> {:error, "Invalid base64 u64 payload"}
      _ -> {:error, "u64 payload must be exactly 8 bytes"}
    end
  end

  @spec negative_zero?(float()) :: boolean()
  def negative_zero?(value) when is_float(value) do
    <<bits::unsigned-little-64>> = <<value::float-little-64>>
    bits == 0x8000000000000000
  end

  @spec special_float?(float()) :: boolean()
  def special_float?(value) when is_float(value) do
    negative_zero?(value) or value != value or bits_are_infinite?(value)
  end

  defp do_encode(nil), do: {:ok, nil}
  defp do_encode(value) when is_boolean(value), do: {:ok, value}
  defp do_encode(value) when is_binary(value), do: {:ok, value}

  defp do_encode(%Bytes{data: data}),
    do: {:ok, %{@bytes_prefix => Base.encode64(data, padding: true)}}

  defp do_encode(%Int64{value: value}), do: {:ok, %{@integer_prefix => encode_i64(value)}}

  # Convex defaults to treating native integers as Float64; if we pass through integer here,
  # it will mismatch the canonical semantics of decode/query token.
  defp do_encode(value) when is_integer(value), do: {:ok, value * 1.0}

  defp do_encode(value) when is_float(value) do
    if special_float?(value) do
      {:ok, %{@special_float_prefix => Base.encode64(<<value::float-little-64>>, padding: true)}}
    else
      {:ok, value}
    end
  end

  defp do_encode(value) when is_list(value) do
    encode_list(value, [])
  end

  defp do_encode(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {key, nested}, {:ok, acc} when is_binary(key) ->
        case validate_field_name(key) do
          :ok ->
            case do_encode(nested) do
              {:ok, encoded} -> {:cont, {:ok, Map.put(acc, key, encoded)}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      {_key, _nested}, _ ->
        {:halt, {:error, "Object keys must be strings"}}
    end)
  end

  defp do_encode(_), do: {:error, "Unsupported Convex value"}

  defp do_decode(nil), do: {:ok, nil}
  defp do_decode(value) when is_boolean(value), do: {:ok, value}
  defp do_decode(value) when is_binary(value), do: {:ok, value}
  defp do_decode(value) when is_integer(value), do: {:ok, value * 1.0}
  defp do_decode(value) when is_float(value), do: {:ok, value}

  defp do_decode(value) when is_list(value) do
    decode_list(value, [])
  end

  defp do_decode(%{@special_float_prefix => encoded} = value) when map_size(value) == 1 do
    with {:ok, bytes} <- Base.decode64(encoded, padding: true),
         8 <- byte_size(bytes) do
      <<bits::unsigned-little-64>> = bytes

      cond do
        bits == 0x8000000000000000 ->
          {:ok, negative_zero()}

        special_ieee_754_bits?(bits) ->
          # Erlang/Elixir runtime cannot reliably represent NaN/Inf; explicit error is safer than
          # crashing during decode or faking a regular float.
          {:error, "Erlang/Elixir does not support NaN or infinity floats"}

        true ->
          decode_regular_float_tagged(bits)
      end
    else
      :error -> {:error, "Invalid base64 Float64 payload"}
      _ -> {:error, "Float64 payload must be exactly 8 bytes"}
    end
  end

  defp do_decode(%{@integer_prefix => encoded} = value) when map_size(value) == 1 do
    with {:ok, decoded} <- decode_i64(encoded) do
      {:ok, Int64.new(decoded)}
    end
  end

  defp do_decode(%{@bytes_prefix => encoded} = value) when map_size(value) == 1 do
    case Base.decode64(encoded, padding: true) do
      {:ok, bytes} -> {:ok, Bytes.new(bytes)}
      :error -> {:error, "Invalid base64 bytes payload"}
    end
  end

  defp do_decode(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested}, {:ok, acc} ->
      case do_decode(nested) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp do_decode(_), do: {:error, "Unsupported JSON value"}

  defp encode_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp encode_list([head | tail], acc) do
    case do_encode(head) do
      {:ok, encoded} -> encode_list(tail, [encoded | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_list([head | tail], acc) do
    case do_decode(head) do
      {:ok, decoded} -> decode_list(tail, [decoded | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp invalid_field_byte?(byte), do: byte < 0x20 or byte > 0x7E

  defp decode_regular_float_tagged(bits) do
    <<decoded::float-little-64>> = <<bits::unsigned-little-64>>
    {:error, "Float64 should be encoded as a number: #{decoded}"}
  end

  defp bits_are_infinite?(value) do
    <<bits::unsigned-64>> = <<value::float-64>>
    exponent = Bitwise.band(Bitwise.bsr(bits, 52), 0x7FF)
    mantissa = Bitwise.band(bits, 0xFFFFFFFFFFFFF)
    exponent == 0x7FF and mantissa == 0
  end

  defp special_ieee_754_bits?(bits) do
    exponent = Bitwise.band(Bitwise.bsr(bits, 52), 0x7FF)
    exponent == 0x7FF
  end

  defp negative_zero do
    <<value::float-little-64>> = <<0x8000000000000000::unsigned-little-64>>
    value
  end
end
