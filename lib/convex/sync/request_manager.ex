defmodule Convex.Sync.RequestManager do
  @moduledoc false

  @type request_type :: :mutation | :action
  @type function_result :: {:ok, term()} | {:error, String.t() | Convex.ConvexError.t()}
  @type request_status ::
          :requested
          | {:completed_awaiting_transition, non_neg_integer() | nil, function_result()}
          | {:completed_immediate, function_result()}

  defmodule Request do
    @enforce_keys [:id, :type, :status, :message]
    defstruct [:id, :type, :status, :message]
  end

  defstruct ongoing_requests: %{}

  @type t :: %__MODULE__{ongoing_requests: %{non_neg_integer() => Request.t()}}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec track_request(t(), non_neg_integer(), request_type(), struct()) :: t()
  def track_request(%__MODULE__{} = manager, request_id, request_type, message) do
    request = %Request{id: request_id, type: request_type, status: :requested, message: message}
    put_in(manager.ongoing_requests[request_id], request)
  end

  @spec update_request(
          t(),
          non_neg_integer(),
          request_type(),
          function_result(),
          non_neg_integer() | nil
        ) ::
          {:ok, t(), %{non_neg_integer() => function_result()}} | {:reconnect, String.t()}
  def update_request(%__MODULE__{} = manager, request_id, request_type, value, ts) do
    with %Request{} = request <- Map.get(manager.ongoing_requests, request_id),
         true <- request.type == request_type do
      {status, completed_now} =
        case {request_type, value} do
          {:action, _} ->
            {{:completed_immediate, value}, %{request_id => value}}

          {:mutation, {:error, _}} ->
            {{:completed_immediate, value}, %{request_id => value}}

          {:mutation, {:ok, _}} ->
            {{:completed_awaiting_transition, ts, value}, %{}}
        end

      updated = %{request | status: status}
      manager = put_in(manager.ongoing_requests[request_id], updated)

      manager =
        if map_size(completed_now) > 0 do
          %{
            manager
            | ongoing_requests: Map.drop(manager.ongoing_requests, Map.keys(completed_now))
          }
        else
          manager
        end

      {:ok, manager, completed_now}
    else
      nil -> {:reconnect, "Invalid request id from server"}
      false -> {:reconnect, "Mismatched request type from server"}
    end
  end

  @spec finalize_completed_requests(t(), non_neg_integer()) ::
          {t(), %{non_neg_integer() => function_result()}}
  def finalize_completed_requests(%__MODULE__{} = manager, transition_ts) do
    {completed, ongoing} =
      Enum.reduce(manager.ongoing_requests, {%{}, %{}}, fn {request_id, request}, {done, keep} ->
        case request.status do
          {:completed_awaiting_transition, nil, value} ->
            {Map.put(done, request_id, value), keep}

          {:completed_awaiting_transition, request_ts, value} when request_ts <= transition_ts ->
            {Map.put(done, request_id, value), keep}

          {:completed_awaiting_transition, _request_ts, _value} ->
            {done, Map.put(keep, request_id, request)}

          :requested ->
            {done, Map.put(keep, request_id, request)}

          {:completed_immediate, value} ->
            {Map.put(done, request_id, value), keep}
        end
      end)

    {%{manager | ongoing_requests: ongoing}, completed}
  end

  @spec restart(t()) :: [struct()]
  def restart(%__MODULE__{} = manager) do
    manager.ongoing_requests
    |> Map.values()
    |> Enum.sort(&request_replay_order/2)
    |> Enum.map(& &1.message)
  end

  defp request_replay_order(left, right) do
    compare_timestamp(replay_ts(left), replay_ts(right))
  end

  defp replay_ts(%Request{status: {:completed_awaiting_transition, ts, _}}), do: ts
  defp replay_ts(_request), do: nil

  defp compare_timestamp(nil, nil), do: false
  defp compare_timestamp(_left, nil), do: true
  defp compare_timestamp(nil, _right), do: false
  defp compare_timestamp(left, right), do: left >= right
end
