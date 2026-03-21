defmodule Convex.Bytes do
  @moduledoc """
  Wraps a binary as a Convex Bytes value on the wire.

      Convex.mutation(client, "files:upload", %{"data" => Convex.Bytes.new(<<1, 2, 3>>)})
  """

  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: binary()}

  @spec new(binary()) :: t()
  def new(data) when is_binary(data), do: %__MODULE__{data: data}
end
