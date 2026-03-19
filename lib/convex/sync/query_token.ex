defmodule Convex.Sync.QueryToken do
  @moduledoc false

  alias Convex.Value

  @type t :: {String.t(), binary()}

  @spec canonicalize_udf_path(String.t()) :: String.t()
  def canonicalize_udf_path(path) when is_binary(path) do
    if String.contains?(path, ":") do
      path
    else
      path <> ":default"
    end
  end

  @spec build(String.t(), map()) :: t()
  def build(udf_path, args) when is_binary(udf_path) and is_map(args) do
    {
      canonicalize_udf_path(udf_path),
      canonical_json([normalize_object(args)])
    }
  end

  @spec canonical_json(list()) :: binary()
  def canonical_json(value) when is_list(value) do
    serialize(value)
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)

  defp normalize_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {key, normalize_value(nested)} end)
    |> Enum.sort_by(fn {key, _} -> key end)
  end

  # Token canonicalization must treat native `1` and `1.0` as the same
  # Convex Float64 query; otherwise identical subscriptions split.
  defp normalize_value(value) when is_integer(value), do: value * 1.0
  defp normalize_value(value), do: Value.encode!(value)

  defp normalize_object(map) do
    map
    |> Enum.map(fn {key, value} -> {key, normalize_value(value)} end)
    |> Enum.sort_by(fn {key, _} -> key end)
  end

  defp serialize(value) when is_list(value) do
    if keywordish?(value) do
      "{" <>
        Enum.map_join(value, ",", fn {key, nested} ->
          Jason.encode!(key) <> ":" <> serialize(nested)
        end) <> "}"
    else
      "[" <> Enum.map_join(value, ",", &serialize/1) <> "]"
    end
  end

  defp serialize(value) when is_map(value) do
    value
    |> normalize_value()
    |> serialize()
  end

  defp serialize(value), do: Jason.encode!(value)

  defp keywordish?(value) do
    Enum.all?(value, fn
      {key, _nested} when is_binary(key) -> true
      _ -> false
    end)
  end
end
