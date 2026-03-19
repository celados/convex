defmodule Convex.ConvexError do
  @enforce_keys [:message]
  defexception [:message, :data]

  @type t :: %__MODULE__{
          message: String.t(),
          data: term()
        }
end
