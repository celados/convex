defmodule Convex.Auth.Token do
  @moduledoc """
  A validated Convex authentication token.
  """

  alias Convex.Auth.Identity

  @enforce_keys [:type, :credential]
  defstruct [:type, :credential, :acting_as]

  @type t :: %__MODULE__{}

  @doc "Builds a user JWT token."
  @spec user(String.t()) :: t()
  def user(credential) when is_binary(credential) and credential != "" do
    %__MODULE__{type: :user, credential: credential, acting_as: nil}
  end

  def user(_credential), do: raise(ArgumentError, "User credential must be a non-empty string")

  @doc "Builds a deployment-admin token."
  @spec admin(String.t()) :: t()
  def admin(credential) when is_binary(credential) and credential != "" do
    %__MODULE__{type: :admin, credential: credential, acting_as: nil}
  end

  @doc "Builds a deployment-admin token acting as the supplied identity."
  @spec admin(String.t(), Identity.t() | nil) :: t()
  def admin(credential, nil) when is_binary(credential) and credential != "" do
    admin(credential)
  end

  def admin(credential, %Identity{} = identity)
      when is_binary(credential) and credential != "" do
    %__MODULE__{type: :admin, credential: credential, acting_as: identity}
  end

  def admin(_credential, _identity),
    do:
      raise(
        ArgumentError,
        "Admin credential must be a non-empty string and acting_as an Identity"
      )

  @doc "Builds the anonymous token."
  @spec none() :: t()
  def none, do: %__MODULE__{type: :none, credential: nil, acting_as: nil}

  @doc false
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{type: :user, credential: credential, acting_as: nil})
      when is_binary(credential) and credential != "",
      do: true

  def valid?(%__MODULE__{type: :admin, credential: credential, acting_as: nil})
      when is_binary(credential) and credential != "",
      do: true

  def valid?(%__MODULE__{type: :admin, credential: credential, acting_as: %Identity{}}),
    do: is_binary(credential) and credential != ""

  def valid?(%__MODULE__{type: :none, credential: nil, acting_as: nil}), do: true
  def valid?(_token), do: false
end

defimpl Inspect, for: Convex.Auth.Token do
  import Inspect.Algebra

  def inspect(token, options) do
    concat([
      "#Convex.Auth.Token<type: ",
      to_doc(token.type, options),
      ", credential: \"<redacted>\"",
      acting_as_inspection(token.acting_as, options),
      ">"
    ])
  end

  defp acting_as_inspection(nil, _options), do: ""

  defp acting_as_inspection(identity, options) do
    concat([", acting_as: ", to_doc(identity, options)])
  end
end
