defmodule Convex.Int64 do
  @moduledoc """
  Wraps an Elixir integer as a Convex Int64 (bigint) on the wire.

  By default, Elixir integers encode as Convex Float64 (matching JS `number` semantics).
  Use this struct when the target Convex field expects a BigInt:

      Convex.mutation(client, "counters:increment", %{"delta" => Convex.Int64.new(1)})
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: integer()}

  @spec new(integer()) :: t()
  def new(value) when is_integer(value), do: %__MODULE__{value: value}
end
