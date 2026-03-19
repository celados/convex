defmodule Convex.Bytes do
  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: binary()}

  @spec new(binary()) :: t()
  def new(data) when is_binary(data), do: %__MODULE__{data: data}
end
