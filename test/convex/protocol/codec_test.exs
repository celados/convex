defmodule Convex.Protocol.CodecTest do
  use ExUnit.Case, async: true

  alias Convex.Auth
  alias Convex.Protocol.Codec
  alias Convex.Protocol.Messages.{Add, Authenticate, ModifyQuerySet, Mutation, MutationResponse}

  test "encodes client args as a one-element array" do
    message = %Mutation{request_id: 1, udf_path: "messages:send", args: %{"channel" => "general"}}

    assert {:ok,
            %{
              "type" => "Mutation",
              "requestId" => 1,
              "udfPath" => "messages:send",
              "args" => [%{"channel" => "general"}]
            }} = Codec.encode_client_message(message)
  end

  test "encodes modify query set additions" do
    message = %ModifyQuerySet{
      base_version: 0,
      new_version: 1,
      modifications: [%Add{query_id: 3, udf_path: "messages:list", args: %{"a" => 1}}]
    }

    assert {:ok,
            %{"modifications" => [%{"type" => "Add", "queryId" => 3, "args" => [%{"a" => 1.0}]}]}} =
             Codec.encode_client_message(message)
  end

  test "encodes admin impersonation with flattened custom claims" do
    identity =
      Auth.Identity.new(
        issuer: "https://auth.example.com",
        subject: "user-123",
        given_name: "Ethan",
        nickname: "",
        email_verified: true,
        custom_claims: %{"isAdmin" => true, "roles" => ["admin"]}
      )

    message = %Authenticate{base_version: 3, token: Auth.Token.admin("deploy-key", identity)}

    assert {:ok,
            %{
              "type" => "Authenticate",
              "baseVersion" => 3,
              "tokenType" => "Admin",
              "value" => "deploy-key",
              "actingAs" => %{
                "tokenIdentifier" => "https://auth.example.com|user-123",
                "issuer" => "https://auth.example.com",
                "subject" => "user-123",
                "givenName" => "Ethan",
                "nickname" => "",
                "emailVerified" => true,
                "isAdmin" => true,
                "roles" => ["admin"]
              }
            }} = Codec.encode_client_message(message)
  end

  test "encodes user and anonymous authentication tokens" do
    user = %Authenticate{base_version: 0, token: Auth.Token.user("jwt-secret")}
    anonymous = %Authenticate{base_version: 1, token: Auth.Token.none()}

    assert {:ok,
            %{
              "type" => "Authenticate",
              "baseVersion" => 0,
              "tokenType" => "User",
              "value" => "jwt-secret"
            }} = Codec.encode_client_message(user)

    assert {:ok,
            %{
              "type" => "Authenticate",
              "baseVersion" => 1,
              "tokenType" => "None"
            }} = Codec.encode_client_message(anonymous)

    refute inspect(user) =~ "jwt-secret"
    refute inspect(anonymous) =~ "jwt-secret"
  end

  test "rejects malformed directly constructed authentication tokens" do
    malformed =
      struct!(Auth.Token, type: :user, credential: nil, acting_as: nil)

    assert {:error, "Invalid authentication token"} =
             Codec.encode_client_message(%Authenticate{base_version: 0, token: malformed})
  end

  test "rejects malformed directly constructed acting-as identities" do
    malformed_identity = struct!(Auth.Identity, token_identifier: nil)

    malformed =
      struct!(Auth.Token,
        type: :admin,
        credential: "deploy-key",
        acting_as: malformed_identity
      )

    assert {:error, "Identity token_identifier must be a non-empty string"} =
             Codec.encode_client_message(%Authenticate{base_version: 0, token: malformed})
  end

  test "admin impersonation always emits a normalized token identifier" do
    identity =
      Auth.Identity.new(issuer: "https://auth.example.com", subject: "user-123")

    assert {:ok,
            %{
              "actingAs" => %{
                "tokenIdentifier" => "https://auth.example.com|user-123",
                "issuer" => "https://auth.example.com",
                "subject" => "user-123"
              }
            }} =
             Codec.encode_client_message(%Authenticate{
               base_version: 0,
               token: Auth.Token.admin("deploy-key", identity)
             })
  end

  test "encodes native integer args as float64 JSON numbers" do
    message = %Mutation{request_id: 1, udf_path: "messages:send", args: %{"count" => 42}}

    assert {:ok, %{"args" => [%{"count" => 42.0}]}} = Codec.encode_client_message(message)
  end

  test "decodes mutation response and preserves absent vs null error_data" do
    payload = %{
      "type" => "MutationResponse",
      "requestId" => 7,
      "success" => false,
      "result" => "boom",
      "logLines" => [],
      "errorData" => nil
    }

    assert {:ok, %MutationResponse{error_data: {:present, nil}, result: "boom"}} =
             Codec.decode_server_message(payload)
  end

  test "decodes timestamp from base64 u64" do
    payload = %{
      "type" => "MutationResponse",
      "requestId" => 1,
      "success" => true,
      "result" => %{"ok" => true},
      "ts" => "AQAAAAAAAAA=",
      "logLines" => []
    }

    assert {:ok, %MutationResponse{ts: 1, result: %{"ok" => true}}} =
             Codec.decode_server_message(payload)
  end
end
