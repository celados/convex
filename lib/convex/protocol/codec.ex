defmodule Convex.Protocol.Codec do
  @moduledoc false

  alias Convex.Protocol.Messages.{
    Action,
    ActionResponse,
    Add,
    Authenticate,
    AuthError,
    Connect,
    FatalError,
    ModifyQuerySet,
    Mutation,
    MutationResponse,
    Ping,
    QueryFailed,
    QueryRemoved,
    QueryUpdated,
    Remove,
    StateVersion,
    Transition,
    TransitionChunk
  }

  alias Convex.Protocol.Optional
  alias Convex.Value

  @spec encode_client_message(struct()) :: {:ok, map()} | {:error, String.t()}
  def encode_client_message(%Connect{} = message) do
    base =
      %{
        "type" => "Connect",
        "sessionId" => message.session_id,
        "connectionCount" => message.connection_count
      }
      |> maybe_put("lastCloseReason", message.last_close_reason)
      |> maybe_put("maxObservedTimestamp", encode_optional_u64(message.max_observed_timestamp))
      |> maybe_put("clientTs", message.client_ts)

    {:ok, base}
  end

  def encode_client_message(%ModifyQuerySet{} = message) do
    with {:ok, modifications} <- encode_modifications(message.modifications) do
      {:ok,
       %{
         "type" => "ModifyQuerySet",
         "baseVersion" => message.base_version,
         "newVersion" => message.new_version,
         "modifications" => modifications
       }}
    end
  end

  def encode_client_message(%Mutation{} = message) do
    with {:ok, args} <- encode_args(message.args) do
      {:ok,
       %{
         "type" => "Mutation",
         "requestId" => message.request_id,
         "udfPath" => message.udf_path,
         "args" => args
       }
       |> optional_put("componentPath", message.component_path)}
    end
  end

  def encode_client_message(%Action{} = message) do
    with {:ok, args} <- encode_args(message.args) do
      {:ok,
       %{
         "type" => "Action",
         "requestId" => message.request_id,
         "udfPath" => message.udf_path,
         "args" => args
       }
       |> optional_put("componentPath", message.component_path)}
    end
  end

  def encode_client_message(%Authenticate{} = message) do
    base =
      %{
        "type" => "Authenticate",
        "baseVersion" => message.base_version,
        "tokenType" => message.token_type
      }
      |> maybe_put("value", message.value)
      |> optional_put("actingAs", message.acting_as)

    {:ok, base}
  end

  @spec encode_client_message_json(struct()) :: {:ok, binary()} | {:error, String.t()}
  def encode_client_message_json(message) do
    with {:ok, encoded} <- encode_client_message(message),
         {:ok, json} <- Jason.encode(encoded) do
      {:ok, json}
    else
      {:error, %Jason.EncodeError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec decode_server_message(binary() | map()) :: {:ok, struct()} | {:error, String.t()}
  def decode_server_message(message) when is_binary(message) do
    with {:ok, decoded} <- Jason.decode(message),
         {:ok, server_message} <- decode_server_message(decoded) do
      {:ok, server_message}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_server_message(%{"type" => "Transition"} = payload) do
    with {:ok, start_version} <- decode_state_version(payload["startVersion"]),
         {:ok, end_version} <- decode_state_version(payload["endVersion"]),
         {:ok, modifications} <- decode_transition_modifications(payload["modifications"]) do
      {:ok,
       %Transition{
         start_version: start_version,
         end_version: end_version,
         modifications: modifications,
         client_clock_skew: payload["clientClockSkew"],
         server_ts: payload["serverTs"]
       }}
    end
  end

  def decode_server_message(%{"type" => "MutationResponse"} = payload) do
    with {:ok, result} <- decode_response_result(payload["success"], payload["result"], payload),
         {:ok, ts} <- decode_optional_u64_field(payload, "ts") do
      {:ok,
       %MutationResponse{
         request_id: payload["requestId"],
         success: payload["success"],
         result: result,
         ts: ts,
         log_lines: payload["logLines"] || [],
         error_data: Optional.fetch(payload, "errorData")
       }}
    end
  end

  def decode_server_message(%{"type" => "ActionResponse"} = payload) do
    with {:ok, result} <- decode_response_result(payload["success"], payload["result"], payload) do
      {:ok,
       %ActionResponse{
         request_id: payload["requestId"],
         success: payload["success"],
         result: result,
         log_lines: payload["logLines"] || [],
         error_data: Optional.fetch(payload, "errorData")
       }}
    end
  end

  def decode_server_message(%{"type" => "TransitionChunk"} = payload) do
    {:ok,
     %TransitionChunk{
       chunk: payload["chunk"],
       part_number: payload["partNumber"],
       total_parts: payload["totalParts"],
       transition_id: payload["transitionId"]
     }}
  end

  def decode_server_message(%{"type" => "AuthError"} = payload) do
    {:ok,
     %AuthError{
       error: payload["error"],
       base_version: payload["baseVersion"],
       auth_update_attempted: payload["authUpdateAttempted"]
     }}
  end

  def decode_server_message(%{"type" => "FatalError", "error" => error}) do
    {:ok, %FatalError{error: error}}
  end

  def decode_server_message(%{"type" => "Ping"}) do
    {:ok, %Ping{}}
  end

  def decode_server_message(%{"type" => unknown}) do
    {:error, "Unsupported server message type #{inspect(unknown)}"}
  end

  def decode_server_message(_), do: {:error, "Unsupported server message payload"}

  defp encode_modifications(modifications) do
    Enum.reduce_while(modifications, {:ok, []}, fn modification, {:ok, acc} ->
      case encode_modification(modification) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      error -> error
    end
  end

  defp encode_modification(%Add{} = modification) do
    with {:ok, args} <- encode_args(modification.args) do
      {:ok,
       %{
         "type" => "Add",
         "queryId" => modification.query_id,
         "udfPath" => modification.udf_path,
         "args" => args
       }
       |> optional_put("journal", modification.journal)
       |> optional_put("componentPath", modification.component_path)}
    end
  end

  defp encode_modification(%Remove{} = modification) do
    {:ok, %{"type" => "Remove", "queryId" => modification.query_id}}
  end

  defp encode_args(args) when is_map(args) do
    with {:ok, encoded} <- Value.encode(args) do
      {:ok, [encoded]}
    end
  end

  defp decode_transition_modifications(modifications) when is_list(modifications) do
    Enum.reduce_while(modifications, {:ok, []}, fn modification, {:ok, acc} ->
      case decode_transition_modification(modification) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_transition_modifications(_), do: {:error, "Transition modifications must be a list"}

  defp decode_transition_modification(%{"type" => "QueryUpdated"} = payload) do
    with {:ok, value} <- Value.decode(payload["value"]) do
      {:ok,
       %QueryUpdated{
         query_id: payload["queryId"],
         value: value,
         log_lines: payload["logLines"] || [],
         journal: Optional.fetch(payload, "journal")
       }}
    end
  end

  defp decode_transition_modification(%{"type" => "QueryFailed"} = payload) do
    error_data =
      case Optional.fetch(payload, "errorData") do
        :absent -> {:ok, :absent}
        {:present, value} -> decode_present_value(value)
      end

    with {:ok, decoded_error_data} <- error_data do
      {:ok,
       %QueryFailed{
         query_id: payload["queryId"],
         error_message: payload["errorMessage"],
         log_lines: payload["logLines"] || [],
         journal: Optional.fetch(payload, "journal"),
         error_data: decoded_error_data
       }}
    end
  end

  defp decode_transition_modification(%{"type" => "QueryRemoved", "queryId" => query_id}) do
    {:ok, %QueryRemoved{query_id: query_id}}
  end

  defp decode_transition_modification(_), do: {:error, "Unsupported Transition modification"}

  defp decode_state_version(%{"querySet" => query_set, "identity" => identity, "ts" => ts}) do
    with {:ok, decoded_ts} <- Value.decode_u64(ts) do
      {:ok, %StateVersion{query_set: query_set, identity: identity, ts: decoded_ts}}
    end
  end

  defp decode_state_version(_), do: {:error, "Invalid state version"}

  defp decode_response_result(true, result, _payload), do: Value.decode(result)
  defp decode_response_result(false, result, _payload) when is_binary(result), do: {:ok, result}

  defp decode_response_result(false, _result, _payload),
    do: {:error, "Error response result must be a string"}

  defp decode_optional_u64_field(payload, key) do
    case Map.get(payload, key) do
      nil -> {:ok, nil}
      value -> Value.decode_u64(value)
    end
  end

  defp decode_present_value(value) do
    case Value.decode(value) do
      {:ok, decoded} -> {:ok, {:present, decoded}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_optional_u64(nil), do: nil
  defp encode_optional_u64(value), do: Value.encode_u64(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp optional_put(map, _key, :absent), do: map
  defp optional_put(map, key, {:present, value}), do: Map.put(map, key, value)
end
