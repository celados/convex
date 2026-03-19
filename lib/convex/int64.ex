defmodule Convex.Int64 do
  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: integer()}

  @spec new(integer()) :: t()
  def new(value) when is_integer(value), do: %__MODULE__{value: value}
end
