defmodule Convex.ConvexError do
  @moduledoc """
  Application-level error returned by Convex functions via `ConvexError`.

  When a Convex function throws a `ConvexError` with structured `data`,
  the client returns `{:error, %Convex.ConvexError{message: msg, data: data}}`.

  A plain server error (no `errorData` field) returns `{:error, message}` instead.
  """

  @enforce_keys [:message]
  defexception [:message, :data]

  @type t :: %__MODULE__{
          message: String.t(),
          data: term()
        }
end
