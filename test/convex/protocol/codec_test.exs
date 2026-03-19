defmodule Convex.Protocol.CodecTest do
  use ExUnit.Case, async: true

  alias Convex.Protocol.Codec
  alias Convex.Protocol.Messages.{Add, ModifyQuerySet, Mutation, MutationResponse}

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
