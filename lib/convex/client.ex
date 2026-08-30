defmodule Convex.Client do
  @moduledoc false

  use GenServer
  require Logger

  alias Convex.Auth
  alias Convex.Backoff
  alias Convex.Protocol.Codec
  alias Convex.Protocol.Messages.Connect
  alias Convex.Sync.Core
  alias Convex.Transport.WebSocket
  alias Convex.Value

  defmodule Subscription do
    @moduledoc false
    @enforce_keys [:ref, :subscriber_id]
    defstruct [:ref, :subscriber_id]

    @type t :: %__MODULE__{
            ref: reference(),
            subscriber_id: {non_neg_integer(), non_neg_integer()}
          }
  end

  defmodule Watch do
    @moduledoc false
    @enforce_keys [:ref]
    defstruct [:ref]
    @type t :: %__MODULE__{ref: reference()}
  end

  defmodule ConnectionWatch do
    @moduledoc false
    @enforce_keys [:ref]
    defstruct [:ref]
    @type t :: %__MODULE__{ref: reference()}
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
    :connection_watchers,
    :backoff,
    :auth_source,
    :active_token,
    :auth_generation,
    :connection_generation,
    :pending_auth,
    :auth_ready,
    :pending_messages,
    :connection_state,
    :monotonic_clock,
    :system_clock,
    :core
  ]

  @type connection_state :: :connecting | :connected
  @type function_result :: Core.function_result()
  @type auth_fetcher :: (keyword() -> {:ok, Auth.Token.t()} | {:error, term()})

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    auth_source = start_auth_source(opts)
    opts = Keyword.put(opts, :auth_source, auth_source)
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

  @spec connection_state(pid()) :: connection_state()
  def connection_state(client) do
    GenServer.call(client, :connection_state)
  end

  @spec watch_connection_state(pid(), keyword()) :: {:ok, ConnectionWatch.t()}
  def watch_connection_state(client, opts \\ []) do
    GenServer.call(
      client,
      {:watch_connection_state, self(), opts},
      Keyword.get(opts, :timeout, 30_000)
    )
  end

  @spec unwatch_connection_state(pid(), ConnectionWatch.t()) :: :ok
  def unwatch_connection_state(client, %ConnectionWatch{} = watch) do
    GenServer.call(client, {:unwatch_connection_state, watch})
  end

  @spec set_auth(pid(), String.t() | nil) :: :ok
  def set_auth(client, token) do
    token =
      case token do
        nil -> Auth.Token.none()
        credential -> Auth.Token.user(credential)
      end

    GenServer.call(client, {:set_auth, token})
  end

  @spec set_admin_auth(pid(), String.t(), Auth.Identity.t() | nil) :: :ok
  def set_admin_auth(client, deploy_key, identity \\ nil) do
    GenServer.call(client, {:set_auth, Auth.Token.admin(deploy_key, identity)})
  end

  @spec set_auth_fetcher(pid(), nil) :: :ok
  @spec set_auth_fetcher(pid(), auth_fetcher()) :: :ok
  def set_auth_fetcher(client, nil) do
    GenServer.call(client, {:set_auth_fetcher, nil})
  end

  def set_auth_fetcher(client, fetcher) when is_function(fetcher, 1) do
    GenServer.call(client, {:set_auth_fetcher, fetcher})
  end

  def set_auth_fetcher(_client, _fetcher),
    do: raise(ArgumentError, "auth_fetcher must be nil or a one-argument function")

  def default_monotonic_clock, do: System.monotonic_time(:millisecond)
  def default_system_clock, do: System.system_time(:millisecond)

  defp start_auth_source(opts) do
    has_auth? = Keyword.has_key?(opts, :auth)
    has_fetcher? = Keyword.has_key?(opts, :auth_fetcher)

    cond do
      Keyword.has_key?(opts, :auth_token) ->
        raise ArgumentError, "auth_token was removed; use auth: Auth.Token.t()"

      has_auth? and has_fetcher? ->
        raise ArgumentError, "auth and auth_fetcher are mutually exclusive"

      has_auth? ->
        token = Keyword.fetch!(opts, :auth)
        unless Auth.Token.valid?(token), do: raise(ArgumentError, "Invalid auth token")
        {:static, token}

      has_fetcher? ->
        fetcher = Keyword.fetch!(opts, :auth_fetcher)

        unless is_function(fetcher, 1),
          do: raise(ArgumentError, "auth_fetcher must be a one-argument function")

        {:fetcher, fetcher}

      true ->
        {:static, Auth.Token.none()}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    deployment_url = Keyword.fetch!(opts, :deployment_url)
    transport_module = Keyword.get(opts, :transport_module, WebSocket)
    transport_opts = Keyword.get(opts, :transport_opts, [])
    inactivity_check_ms = Keyword.get(opts, :inactivity_check_ms, 5_000)
    inactivity_timeout_ms = Keyword.get(opts, :inactivity_timeout_ms, 30_000)
    auth_source = Keyword.fetch!(opts, :auth_source)
    monotonic_clock = Keyword.get(opts, :monotonic_clock, &__MODULE__.default_monotonic_clock/0)
    system_clock = Keyword.get(opts, :system_clock, &__MODULE__.default_system_clock/0)

    state = %__MODULE__{
      deployment_url: deployment_url,
      ws_url: sync_url(deployment_url),
      transport_module: transport_module,
      transport_pid: nil,
      transport_opts: transport_opts,
      session_id: uuid4(),
      connection_count: 0,
      last_close_reason: "InitialConnect",
      last_server_response_ms: monotonic_clock.(),
      inactivity_check_ms: inactivity_check_ms,
      inactivity_timeout_ms: inactivity_timeout_ms,
      pending_reconnect_timer: nil,
      inactivity_timer: nil,
      request_waiters: %{},
      pending_queries: %{},
      subscriptions: %{},
      watchers: %{},
      connection_watchers: %{},
      backoff: Backoff.new(Keyword.get(opts, :backoff, [])),
      auth_source: auth_source,
      active_token: Auth.Token.none(),
      auth_generation: 0,
      connection_generation: 0,
      pending_auth: nil,
      auth_ready: false,
      pending_messages: :queue.new(),
      connection_state: :connecting,
      monotonic_clock: monotonic_clock,
      system_clock: system_clock,
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

  def handle_call(:connection_state, _from, state) do
    {:reply, state.connection_state, state}
  end

  def handle_call({:watch_connection_state, owner, _opts}, _from, state) do
    ref = make_ref()
    watch = %ConnectionWatch{ref: ref}

    {:reply, {:ok, watch},
     %{state | connection_watchers: Map.put(state.connection_watchers, ref, owner)}}
  end

  def handle_call({:unwatch_connection_state, %ConnectionWatch{ref: ref}}, _from, state) do
    {:reply, :ok, %{state | connection_watchers: Map.delete(state.connection_watchers, ref)}}
  end

  def handle_call({:set_auth, token}, _from, state) do
    if Auth.Token.valid?(token) do
      pending_mode = pending_auth_mode(state)
      state = replace_auth_source(state, {:static, token})
      {:reply, :ok, set_static_auth(state, token, pending_mode)}
    else
      raise ArgumentError, "Invalid auth token"
    end
  end

  def handle_call({:set_auth_fetcher, nil}, _from, state) do
    token = Auth.Token.none()
    pending_mode = pending_auth_mode(state)
    state = replace_auth_source(state, {:static, token})
    {:reply, :ok, set_static_auth(state, token, pending_mode)}
  end

  def handle_call({:set_auth_fetcher, fetcher}, _from, state) do
    pending_mode = pending_auth_mode(state)
    state = replace_auth_source(state, {:fetcher, fetcher})

    next_state =
      if pending_mode == :connection do
        start_auth_resolution(state)
      else
        start_runtime_auth_fetch(state, pending_mode == :runtime)
      end

    {:reply, :ok, next_state}
  end

  def handle_call({:mutation, udf_path, args}, from, state) do
    dispatch_oneshot_request(&Core.prepare_mutation/3, udf_path, args, from, state)
  end

  def handle_call({:action, udf_path, args}, from, state) do
    dispatch_oneshot_request(&Core.prepare_action/3, udf_path, args, from, state)
  end

  def handle_call({:query, udf_path, args}, from, state) do
    with :ok <- validate_args(args) do
      {core, subscriber_id, initial} = Core.subscribe(state.core, udf_path, args)
      {core, messages} = Core.take_outbox(core)
      state = %{state | core: core}

      case dispatch_messages(state, messages) do
        {:ok, state} ->
          handle_query_result(state, core, subscriber_id, initial, from)

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
           state.monotonic_clock.() - state.last_server_response_ms >= state.inactivity_timeout_ms do
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
      client_ts: state.system_clock.()
    }

    state = %{
      state
      | last_server_response_ms: state.monotonic_clock.(),
        connection_count: state.connection_count + 1,
        connection_generation: state.connection_generation + 1,
        auth_ready: false,
        pending_auth: nil,
        pending_messages: :queue.new(),
        connection_state: :connecting
    }

    case dispatch_control_messages(state, [connect_message]) do
      {:ok, state} ->
        {:noreply, start_auth_resolution(state)}

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
      | last_server_response_ms: state.monotonic_clock.(),
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
       %{state | transport_pid: nil},
       inspect(reason)
     )}
  end

  def handle_info({:auth_fetch_complete, generation, result}, state) do
    if state.pending_auth && state.pending_auth.generation == generation do
      case state.pending_auth.mode do
        :connection -> {:noreply, complete_connection_auth(state, result)}
        :runtime -> {:noreply, complete_runtime_auth(state, result)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, transport_pid, reason}, %{transport_pid: transport_pid} = state) do
    {:noreply,
     schedule_reconnect(
       %{state | transport_pid: nil},
       "TransportExit: #{inspect(reason)}"
     )}
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("Ignoring unexpected Convex.Client message: #{inspect(message)}")
    {:noreply, state}
  end

  defp dispatch_oneshot_request(prepare_fn, udf_path, args, from, state) do
    with :ok <- validate_args(args) do
      {core, request_id} = prepare_fn.(state.core, udf_path, args)
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

  defp handle_query_result(state, _core, subscriber_id, nil, from) do
    {:noreply, %{state | pending_queries: Map.put(state.pending_queries, subscriber_id, from)}}
  end

  defp handle_query_result(state, core, subscriber_id, result, from) do
    {:ok, core} = Core.unsubscribe(core, subscriber_id)
    {core, unsubscribe_messages} = Core.take_outbox(core)
    GenServer.reply(from, result)

    case dispatch_messages(%{state | core: core}, unsubscribe_messages) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason} -> {:noreply, %{state | core: core}}
    end
  end

  defp dispatch_messages(state, messages) do
    if state.auth_ready do
      with {:ok, payloads} <- encode_messages(messages) do
        Enum.each(payloads, &send_payload(state, &1))

        {:ok, state}
      end
    else
      # Authentication owns message ordering: no function request may race an Authenticate.
      {:ok, queue_pending_messages(state, messages)}
    end
  end

  defp dispatch_control_messages(state, messages) do
    if state.transport_pid do
      with {:ok, payloads} <- encode_messages(messages) do
        Enum.each(payloads, &send_payload(state, &1))

        {:ok, state}
      end
    else
      {:error, "TransportNotConnected"}
    end
  end

  defp send_payload(state, payload) do
    if state.transport_pid do
      _result = state.transport_module.send_text(state.transport_pid, payload)
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

        _other_subscription, nested ->
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
      _result = state.transport_module.close(state.transport_pid)
    end

    # The task handle must remain reachable until cancellation; clearing it
    # first would leak a blocked fetcher across protocol-driven reconnects.
    state = cancel_pending_auth_task(state)

    schedule_reconnect(
      %{
        state
        | transport_pid: nil,
          auth_ready: false,
          pending_auth: nil,
          active_token: Auth.Token.none(),
          pending_messages: :queue.new()
      },
      reason
    )
  end

  defp schedule_reconnect(state, reason) do
    state = cancel_pending_auth_task(state)

    if state.pending_reconnect_timer do
      Process.cancel_timer(state.pending_reconnect_timer)
    end

    {delay, backoff} = Backoff.next_delay(state.backoff)
    timer = Process.send_after(self(), :reconnect_now, delay)

    state =
      %{state | backoff: backoff, last_close_reason: reason, pending_reconnect_timer: timer}

    transition_connection_state(state, :connecting)
  end

  defp schedule_inactivity_check(state) do
    if state.inactivity_timer do
      Process.cancel_timer(state.inactivity_timer)
    end

    timer = Process.send_after(self(), :check_inactivity, state.inactivity_check_ms)
    %{state | inactivity_timer: timer}
  end

  defp sync_url("https://" <> rest), do: "wss://" <> trim_trailing_slash(rest) <> "/api/sync"
  defp sync_url("http://" <> rest), do: "ws://" <> trim_trailing_slash(rest) <> "/api/sync"
  defp sync_url(url), do: trim_trailing_slash(url) <> "/api/sync"

  defp validate_args(args) when is_map(args) do
    case Value.encode(args) do
      {:ok, _encoded} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_args(_args), do: {:error, "Arguments must be a map"}

  defp replace_auth_source(state, source) do
    state = cancel_pending_auth_task(state)

    %{state | auth_source: source, auth_generation: state.auth_generation + 1, pending_auth: nil}
  end

  defp set_static_auth(state, _token, :connection), do: start_auth_resolution(state)

  defp set_static_auth(state, token, :runtime),
    do: complete_runtime_auth(state, {:ok, token})

  defp set_static_auth(state, token, nil), do: apply_static_auth(state, token)

  defp apply_static_auth(state, token) do
    if state.connection_state == :connected do
      {core, messages} = state.core |> Core.set_auth(token) |> Core.take_outbox()
      state = %{state | core: core, active_token: token}

      case dispatch_control_messages(state, messages) do
        {:ok, state} -> state
        {:error, reason} -> reconnect(state, "EncodeError: #{reason}")
      end
    else
      %{state | active_token: Auth.Token.none()}
    end
  end

  defp start_runtime_auth_fetch(state, preserve_pending) do
    # Revoke before the asynchronous fetch so a failure cannot continue under the prior credential.
    was_authenticated = state.connection_state == :connected and state.active_token.type != :none

    state = %{
      state
      | auth_ready: false,
        pending_messages: if(preserve_pending, do: state.pending_messages, else: :queue.new()),
        active_token: Auth.Token.none()
    }

    state = transition_connection_state(state, :connecting)

    revocation =
      if was_authenticated do
        {core, messages} = state.core |> Core.set_auth(Auth.Token.none()) |> Core.take_outbox()
        {%{state | core: core}, messages}
      else
        {state, []}
      end

    case dispatch_control_messages(elem(revocation, 0), elem(revocation, 1)) do
      {:ok, state} -> start_auth_fetch(state, false, :runtime)
      {:error, reason} -> reconnect(state, "EncodeError: #{reason}")
    end
  end

  defp pending_auth_mode(state) do
    if state.pending_auth, do: state.pending_auth.mode
  end

  defp cancel_pending_auth_task(state) do
    if state.pending_auth && state.pending_auth.task_pid do
      Process.exit(state.pending_auth.task_pid, :kill)
    end

    state
  end

  defp start_auth_resolution(state) do
    case state.auth_source do
      {:static, token} -> complete_connection_auth(state, {:ok, token})
      {:fetcher, _fetcher} -> start_auth_fetch(state, state.connection_count > 1, :connection)
    end
  end

  defp start_auth_fetch(state, force_refresh, mode) do
    {:fetcher, fetcher} = state.auth_source
    generation = {state.connection_generation, state.auth_generation}
    parent = self()

    task_result =
      Task.Supervisor.start_child(Convex.AuthTaskSupervisor, fn ->
        # Normalize crashes inside the wrapper so OTP never renders callback reasons or secrets.
        result =
          try do
            fetcher.(force_refresh: force_refresh)
          rescue
            _error -> {:error, :auth_fetch_failed}
          catch
            :exit, _reason -> {:error, :auth_fetch_failed}
            :throw, _value -> {:error, :auth_fetch_failed}
          end
          |> normalize_fetched_token()

        send(parent, {:auth_fetch_complete, generation, result})
      end)

    case task_result do
      {:ok, task_pid} ->
        %{state | pending_auth: %{generation: generation, mode: mode, task_pid: task_pid}}

      {:error, _reason} ->
        complete_auth_fetch_failure(state, mode)
    end
  end

  defp complete_connection_auth(state, result) do
    state =
      if state.connection_count > 1,
        do: %{state | pending_messages: :queue.new()},
        else: state

    token = anonymous_token_to_no_auth(error_to_anonymous(result))

    if auth_fetch_failed?(result),
      do: Logger.warning("Convex auth fetch failed; continuing anonymously")

    {core, messages} = connection_auth_messages(state, token)

    state = %{
      state
      | core: core,
        active_token: token || Auth.Token.none(),
        auth_ready: true,
        pending_auth: nil
    }

    finish_auth_messages(state, messages)
  end

  defp complete_runtime_auth(state, result) do
    token = anonymous_token_to_no_auth(error_to_anonymous(result))

    if auth_fetch_failed?(result),
      do: Logger.warning("Convex auth fetch failed; continuing anonymously")

    {core, messages} =
      case token do
        nil -> {state.core, []}
        token -> state.core |> Core.set_auth(token) |> Core.take_outbox()
      end

    state = %{
      state
      | core: core,
        active_token: token || Auth.Token.none(),
        auth_ready: true,
        pending_auth: nil
    }

    finish_auth_messages(state, messages)
  end

  defp connection_auth_messages(state, nil) do
    if state.connection_count == 1 do
      {state.core, []}
    else
      Core.rebuild_for_reconnect(state.core, :no_auth)
    end
  end

  defp connection_auth_messages(state, token) do
    if state.connection_count == 1 do
      state.core |> Core.set_auth(token) |> Core.take_outbox()
    else
      Core.rebuild_for_reconnect(state.core, {:token, token})
    end
  end

  defp finish_auth_messages(state, messages) do
    {auth_messages, business_messages} =
      Enum.split_with(messages, &match?(%Convex.Protocol.Messages.Authenticate{}, &1))

    pending_messages = :queue.to_list(state.pending_messages)
    state = %{state | pending_messages: :queue.new()}

    case dispatch_control_messages(state, auth_messages) do
      {:ok, state} ->
        case dispatch_messages(state, business_messages ++ pending_messages) do
          {:ok, state} -> transition_connection_state(state, :connected)
          {:error, reason} -> reconnect(state, "EncodeError: #{reason}")
        end

      {:error, reason} ->
        reconnect(state, "EncodeError: #{reason}")
    end
  end

  defp fetched_token({:ok, %Auth.Token{} = token}) do
    if Auth.Token.valid?(token), do: token
  end

  defp fetched_token(_result), do: :error

  defp error_to_anonymous(result) do
    case fetched_token(result) do
      :error -> nil
      token -> token
    end
  end

  defp anonymous_token_to_no_auth(%Auth.Token{type: :none}), do: nil
  defp anonymous_token_to_no_auth(token), do: token

  defp auth_fetch_failed?({:ok, %Auth.Token{} = token}), do: not Auth.Token.valid?(token)
  defp auth_fetch_failed?(_result), do: true

  defp complete_auth_fetch_failure(state, :connection),
    do: complete_connection_auth(state, {:error, :start_failed})

  defp complete_auth_fetch_failure(state, :runtime),
    do: complete_runtime_auth(state, {:error, :start_failed})

  defp normalize_fetched_token({:ok, %Auth.Token{} = token}) do
    if Auth.Token.valid?(token), do: {:ok, token}, else: {:error, :invalid_auth_token}
  end

  defp normalize_fetched_token({:error, _reason}), do: {:error, :auth_fetch_failed}
  defp normalize_fetched_token(_result), do: {:error, :invalid_auth_token}

  defp queue_pending_messages(state, messages) do
    queue = Enum.reduce(messages, state.pending_messages, &:queue.in/2)
    %{state | pending_messages: queue}
  end

  defp transition_connection_state(state, new_state) do
    if state.connection_state == new_state do
      state
    else
      Enum.each(state.connection_watchers, fn {ref, owner} ->
        send(owner, {:convex_connection_state, ref, new_state})
      end)

      %{state | connection_state: new_state}
    end
  end

  defp dispatch_messages!(state, messages) do
    case dispatch_messages(state, messages) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  defp trim_trailing_slash(url) do
    String.trim_trailing(url, "/")
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
