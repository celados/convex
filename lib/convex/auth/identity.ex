defmodule Convex.Auth.Identity do
  @moduledoc """
  Validated identity attributes for an admin acting as a user.
  """

  @enforce_keys [:token_identifier]
  defstruct [
    :token_identifier,
    :issuer,
    :subject,
    :name,
    :given_name,
    :family_name,
    :nickname,
    :preferred_username,
    :profile_url,
    :picture_url,
    :website_url,
    :email,
    :email_verified,
    :gender,
    :birthday,
    :timezone,
    :language,
    :phone_number,
    :phone_number_verified,
    :address,
    :updated_at,
    custom_claims: %{}
  ]

  @type t :: %__MODULE__{}

  @string_fields [
    :issuer,
    :subject,
    :name,
    :given_name,
    :family_name,
    :nickname,
    :preferred_username,
    :profile_url,
    :picture_url,
    :website_url,
    :email,
    :gender,
    :birthday,
    :timezone,
    :language,
    :phone_number,
    :address,
    :updated_at
  ]

  @wire_fields [
    token_identifier: "tokenIdentifier",
    issuer: "issuer",
    subject: "subject",
    name: "name",
    given_name: "givenName",
    family_name: "familyName",
    nickname: "nickname",
    preferred_username: "preferredUsername",
    profile_url: "profileUrl",
    picture_url: "pictureUrl",
    website_url: "websiteUrl",
    email: "email",
    email_verified: "emailVerified",
    gender: "gender",
    birthday: "birthday",
    timezone: "timezone",
    language: "language",
    phone_number: "phoneNumber",
    phone_number_verified: "phoneNumberVerified",
    address: "address",
    updated_at: "updatedAt"
  ]

  @reserved_claim_keys Enum.map(@wire_fields, &elem(&1, 1))

  @doc """
  Builds an admin impersonation identity.

  Accepts atom-keyed keyword lists or maps. Supply `token_identifier`, or both
  `issuer` and `subject`; the latter are normalized to the upstream identifier
  format. Custom claims are JSON values and are flattened into the wire identity.
  """
  @spec new(keyword() | map()) :: t()
  def new(attributes) when is_list(attributes) do
    validate_duplicate_fields(attributes)
    new(Map.new(attributes))
  end

  def new(attributes) when is_map(attributes) do
    attributes = Map.new(attributes)
    validate_unknown_fields(Map.keys(attributes))
    validate_string_fields(attributes)
    validate_boolean_fields(attributes)
    validate_custom_claims(attributes)

    token_identifier =
      case Map.get(attributes, :token_identifier) do
        nil -> derive_token_identifier(attributes)
        value -> validate_non_empty_string(:token_identifier, value)
      end

    struct!(__MODULE__, Map.put(attributes, :token_identifier, token_identifier))
  end

  def new(_attributes),
    do: raise(ArgumentError, "Identity attributes must be a keyword list or map")

  @doc false
  @spec serialize(t()) :: {:ok, map()} | {:error, String.t()}
  def serialize(%__MODULE__{} = identity) do
    with :ok <- validate_serialized_identity(identity),
         {:ok, custom_claims} <- serialize_custom_claims(identity.custom_claims) do
      standard =
        Enum.reduce(@wire_fields, %{}, fn {field, wire_name}, acc ->
          case Map.get(identity, field) do
            nil -> acc
            value -> Map.put(acc, wire_name, value)
          end
        end)

      # Custom claims are flattened by the official wire adapter, not nested under customClaims.
      {:ok, Map.merge(standard, custom_claims)}
    end
  end

  defp validate_unknown_fields(keys) do
    allowed =
      [:token_identifier, :custom_claims] ++
        @string_fields ++ [:email_verified, :phone_number_verified]

    invalid = Enum.filter(keys, &(&1 not in allowed))

    if invalid != [] do
      raise ArgumentError, "Unknown identity fields: #{inspect(invalid)}"
    end
  end

  defp validate_duplicate_fields(attributes) do
    duplicates =
      attributes
      |> Keyword.keys()
      |> Enum.frequencies()
      |> Enum.filter(fn {_field, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "Identity duplicate fields: #{inspect(duplicates)}"
    end
  end

  defp validate_string_fields(attributes) do
    Enum.each(@string_fields, fn field ->
      case Map.get(attributes, field) do
        nil -> :ok
        value when is_binary(value) -> :ok
        _value -> raise ArgumentError, "Identity field #{field} must be a string"
      end
    end)
  end

  defp validate_boolean_fields(attributes) do
    Enum.each([:email_verified, :phone_number_verified], fn field ->
      case Map.get(attributes, field) do
        nil -> :ok
        value when is_boolean(value) -> :ok
        _value -> raise ArgumentError, "Identity field #{field} must be a boolean"
      end
    end)
  end

  defp validate_custom_claims(attributes) do
    case Map.get(attributes, :custom_claims, %{}) do
      claims when is_map(claims) ->
        Enum.each(claims, fn
          {key, value} when is_binary(key) and key != "" ->
            if key in @reserved_claim_keys do
              raise ArgumentError, "Identity custom claim key #{key} is reserved"
            end

            case Jason.encode(value) do
              {:ok, _json} ->
                :ok

              {:error, _reason} ->
                raise ArgumentError, "Identity custom claim #{key} must be JSON encodable"
            end

          _invalid ->
            raise ArgumentError, "Identity custom claim keys must be non-empty strings"
        end)

      _claims ->
        raise ArgumentError, "Identity custom_claims must be a map"
    end
  end

  defp validate_serialized_identity(identity) do
    with :ok <- validate_serialized_string_fields(identity),
         :ok <- validate_serialized_boolean_fields(identity),
         :ok <- validate_serialized_identifier(identity),
         :ok <- validate_serialized_claims(identity) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_serialized_string_fields(identity) do
    if Enum.all?(@string_fields, fn field ->
         value = Map.get(identity, field)
         is_nil(value) or is_binary(value)
       end) do
      :ok
    else
      {:error, "Identity optional string fields must be strings"}
    end
  end

  defp validate_serialized_boolean_fields(identity) do
    if Enum.all?([:email_verified, :phone_number_verified], fn field ->
         value = Map.get(identity, field)
         is_nil(value) or is_boolean(value)
       end) do
      :ok
    else
      {:error, "Identity verification fields must be booleans"}
    end
  end

  defp validate_serialized_identifier(identity) do
    if is_binary(identity.token_identifier) and identity.token_identifier != "" do
      :ok
    else
      {:error, "Identity token_identifier must be a non-empty string"}
    end
  end

  defp validate_serialized_claims(identity) do
    valid_claims =
      is_map(identity.custom_claims) and
        Enum.all?(identity.custom_claims, fn {key, _value} ->
          is_binary(key) and key != "" and key not in @reserved_claim_keys
        end)

    if valid_claims do
      :ok
    else
      {:error, "Identity custom claim keys must be non-empty and not reserved"}
    end
  end

  defp serialize_custom_claims(claims) do
    Enum.reduce_while(claims, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Jason.encode(value) do
        {:ok, _json} ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        {:error, %Jason.EncodeError{}} ->
          {:halt, {:error, "Identity custom claim #{key} must be JSON encodable"}}

        {:error, reason} ->
          {:halt, {:error, "Identity custom claim #{key} is invalid: #{inspect(reason)}"}}
      end
    end)
  end

  defp derive_token_identifier(attributes) do
    with {:ok, issuer} <- fetch_required_string(attributes, :issuer),
         {:ok, subject} <- fetch_required_string(attributes, :subject) do
      # Match UserIdentifier::construct in convex-rs; the separator is protocol identity syntax.
      issuer <> "|" <> subject
    else
      :error ->
        raise ArgumentError, "Identity requires token_identifier or both issuer and subject"
    end
  end

  defp fetch_required_string(attributes, field) do
    case Map.get(attributes, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :error
    end
  end

  defp validate_non_empty_string(_field, value) when is_binary(value) and value != "", do: value

  defp validate_non_empty_string(field, _value),
    do: raise(ArgumentError, "Identity field #{field} must be a non-empty string")
end
