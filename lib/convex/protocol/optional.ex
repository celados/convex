defmodule Convex.Protocol.Optional do
  @moduledoc false
  @type t(value) :: :absent | {:present, value}

  @spec absent() :: :absent
  def absent, do: :absent

  @spec present(value) :: {:present, value} when value: var
  def present(value), do: {:present, value}

  @spec put_if_present(map(), atom() | String.t(), t(term())) :: map()
  def put_if_present(map, _key, :absent), do: map
  def put_if_present(map, key, {:present, value}), do: Map.put(map, key, value)

  @spec fetch(map(), atom() | String.t()) :: t(term())
  def fetch(map, key) do
    if Map.has_key?(map, key) do
      {:present, Map.fetch!(map, key)}
    else
      :absent
    end
  end
end
