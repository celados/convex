defmodule Convex.Sync.Core do
  @moduledoc false

  alias Convex.ConvexError

  alias Convex.Protocol.Messages.{
    Action,
    ActionResponse,
    Add,
    Authenticate,
    AuthError,
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

  alias Convex.Sync.{QueryToken, RequestManager}

  @type query_id :: non_neg_integer()
  @type subscriber_id :: {query_id(), non_neg_integer()}
  @type function_result :: RequestManager.function_result()
  @type request_completion :: %{non_neg_integer() => function_result()}
  @type changed_queries :: %{query_id() => function_result()}

  defmodule LocalQuery do
    @enforce_keys [:id, :udf_path, :args]
    defstruct [
      :id,
      :udf_path,
      :args,
      :journal,
      :component_path,
      subscriber_count: 1,
      next_subscription_index: 0
    ]
  end

  @enforce_keys [:remote_version, :request_manager]
  defstruct next_query_id: 0,
            query_set_version: 0,
            query_set: %{},
            query_id_to_token: %{},
            identity_version: 0,
            remote_version: %StateVersion{query_set: 0, identity: 0, ts: 0},
            remote_query_set: %{},
            optimistic_results: %{},
            subscribers: MapSet.new(),
            latest_results: %{},
            request_manager: RequestManager.new(),
            next_request_id: 0,
            outbox: :queue.new(),
            max_observed_timestamp: nil

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new,
    do: %__MODULE__{
      remote_version: %StateVersion{query_set: 0, identity: 0, ts: 0},
      request_manager: RequestManager.new()
    }

  @spec subscribe(t(), String.t(), map()) :: {t(), subscriber_id(), function_result() | nil}
  def subscribe(%__MODULE__{} = state, udf_path, args)
      when is_binary(udf_path) and is_map(args) do
    token = QueryToken.build(udf_path, args)

    case Map.get(state.query_set, token) do
      %LocalQuery{} = query ->
        updated_query = %{
          query
          | subscriber_count: query.subscriber_count + 1,
            next_subscription_index: query.next_subscription_index + 1
        }

        subscriber_id = {query.id, updated_query.next_subscription_index}

        state =
          state
          |> put_in([Access.key!(:query_set), token], updated_query)
          |> update_in([Access.key!(:subscribers)], &MapSet.put(&1, subscriber_id))

        {state, subscriber_id, Map.get(state.latest_results, query.id)}

      nil ->
        query_id = state.next_query_id
        base_version = state.query_set_version
        new_version = base_version + 1

        query = %LocalQuery{
          id: query_id,
          udf_path: QueryToken.canonicalize_udf_path(udf_path),
          args: args,
          journal: nil,
          component_path: nil
        }

        subscriber_id = {query_id, 0}

        message = %ModifyQuerySet{
          base_version: base_version,
          new_version: new_version,
          modifications: [%Add{query_id: query_id, udf_path: query.udf_path, args: args}]
        }

        state =
          state
          |> Map.put(:next_query_id, query_id + 1)
          |> Map.put(:query_set_version, new_version)
          |> put_in([Access.key!(:query_set), token], query)
          |> put_in([Access.key!(:query_id_to_token), query_id], token)
          |> update_in([Access.key!(:subscribers)], &MapSet.put(&1, subscriber_id))
          |> enqueue([message])

        {state, subscriber_id, nil}
    end
  end

  @spec unsubscribe(t(), subscriber_id()) :: {:ok, t()} | {:error, :unknown_subscriber}
  def unsubscribe(%__MODULE__{} = state, subscriber_id = {query_id, _index}) do
    if MapSet.member?(state.subscribers, subscriber_id) do
      token = state.query_id_to_token[query_id]
      query = state.query_set[token]
      subscribers = MapSet.delete(state.subscribers, subscriber_id)

      cond do
        query == nil ->
          {:ok, %{state | subscribers: subscribers}}

        query.subscriber_count > 1 ->
          updated_query = %{query | subscriber_count: query.subscriber_count - 1}
          updated_state = put_in(state.query_set[token], updated_query)
          {:ok, %{updated_state | subscribers: subscribers}}

        true ->
          base_version = state.query_set_version
          new_version = base_version + 1

          updated_state =
            state
            |> Map.put(:subscribers, subscribers)
            |> Map.put(:query_set_version, new_version)
            |> update_in([Access.key!(:query_set)], &Map.delete(&1, token))
            |> update_in([Access.key!(:query_id_to_token)], &Map.delete(&1, query_id))
            |> update_in([Access.key!(:latest_results)], &Map.delete(&1, query_id))
            |> update_in([Access.key!(:remote_query_set)], &Map.delete(&1, query_id))
            |> enqueue([
              %ModifyQuerySet{
                base_version: base_version,
                new_version: new_version,
                modifications: [%Remove{query_id: query_id}]
              }
            ])

          {:ok, updated_state}
      end
    else
      {:error, :unknown_subscriber}
    end
  end

  @spec set_auth(t(), String.t() | nil) :: t()
  def set_auth(%__MODULE__{} = state, token) when is_binary(token) or is_nil(token) do
    base_version = state.identity_version

    message =
      case token do
        nil -> %Authenticate{base_version: base_version, token_type: "None"}
        value -> %Authenticate{base_version: base_version, token_type: "User", value: value}
      end

    state
    |> Map.put(:identity_version, base_version + 1)
    |> enqueue([message])
  end

  @spec prepare_mutation(t(), String.t(), map()) :: {t(), non_neg_integer()}
  def prepare_mutation(%__MODULE__{} = state, udf_path, args)
      when is_binary(udf_path) and is_map(args) do
    request_id = state.next_request_id

    message = %Mutation{
      request_id: request_id,
      udf_path: QueryToken.canonicalize_udf_path(udf_path),
      args: args
    }

    state =
      state
      |> Map.put(:next_request_id, request_id + 1)
      |> Map.update!(
        :request_manager,
        &RequestManager.track_request(&1, request_id, :mutation, message)
      )
      |> enqueue([message])

    {state, request_id}
  end

  @spec prepare_action(t(), String.t(), map()) :: {t(), non_neg_integer()}
  def prepare_action(%__MODULE__{} = state, udf_path, args)
      when is_binary(udf_path) and is_map(args) do
    request_id = state.next_request_id

    message = %Action{
      request_id: request_id,
      udf_path: QueryToken.canonicalize_udf_path(udf_path),
      args: args
    }

    state =
      state
      |> Map.put(:next_request_id, request_id + 1)
      |> Map.update!(
        :request_manager,
        &RequestManager.track_request(&1, request_id, :action, message)
      )
      |> enqueue([message])

    {state, request_id}
  end

  @spec take_outbox(t()) :: {t(), [struct()]}
  def take_outbox(%__MODULE__{} = state) do
    {messages, queue} = drain_queue(state.outbox, [])
    {%{state | outbox: queue}, messages}
  end

  @spec rebuild_for_reconnect(t(), :no_auth | {:token, String.t()}) :: {t(), [struct()]}
  def rebuild_for_reconnect(%__MODULE__{} = state, auth_input) do
    auth_messages =
      case auth_input do
        {:token, token} -> [%Authenticate{base_version: 0, token_type: "User", value: token}]
        :no_auth -> []
      end

    modifications =
      state.query_set
      |> Map.values()
      |> Enum.map(fn query ->
        %Add{query_id: query.id, udf_path: query.udf_path, args: query.args}
      end)

    query_messages =
      if modifications == [] do
        []
      else
        [%ModifyQuerySet{base_version: 0, new_version: 1, modifications: modifications}]
      end

    replay_messages = RequestManager.restart(state.request_manager)
    messages = auth_messages ++ query_messages ++ replay_messages

    reset_state =
      %{
        state
        | identity_version: if(auth_input == :no_auth, do: 0, else: 1),
          query_set_version: if(modifications == [], do: 0, else: 1),
          remote_version: %StateVersion{query_set: 0, identity: 0, ts: 0},
          remote_query_set: %{},
          optimistic_results: %{},
          latest_results: %{},
          outbox: :queue.new()
      }
      |> enqueue(messages)

    take_outbox(reset_state)
  end

  @spec receive_message(t(), struct()) ::
          {:ok, t(), changed_queries(), request_completion()} | {:reconnect, String.t()}
  def receive_message(%__MODULE__{} = state, %Transition{} = message) do
    if message.start_version != state.remote_version do
      {:reconnect, "StartVersionMismatch"}
    else
      with {:ok, remote_query_set} <-
             apply_transition_modifications(state.remote_query_set, message.modifications),
           {request_manager, completed_requests} <-
             RequestManager.finalize_completed_requests(
               state.request_manager,
               message.end_version.ts
             ) do
        active_query_ids = Map.keys(state.query_id_to_token) |> MapSet.new()

        latest_results =
          remote_query_set
          |> Enum.filter(fn {query_id, _result} -> MapSet.member?(active_query_ids, query_id) end)
          |> Map.new()

        changed_queries = diff_results(state.latest_results, latest_results)

        {:ok,
         %{
           state
           | remote_version: message.end_version,
             remote_query_set: remote_query_set,
             latest_results: latest_results,
             request_manager: request_manager,
             max_observed_timestamp:
               observe_timestamp(state.max_observed_timestamp, message.end_version.ts)
         }, changed_queries, completed_requests}
      end
    end
  end

  def receive_message(%__MODULE__{} = state, %MutationResponse{} = message) do
    state = maybe_observe_response_timestamp(state, message.ts)
    result = response_result(message.success, message.result, message.error_data)

    case RequestManager.update_request(
           state.request_manager,
           message.request_id,
           :mutation,
           result,
           message.ts
         ) do
      {:ok, manager, completed_requests} ->
        {:ok, %{state | request_manager: manager}, %{}, completed_requests}

      {:reconnect, reason} ->
        {:reconnect, reason}
    end
  end

  def receive_message(%__MODULE__{} = state, %ActionResponse{} = message) do
    result = response_result(message.success, message.result, message.error_data)

    case RequestManager.update_request(
           state.request_manager,
           message.request_id,
           :action,
           result,
           nil
         ) do
      {:ok, manager, completed_requests} ->
        {:ok, %{state | request_manager: manager}, %{}, completed_requests}

      {:reconnect, reason} ->
        {:reconnect, reason}
    end
  end

  def receive_message(_state, %TransitionChunk{}),
    do: {:reconnect, "Unexpected TransitionChunk message received"}

  def receive_message(_state, %AuthError{error: error}), do: {:reconnect, "AuthError: #{error}"}
  def receive_message(_state, %FatalError{error: error}), do: {:reconnect, "FatalError: #{error}"}
  def receive_message(%__MODULE__{} = state, %Ping{}), do: {:ok, state, %{}, %{}}

  @spec snapshot_for_subscribers(t()) :: %{subscriber_id() => function_result()}
  def snapshot_for_subscribers(%__MODULE__{} = state) do
    Enum.reduce(state.subscribers, %{}, fn {query_id, _index} = subscriber_id, acc ->
      case Map.get(state.latest_results, query_id) do
        nil -> acc
        result -> Map.put(acc, subscriber_id, result)
      end
    end)
  end

  defp apply_transition_modifications(remote_query_set, modifications) do
    Enum.reduce_while(modifications, {:ok, remote_query_set}, fn modification, {:ok, acc} ->
      case modification do
        %QueryUpdated{query_id: query_id, value: value} ->
          {:cont, {:ok, Map.put(acc, query_id, {:ok, value})}}

        %QueryFailed{query_id: query_id, error_message: message, error_data: error_data} ->
          {:cont, {:ok, Map.put(acc, query_id, query_failure(message, error_data))}}

        %QueryRemoved{query_id: query_id} ->
          {:cont, {:ok, Map.delete(acc, query_id)}}
      end
    end)
  end

  defp response_result(true, value, _error_data), do: {:ok, value}
  defp response_result(false, message, :absent), do: {:error, message}

  defp response_result(false, message, {:present, data}),
    do: {:error, %ConvexError{message: message, data: data}}

  defp query_failure(message, :absent), do: {:error, message}

  defp query_failure(message, {:present, data}),
    do: {:error, %ConvexError{message: message, data: data}}

  defp enqueue(state, messages) do
    queue = Enum.reduce(messages, state.outbox, &:queue.in/2)
    %{state | outbox: queue}
  end

  defp drain_queue(queue, acc) do
    case :queue.out(queue) do
      {{:value, message}, rest} -> drain_queue(rest, [message | acc])
      {:empty, rest} -> {Enum.reverse(acc), rest}
    end
  end

  defp diff_results(old_results, new_results) do
    Enum.reduce(new_results, %{}, fn {query_id, result}, acc ->
      if Map.get(old_results, query_id) == result do
        acc
      else
        Map.put(acc, query_id, result)
      end
    end)
  end

  defp maybe_observe_response_timestamp(state, nil), do: state

  defp maybe_observe_response_timestamp(state, ts),
    do: %{state | max_observed_timestamp: observe_timestamp(state.max_observed_timestamp, ts)}

  defp observe_timestamp(nil, ts), do: ts
  defp observe_timestamp(current, ts), do: max(current, ts)
end
