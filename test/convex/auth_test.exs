defmodule Convex.AuthTest do
  use ExUnit.Case, async: true

  alias Convex.Auth.Identity
  alias Convex.Auth.Token

  test "identity derives a token identifier from issuer and subject" do
    identity =
      Identity.new(
        issuer: "https://auth.example.com",
        subject: "user-123",
        name: "Ethan",
        custom_claims: %{"isAdmin" => true}
      )

    assert identity.token_identifier == "https://auth.example.com|user-123"
    assert identity.issuer == "https://auth.example.com"
  end

  test "tokens expose typed identities without exposing credentials" do
    identity = Identity.new(token_identifier: "convex|user")
    admin = Token.admin("deploy-key", identity)

    assert admin.type == :admin
    assert admin.credential == "deploy-key"
    assert admin.acting_as == identity
    assert inspect(Token.user("jwt-secret")) =~ "<redacted>"
    refute inspect(admin) =~ "deploy-key"
  end

  test "identity rejects custom claims that collide with protocol fields" do
    assert_raise ArgumentError,
                 "Identity custom claim key emailVerified is reserved",
                 fn ->
                   Identity.new(
                     token_identifier: "convex|user",
                     custom_claims: %{"emailVerified" => true}
                   )
                 end
  end

  test "identity rejects values that cannot be encoded as JSON claims" do
    assert_raise ArgumentError,
                 "Identity custom claim roles must be JSON encodable",
                 fn ->
                   Identity.new(
                     token_identifier: "convex|user",
                     custom_claims: %{"roles" => {1, 2}}
                   )
                 end
  end

  test "identity requires a token identifier or both issuer and subject" do
    assert_raise ArgumentError,
                 "Identity requires token_identifier or both issuer and subject",
                 fn ->
                   Identity.new(issuer: "https://auth.example.com")
                 end
  end

  test "identity rejects duplicate keyword fields" do
    assert_raise ArgumentError,
                 "Identity duplicate fields: [:issuer]",
                 fn ->
                   Identity.new(
                     issuer: "https://auth.example.com",
                     issuer: "https://other.example.com",
                     subject: "user-123"
                   )
                 end
  end

  test "constructor errors do not echo credentials" do
    assert_raise ArgumentError, "User credential must be a non-empty string", fn ->
      Token.user("")
    end

    assert_raise ArgumentError,
                 "Admin credential must be a non-empty string and acting_as an Identity",
                 fn ->
                   Token.admin("", nil)
                 end
  end
end
