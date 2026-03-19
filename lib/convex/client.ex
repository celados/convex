defmodule Convex.Client do
  @moduledoc false

  use GenServer
  require Logger

  alias Convex.Backoff
  alias Convex.Protocol.Codec
  alias Convex.Protocol.Messages.Connect
  alias Convex.Sync.Core
  alias Convex.Transport.WebSocket
  alias Convex.Value

  defmodule Subscription do
    @enforce_keys [:ref, :subscriber_id]
    defstruct [:ref, :subscriber_id]
  end

  defmodule Watch do
    @enforce_keys [:ref]
    defstruct [:ref]
  end

  defstruct [
    :deployment_url,
    :ws_url,
    :transport_module,
    :transport_pid,
    :transport_opts,
    :session_id,
    :connection_count,
    :last_close_reason,
    :last_server_response_ms,
    :inactivity_check_ms,
    :inactivity_timeout_ms,
    :pending_reconnect_timer,
    :inactivity_timer,
    :request_waiters,
    :pending_queries,
    :subscriptions,
    :watchers,
    :backoff,
    :auth_fetcher,
    :auth_token,
    :connection_state,
    :core
  ]

  @type function_result :: Core.function_result()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec query(pid(), String.t(), map(), keyword()) :: function_result() | {:error, String.t()}
  def query(client, udf_path, args, opts \\ []) do
    GenServer.call(client, {:query, udf_path, args}, Keyword.get(opts, :timeout, 30_000))
  end

  @spec mutation(pid(), String.t(), map(), keyword()) :: function_result() | {:error, String.t()}
  def mutation(client, udf_path, args, opts \\ []) do
    GenServer.call(client, {:mutation, udf_path, args}, Keyword.get(opts, :timeout, 30_000))
  end

  @spec action(pid(), String.t(), map(), keyword()) :: function_result() | {:error, String.t()}
  def action(client, udf_path, args, opts \\ []) do
    GenServer.call(client, {:action, udf_path, args}, Keyword.get(opts, :timeout, 30_000))
  end

  @spec subscribe(pid(), String.t(), map(), keyword()) ::
          {:ok, Subscription.t()} | {:error, String.t()}
  def subscribe(client, udf_path, args, opts \\ []) do
    GenServer.call(
      client,
      {:subscribe, self(), udf_path, args, opts},
      Keyword.get(opts, :timeout, 30_000)
    )
  end

  @spec unsubscribe(pid(), Subscription.t()) :: :ok | {:error, :unknown_subscriber}
  def unsubscribe(client, %Subscription{} = subscription) do
    GenServer.call(client, {:unsubscribe, subscription})
  end

  @spec watch_all(pid(), keyword()) :: {:ok, Watch.t()}
  def watch_all(client, opts \\ []) do
    GenServer.call(client, {:watch_all, self(), opts}, Keyword.get(opts, :timeout, 30_000))
  end

  @spec unwatch_all(pid(), Watch.t()) :: :ok
  def unwatch_all(client, %Watch{} = watch) do
    GenServer.call(client, {:unwatch_all, watch})
  end

  @spec set_auth(pid(), String.t() | nil) :: :ok | {:error, String.t()}
  def set_auth(client, token) do
    GenServer.call(client, {:set_auth, token})
  end

  @impl true
  def init(opts) do
    deployment_url = Keyword.fetch!(opts, :deployment_url)
    transport_module = Keyword.get(opts, :transport_module, WebSocket)
    transport_opts = Keyword.get(opts, :transport_opts, [])
    inactivity_check_ms = Keyword.get(opts, :inactivity_check_ms, 5_000)
    inactivity_timeout_ms = Keyword.get(opts, :inactivity_timeout_ms, 30_000)
    auth_fetcher = Keyword.get(opts, :auth_fetcher)

    state = %__MODULE__{
      deployment_url: deployment_url,
      ws_url: sync_url(deployment_url),
      transport_module: transport_module,
      transport_pid: nil,
      transport_opts: transport_opts,
      session_id: uuid4(),
      connection_count: 0,
      last_close_reason: "InitialConnect",
      last_server_response_ms: monotonic_ms(),
      inactivity_check_ms: inactivity_check_ms,
      inactivity_timeout_ms: inactivity_timeout_ms,
      pending_reconnect_timer: nil,
      inactivity_timer: nil,
      request_waiters: %{},
      pending_queries: %{},
      subscriptions: %{},
      watchers: %{},
      backoff: Backoff.new(Keyword.get(opts, :backoff, [])),
      auth_fetcher: auth_fetcher,
      auth_token: Keyword.get(opts, :auth_token),
      connection_state: :connecting,
      core: Core.new()
    }

    send(self(), :connect_transport)
    {:ok, schedule_inactivity_check(state)}
  end

  @impl true
  def handle_call({:subscribe, owner, udf_path, args, _opts}, _from, state) do
    with :ok <- validate_args(args) do
      {core, subscriber_id, initial} = Core.subscribe(state.core, udf_path, args)
      {core, messages} = Core.take_outbox(core)
      ref = make_ref()
      subscription = %Subscription{ref: ref, subscriber_id: subscriber_id}

      state =
        %{
          state
          | core: core,
            subscriptions: Map.put(state.subscriptions, subscriber_id, %{owner: owner, ref: ref})
        }

      case dispatch_messages(state, messages) do
        {:ok, state} ->
          if initial != nil do
            send(owner, {:convex, ref, initial})
          end

          {:reply, {:ok, subscription}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe, %Subscription{subscriber_id: subscriber_id}}, _from, state) do
    case Core.unsubscribe(state.core, subscriber_id) do
      {:ok, core} ->
        {core, messages} = Core.take_outbox(core)

        state = %{
          state
          | core: core,
            subscriptions: Map.delete(state.subscriptions, subscriber_id)
        }

        case dispatch_messages(state, messages) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, :unknown_subscriber} ->
        {:reply, {:error, :unknown_subscriber}, state}
    end
  end

  def handle_call({:watch_all, owner, _opts}, _from, state) do
    ref = make_ref()
    watch = %Watch{ref: ref}
    {:reply, {:ok, watch}, %{state | watchers: Map.put(state.watchers, ref, owner)}}
  end

  def handle_call({:unwatch_all, %Watch{ref: ref}}, _from, state) do
    {:reply, :ok, %{state | watchers: Map.delete(state.watchers, ref)}}
  end

  def handle_call({:set_auth, token}, _from, state) do
    with :ok <- validate_auth_token(token) do
      core = state.core |> Core.set_auth(token)
      {core, messages} = Core.take_outbox(core)
      state = %{state | core: core, auth_token: token}

      case dispatch_messages(state, messages) do
        {:ok, state} -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mutation, udf_path, args}, from, state) do
    with :ok <- validate_args(args) do
      {core, request_id} = Core.prepare_mutation(state.core, udf_path, args)
      {core, messages} = Core.take_outbox(core)

      state = %{
        state
        | core: core,
          request_waiters: Map.put(state.request_waiters, request_id, from)
      }

      case dispatch_messages(state, messages) do
        {:ok, state} ->
          {:noreply, state}

        {:error, reason} ->
          {:reply, {:error, reason},
           %{
             state
             | core: state.core,
               request_waiters: Map.delete(state.request_waiters, request_id)
           }}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:action, udf_path, args}, from, state) do
    with :ok <- validate_args(args) do
      {core, request_id} = Core.prepare_action(state.core, udf_path, args)
      {core, messages} = Core.take_outbox(core)

      state = %{
        state
        | core: core,
          request_waiters: Map.put(state.request_waiters, request_id, from)
      }

      case dispatch_messages(state, messages) do
        {:ok, state} ->
          {:noreply, state}

        {:error, reason} ->
          {:reply, {:error, reason},
           %{
             state
             | core: state.core,
               request_waiters: Map.delete(state.request_waiters, request_id)
           }}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:query, udf_path, args}, from, state) do
    with :ok <- validate_args(args) do
      {core, subscriber_id, initial} = Core.subscribe(state.core, udf_path, args)
      {core, messages} = Core.take_outbox(core)
      state = %{state | core: core}

      case dispatch_messages(state, messages) do
        {:ok, state} ->
          case initial do
            nil ->
              {:noreply,
               %{state | pending_queries: Map.put(state.pending_queries, subscriber_id, from)}}

            result ->
              {:ok, core} = Core.unsubscribe(core, subscriber_id)
              {core, unsubscribe_messages} = Core.take_outbox(core)
              GenServer.reply(from, result)

              case dispatch_messages(%{state | core: core}, unsubscribe_messages) do
                {:ok, state} -> {:noreply, state}
                {:error, _reason} -> {:noreply, %{state | core: core}}
              end
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:connect_transport, state) do
    case state.transport_pid do
      nil ->
        headers = [{"Convex-Client", "elixir-#{Application.spec(:convex, :vsn) || "0.1.0"}"}]

        case state.transport_module.start_link(
               Keyword.merge(state.transport_opts,
                 owner: self(),
                 url: state.ws_url,
                 headers: headers
               )
             ) do
          {:ok, transport_pid} ->
            {:noreply, %{state | transport_pid: transport_pid}}

          {:error, reason} ->
            Logger.debug("Convex transport connect failed: #{inspect(reason)}")
            {:noreply, schedule_reconnect(%{state | transport_pid: nil}, inspect(reason))}
        end

      _transport_pid ->
        {:noreply, state}
    end
  end

  def handle_info(:check_inactivity, state) do
    state =
      if state.connection_state == :connected and
           monotonic_ms() - state.last_server_response_ms >= state.inactivity_timeout_ms do
        reconnect(state, "InactiveServer")
      else
        state
      end

    {:noreply, schedule_inactivity_check(state)}
  end

  def handle_info(:reconnect_now, state) do
    send(self(), :connect_transport)
    {:noreply, %{state | pending_reconnect_timer: nil}}
  end

  def handle_info(
        {:convex_transport, transport_pid, :connected},
        %{transport_pid: transport_pid} = state
      ) do
    connect_message = %Connect{
      session_id: state.session_id,
      connection_count: state.connection_count,
      last_close_reason: state.last_close_reason,
      max_observed_timestamp: state.core.max_observed_timestamp,
      # `clientTs` is sent to the server for clock skew estimation and must be wall clock;
      # monotonic clocks are only suitable for local timeout/interval checks.
      client_ts: system_ms()
    }

    state = %{state | connection_state: :connected, last_server_response_ms: monotonic_ms()}

    case dispatch_messages(state, [connect_message]) do
      {:ok, state} ->
        {state, auth_input} = resolve_auth_input(state)

        {core, messages} =
          if state.connection_count == 0 do
            state.core
            |> apply_initial_auth(auth_input)
            |> Core.take_outbox()
          else
            Core.rebuild_for_reconnect(state.core, auth_input)
          end

        state = %{
          state
          | core: core,
            backoff: Backoff.reset(state.backoff),
            connection_count: state.connection_count + 1
        }

        case dispatch_messages(state, messages) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:noreply, reconnect(state, "EncodeError: #{reason}")}
        end

      {:error, reason} ->
        {:noreply, reconnect(state, "EncodeError: #{reason}")}
    end
  end

  def handle_info(
        {:convex_transport, transport_pid, {:text, payload}},
        %{transport_pid: transport_pid} = state
      ) do
    previous_snapshot = Core.snapshot_for_subscribers(state.core)

    state = %{
      state
      | last_server_response_ms: monotonic_ms(),
        backoff: Backoff.reset(state.backoff)
    }

    case Codec.decode_server_message(payload) do
      {:ok, message} ->
        case Core.receive_message(state.core, message) do
          {:ok, core, changed_queries, completed_requests} ->
            state = %{state | core: core}
            state = notify_changed_queries(state, changed_queries)
            state = notify_request_waiters(state, completed_requests)
            state = maybe_notify_watchers(state, previous_snapshot)
            {:noreply, state}

          {:reconnect, reason} ->
            {:noreply, reconnect(state, reason)}
        end

      {:error, reason} ->
        {:noreply, reconnect(state, "ProtocolDecodeError: #{reason}")}
    end
  end

  def handle_info(
        {:convex_transport, transport_pid, {:closed, reason}},
        %{transport_pid: transport_pid} = state
      ) do
    {:noreply,
     schedule_reconnect(
       %{state | transport_pid: nil, connection_state: :connecting},
       inspect(reason)
     )}
  end

  def handle_info(message, state) do
    Logger.debug("Ignoring unexpected Convex.Client message: #{inspect(message)}")
    {:noreply, state}
  end

  defp dispatch_messages(state, messages) do
    with {:ok, payloads} <- encode_messages(messages) do
      Enum.each(payloads, fn payload ->
        if state.transport_pid do
          _ = state.transport_module.send_text(state.transport_pid, payload)
        end
      end)

      {:ok, state}
    end
  end

  defp encode_messages(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      case Codec.encode_client_message_json(message) do
        {:ok, payload} -> {:cont, {:ok, [payload | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      error -> error
    end
  end

  defp notify_changed_queries(state, changed_queries) do
    Enum.reduce(changed_queries, state, fn {query_id, result}, acc ->
      pending_subscribers =
        acc.pending_queries
        |> Enum.filter(fn {{pending_query_id, _index}, _from} -> pending_query_id == query_id end)
        |> Enum.map(fn {subscriber_id, from} -> {subscriber_id, from} end)

      acc =
        Enum.reduce(pending_subscribers, acc, fn {subscriber_id, from}, nested ->
          GenServer.reply(from, result)

          core =
            case Core.unsubscribe(nested.core, subscriber_id) do
              {:ok, updated_core} -> updated_core
              {:error, :unknown_subscriber} -> nested.core
            end

          {core, messages} = Core.take_outbox(core)

          nested
          |> Map.put(:core, core)
          |> Map.put(:pending_queries, Map.delete(nested.pending_queries, subscriber_id))
          |> dispatch_messages!(messages)
        end)

      Enum.reduce(acc.subscriptions, acc, fn
        {{^query_id, _index}, %{owner: owner, ref: ref}}, nested ->
          send(owner, {:convex, ref, result})
          nested

        _, nested ->
          nested
      end)
    end)
  end

  defp notify_request_waiters(state, completed_requests) do
    Enum.reduce(completed_requests, state, fn {request_id, result}, acc ->
      case Map.pop(acc.request_waiters, request_id) do
        {nil, _waiters} ->
          acc

        {from, waiters} ->
          GenServer.reply(from, result)
          %{acc | request_waiters: waiters}
      end
    end)
  end

  defp maybe_notify_watchers(state, previous_snapshot) do
    snapshot = Core.snapshot_for_subscribers(state.core)

    # `watch_all/1` semantically means "snapshot changed", not "received any server message".
    if snapshot != previous_snapshot do
      Enum.each(state.watchers, fn {ref, owner} ->
        send(owner, {:convex_watch, ref, snapshot})
      end)
    end

    state
  end

  defp reconnect(state, reason) do
    if state.transport_pid do
      _ = state.transport_module.close(state.transport_pid)
    end

    schedule_reconnect(%{state | transport_pid: nil, connection_state: :connecting}, reason)
  end

  defp schedule_reconnect(state, reason) do
    if state.pending_reconnect_timer do
      Process.cancel_timer(state.pending_reconnect_timer)
    end

    {delay, backoff} = Backoff.next_delay(state.backoff)
    timer = Process.send_after(self(), :reconnect_now, delay)
    %{state | backoff: backoff, last_close_reason: reason, pending_reconnect_timer: timer}
  end

  defp schedule_inactivity_check(state) do
    if state.inactivity_timer do
      Process.cancel_timer(state.inactivity_timer)
    end

    timer = Process.send_after(self(), :check_inactivity, state.inactivity_check_ms)
    %{state | inactivity_timer: timer}
  end

  defp sync_url("https://" <> rest), do: "wss://" <> rest <> "/api/sync"
  defp sync_url("http://" <> rest), do: "ws://" <> rest <> "/api/sync"
  defp sync_url(url), do: url <> "/api/sync"

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  defp system_ms do
    System.system_time(:millisecond)
  end

  defp validate_args(args) when is_map(args) do
    case Value.encode(args) do
      {:ok, _encoded} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_args(_args), do: {:error, "Arguments must be a map"}

  defp validate_auth_token(token) when is_binary(token) or is_nil(token), do: :ok
  defp validate_auth_token(_token), do: {:error, "Auth token must be a string or nil"}

  defp resolve_auth_input(state) do
    force_refresh = state.connection_count > 0

    case state.auth_fetcher do
      nil ->
        {state, auth_input_from_token(state.auth_token)}

      fetcher ->
        case normalize_fetched_token(fetcher.(force_refresh: force_refresh)) do
          {:ok, token} ->
            {%{state | auth_token: token}, auth_input_from_token(token)}

          :no_auth ->
            # fetcher returning nil semantically means "this connection should be anonymous"; we must not reuse the old token，
            # otherwise logout/refresh failure will cause us to silently reconnect with expired credentials.
            {%{state | auth_token: nil}, :no_auth}
        end
    end
  end

  defp normalize_fetched_token({:ok, token}) when is_binary(token) or is_nil(token),
    do: {:ok, token}

  defp normalize_fetched_token(token) when is_binary(token) or is_nil(token), do: {:ok, token}
  defp normalize_fetched_token(_token), do: :no_auth

  defp auth_input_from_token(nil), do: :no_auth
  defp auth_input_from_token(token), do: {:token, token}

  defp apply_initial_auth(core, :no_auth), do: core
  defp apply_initial_auth(core, {:token, token}), do: Core.set_auth(core, token)

  defp dispatch_messages!(state, messages) do
    case dispatch_messages(state, messages) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  defp uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    Enum.join(
      [
        hex(a, 8),
        hex(b, 4),
        hex(c, 4),
        hex(d, 4),
        hex(e, 12)
      ],
      "-"
    )
  end

  defp hex(value, width) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
