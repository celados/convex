defmodule Convex.ClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Convex.Auth
  alias Convex.Client
  alias Convex.Sync.Core
  alias Convex.Transport.Mock

  defmodule FailingTransport do
    @behaviour Convex.Transport

    @impl true
    def start_link(_opts), do: {:error, :econnrefused}

    @impl true
    def send_text(_pid, _text), do: :ok

    @impl true
    def close(_pid), do: :ok
  end

  defmodule ControlledTransport do
    @behaviour Convex.Transport

    use GenServer

    defstruct [:owner, sent_messages: []]

    @impl true
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def send_text(pid, text) do
      GenServer.cast(pid, {:send_text, text})
    end

    @impl true
    def close(pid) do
      GenServer.cast(pid, :close)
    end

    def connect(pid) do
      GenServer.cast(pid, :connect)
    end

    def messages(pid) do
      GenServer.call(pid, :messages)
    end

    @impl true
    def init(opts) do
      owner = Keyword.fetch!(opts, :owner)
      {:ok, %__MODULE__{owner: owner}}
    end

    @impl true
    def handle_cast(:connect, state) do
      send(state.owner, {:convex_transport, self(), :connected})
      {:noreply, state}
    end

    def handle_cast({:send_text, text}, state) do
      {:noreply, %{state | sent_messages: [text | state.sent_messages]}}
    end

    def handle_cast(:close, state) do
      send(state.owner, {:convex_transport, self(), {:closed, :normal}})
      {:stop, :normal, state}
    end

    @impl true
    def handle_call(:messages, _from, state) do
      {:reply, Enum.reverse(state.sent_messages), state}
    end
  end

  defmodule CrashableTransport do
    @behaviour Convex.Transport

    use GenServer

    defstruct [:owner]

    @impl true
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def send_text(_pid, _text), do: :ok

    @impl true
    def close(pid) do
      GenServer.cast(pid, :close)
    end

    def crash(pid, reason \\ :boom) do
      GenServer.cast(pid, {:crash, reason})
    end

    @impl true
    def init(opts) do
      owner = Keyword.fetch!(opts, :owner)
      send(owner, {:convex_transport, self(), :connected})
      {:ok, %__MODULE__{owner: owner}}
    end

    @impl true
    def handle_cast(:close, state) do
      {:stop, :normal, state}
    end

    def handle_cast({:crash, reason}, state) do
      {:stop, reason, state}
    end
  end

  test "cold query subscribes, waits for transition, and unsubscribes" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000
      )

    transport = :sys.get_state(client).transport_pid

    task = Task.async(fn -> Client.query(client, "messages:list", %{}) end)

    wait_until(fn ->
      sent = Mock.sent_messages(transport)
      Enum.any?(sent, &(&1["type"] == "ModifyQuerySet"))
    end)

    Mock.inject_server_message(transport, %{
      "type" => "Transition",
      "startVersion" => %{"querySet" => 0, "identity" => 0, "ts" => "AAAAAAAAAAA="},
      "endVersion" => %{"querySet" => 1, "identity" => 0, "ts" => "AQAAAAAAAAA="},
      "modifications" => [
        %{
          "type" => "QueryUpdated",
          "queryId" => 0,
          "value" => [%{"body" => "hi"}],
          "logLines" => []
        }
      ]
    })

    assert {:ok, [%{"body" => "hi"}]} = Task.await(task, 1_000)

    wait_until(fn ->
      sent = Mock.sent_messages(transport)

      Enum.any?(sent, fn payload ->
        payload["type"] == "ModifyQuerySet" and
          Enum.any?(payload["modifications"], &(&1["type"] == "Remove"))
      end)
    end)
  end

  test "watch_all emits consistent snapshots for active subscriptions" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000
      )

    transport = :sys.get_state(client).transport_pid
    {:ok, subscription} = Client.subscribe(client, "messages:list", %{})
    {:ok, watch} = Client.watch_all(client)
    subscription_ref = subscription.ref
    watch_ref = watch.ref

    Mock.inject_server_message(transport, %{
      "type" => "Transition",
      "startVersion" => %{"querySet" => 0, "identity" => 0, "ts" => "AAAAAAAAAAA="},
      "endVersion" => %{"querySet" => 1, "identity" => 0, "ts" => "AQAAAAAAAAA="},
      "modifications" => [
        %{
          "type" => "QueryUpdated",
          "queryId" => 0,
          "value" => [%{"body" => "hi"}],
          "logLines" => []
        }
      ]
    })

    assert_receive {:convex, ^subscription_ref, {:ok, [%{"body" => "hi"}]}}
    assert_receive {:convex_watch, ^watch_ref, %{{0, 0} => {:ok, [%{"body" => "hi"}]}}}
  end

  test "connection_state getter and watcher track connection lifecycle" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: ControlledTransport,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 1.0 end]
      )

    assert Client.connection_state(client) == :connecting
    {:ok, watch} = Client.watch_connection_state(client)
    ref = watch.ref

    refute_receive {:convex_connection_state, ^ref, _}, 50

    transport = wait_for_transport(client)
    ControlledTransport.connect(transport)

    assert_receive {:convex_connection_state, ^ref, :connected}
    assert Client.connection_state(client) == :connected

    ControlledTransport.close(transport)

    assert_receive {:convex_connection_state, ^ref, :connecting}
    assert Client.connection_state(client) == :connecting

    refute_receive {:convex_connection_state, ^ref, _}, 50

    new_transport = wait_until_value(fn -> current_transport_pid(client, transport) end)
    ControlledTransport.connect(new_transport)

    assert_receive {:convex_connection_state, ^ref, :connected}
    assert Client.connection_state(client) == :connected
  end

  test "connection_state watcher does not emit duplicate connecting events while retries fail" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: FailingTransport,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 0.5 end]
      )

    assert Client.connection_state(client) == :connecting
    {:ok, watch} = Client.watch_connection_state(client)
    ref = watch.ref

    Process.sleep(100)

    refute_receive {:convex_connection_state, ^ref, :connecting}, 50
    refute_receive {:convex_connection_state, ^ref, :connected}, 50

    Process.exit(client, :normal)
  end

  test "unwatch_connection_state stops future notifications" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: ControlledTransport,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 0.0 end]
      )

    {:ok, watch} = Client.watch_connection_state(client)
    ref = watch.ref

    transport = wait_for_transport(client)
    ControlledTransport.connect(transport)

    assert_receive {:convex_connection_state, ^ref, :connected}
    assert :ok = Client.unwatch_connection_state(client, watch)

    ControlledTransport.close(transport)

    refute_receive {:convex_connection_state, ^ref, _}, 100
  end

  test "transport crash does not kill client and triggers reconnect" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210/",
        transport_module: CrashableTransport,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 0.0 end]
      )

    assert Process.alive?(client)
    assert :sys.get_state(client).ws_url == "ws://localhost:3210/api/sync"

    transport = wait_for_transport(client)
    assert Client.connection_state(client) == :connected

    CrashableTransport.crash(transport, :boom)

    new_transport = wait_until_value(fn -> current_transport_pid(client, transport) end)

    assert Process.alive?(client)
    assert is_pid(new_transport)
    assert new_transport != transport
    assert :sys.get_state(client).last_close_reason == "TransportExit: :boom"
  end

  test "startVersion mismatch triggers reconnect" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 0.0 end]
      )

    transport = wait_for_transport(client)

    Mock.inject_server_message(transport, %{
      "type" => "Transition",
      "startVersion" => %{"querySet" => 9, "identity" => 0, "ts" => "AAAAAAAAAAA="},
      "endVersion" => %{"querySet" => 10, "identity" => 0, "ts" => "AQAAAAAAAAA="},
      "modifications" => []
    })

    new_transport = wait_until_value(fn -> current_transport_pid(client, transport) end)

    assert new_transport != transport
    assert :sys.get_state(client).last_close_reason == "StartVersionMismatch"
  end

  test "auth_fetcher is applied on the initial connection" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        auth_fetcher: fn force_refresh: force_refresh ->
          refute force_refresh
          {:ok, Auth.Token.user("jwt-initial")}
        end
      )

    transport = wait_for_transport(client)

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(fn payload ->
        payload["type"] == "Authenticate" and payload["value"] == "jwt-initial"
      end)
    end)
  end

  test "set_admin_auth sends an admin impersonation message" do
    identity = Auth.Identity.new(token_identifier: "convex|user")

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000
      )

    transport = wait_for_transport(client)
    assert :ok = Client.set_admin_auth(client, "deploy-key", identity)

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(fn payload ->
        payload["type"] == "Authenticate" and payload["tokenType"] == "Admin" and
          payload["actingAs"]["tokenIdentifier"] == "convex|user"
      end)
    end)
  end

  test "business messages wait for asynchronous authentication" do
    test_pid = self()

    fetcher = fn force_refresh: force_refresh ->
      send(test_pid, {:auth_fetch, self(), force_refresh})

      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, :timeout}
      end
    end

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        auth_fetcher: fetcher
      )

    transport = wait_for_transport(client)
    assert_receive {:auth_fetch, fetcher_pid, false}

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(&(&1["type"] == "Connect"))
    end)

    task = Task.async(fn -> Client.subscribe(client, "messages:list", %{}) end)
    Process.sleep(50)
    assert Mock.sent_messages(transport) |> Enum.map(& &1["type"]) == ["Connect"]

    send(fetcher_pid, {:release, {:ok, Auth.Token.user("jwt-secret")}})
    assert {:ok, _subscription} = Task.await(task, 1_000)

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.map(& &1["type"])
      |> Enum.count(&(&1 == "ModifyQuerySet")) == 1
    end)

    assert ["Connect", "Authenticate", "ModifyQuerySet"] =
             Mock.sent_messages(transport) |> Enum.map(& &1["type"])
  end

  test "static auth can replace an unresolved initial fetcher" do
    test_pid = self()

    fetcher = fn force_refresh: force_refresh ->
      send(test_pid, {:unresolved_initial_fetch, self(), force_refresh})

      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, :timeout}
      end
    end

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        auth_fetcher: fetcher
      )

    transport = wait_for_transport(client)
    assert_receive {:unresolved_initial_fetch, old_fetch_pid, false}

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(&(&1["type"] == "Connect"))
    end)

    assert :ok = Client.set_auth(client, "jwt-replacement")
    wait_until(fn -> Client.connection_state(client) == :connected end)

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(&(&1["type"] == "Authenticate"))
    end)

    assert [
             %{"type" => "Connect"},
             %{"type" => "Authenticate", "baseVersion" => 0, "value" => "jwt-replacement"}
           ] =
             Mock.sent_messages(transport)

    refute Process.alive?(old_fetch_pid)
    send(old_fetch_pid, {:release, {:ok, Auth.Token.user("jwt-old")}})
    Process.sleep(50)
    assert Enum.count(Mock.sent_messages(transport), &(&1["type"] == "Authenticate")) == 1
  end

  test "a fetcher can replace an unresolved initial fetcher without losing queued work" do
    test_pid = self()

    initial_fetcher = fn force_refresh: force_refresh ->
      send(test_pid, {:initial_fetcher, self(), force_refresh})

      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, :timeout}
      end
    end

    replacement_fetcher = fn force_refresh: force_refresh ->
      send(test_pid, {:replacement_fetcher, self(), force_refresh})
      {:ok, Auth.Token.user("jwt-replacement")}
    end

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        auth_fetcher: initial_fetcher
      )

    transport = wait_for_transport(client)
    assert_receive {:initial_fetcher, old_fetch_pid, false}
    task = Task.async(fn -> Client.subscribe(client, "messages:list", %{}) end)
    Process.sleep(50)
    assert Mock.sent_messages(transport) |> Enum.map(& &1["type"]) == ["Connect"]

    assert :ok = Client.set_auth_fetcher(client, replacement_fetcher)
    assert_receive {:replacement_fetcher, _replacement_pid, false}
    assert {:ok, _subscription} = Task.await(task, 1_000)

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(&(&1["type"] == "ModifyQuerySet"))
    end)

    assert ["Connect", "Authenticate", "ModifyQuerySet"] =
             Mock.sent_messages(transport) |> Enum.map(& &1["type"])

    send(old_fetch_pid, {:release, {:ok, Auth.Token.user("jwt-old")}})
    Process.sleep(50)
    assert Enum.count(Mock.sent_messages(transport), &(&1["type"] == "Authenticate")) == 1
  end

  test "anonymous connections remain at identity version zero" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000
      )

    transport = wait_for_transport(client)

    wait_until(fn -> Client.connection_state(client) == :connected end)

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(&(&1["type"] == "Connect"))
    end)

    assert Mock.sent_messages(transport) |> Enum.map(& &1["type"]) == ["Connect"]
  end

  test "static auth set before the first connection authenticates once at base version zero" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: ControlledTransport,
        inactivity_check_ms: 100_000
      )

    transport = wait_for_transport(client)
    assert :ok = Client.set_auth(client, "jwt-secret")
    ControlledTransport.connect(transport)

    wait_until(fn -> Client.connection_state(client) == :connected end)
    wait_until(fn -> length(ControlledTransport.messages(transport)) == 2 end)

    assert [
             %{"type" => "Connect"},
             %{"type" => "Authenticate", "baseVersion" => 0, "tokenType" => "User"}
           ] =
             ControlledTransport.messages(transport) |> Enum.map(&Jason.decode!(&1))
  end

  test "runtime fetcher replacement revokes the old credential before fetching" do
    test_pid = self()

    fetcher = fn force_refresh: force_refresh ->
      send(test_pid, {:runtime_fetch, self(), force_refresh})

      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, :timeout}
      end
    end

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: ControlledTransport,
        inactivity_check_ms: 100_000,
        auth: Auth.Token.user("jwt-old")
      )

    transport = wait_for_transport(client)
    ControlledTransport.connect(transport)
    wait_until(fn -> Client.connection_state(client) == :connected end)
    {:ok, watch} = Client.watch_connection_state(client)
    watch_ref = watch.ref

    assert :ok = Client.set_auth_fetcher(client, fetcher)
    assert_receive {:runtime_fetch, fetcher_pid, false}

    task = Task.async(fn -> Client.subscribe(client, "messages:list", %{}) end)
    Process.sleep(50)

    assert [
             %{"type" => "Connect"},
             %{"type" => "Authenticate", "baseVersion" => 0},
             %{"type" => "Authenticate", "baseVersion" => 1, "tokenType" => "None"}
           ] =
             ControlledTransport.messages(transport) |> Enum.map(&Jason.decode!(&1))

    assert_receive {:convex_connection_state, ^watch_ref, :connecting}
    send(fetcher_pid, {:release, {:ok, Auth.Token.admin("deploy-key")}})
    assert {:ok, _subscription} = Task.await(task, 1_000)
    assert_receive {:convex_connection_state, ^watch_ref, :connected}

    wait_until(fn ->
      ControlledTransport.messages(transport)
      |> Enum.map(&Jason.decode!(&1))
      |> Enum.any?(fn payload -> payload["type"] == "ModifyQuerySet" end)
    end)

    messages = ControlledTransport.messages(transport) |> Enum.map(&Jason.decode!(&1))
    assert Enum.at(messages, 3)["type"] == "Authenticate"
    assert Enum.at(messages, 3)["baseVersion"] == 2
    assert Enum.at(messages, 3)["tokenType"] == "Admin"
    assert Enum.at(messages, 4)["type"] == "ModifyQuerySet"
    refute_receive {:convex_connection_state, ^watch_ref, _}, 50
  end

  test "logout replaces a fetcher and its identity cannot return on reconnect" do
    auth_fetcher = fn force_refresh: force_refresh ->
      if force_refresh,
        do: {:ok, Auth.Token.user("jwt-refreshed")},
        else: {:ok, Auth.Token.user("jwt-initial")}
    end

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 0.0 end],
        auth_fetcher: auth_fetcher
      )

    transport = wait_for_transport(client)
    wait_until(fn -> Client.connection_state(client) == :connected end)
    assert :ok = Client.set_auth(client, nil)

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(fn payload ->
        payload["type"] == "Authenticate" and payload["tokenType"] == "None"
      end)
    end)

    Mock.close(transport)
    new_transport = wait_until_value(fn -> current_transport_pid(client, transport) end)
    wait_until(fn -> Client.connection_state(client) == :connected end)

    wait_until(fn ->
      Mock.sent_messages(new_transport)
      |> Enum.any?(&(&1["type"] == "Connect"))
    end)

    assert Mock.sent_messages(new_transport) |> Enum.map(& &1["type"]) == ["Connect"]
  end

  test "runtime fetcher failure continues anonymously without the old credential" do
    test_pid = self()

    fetcher = fn force_refresh: force_refresh ->
      send(test_pid, {:failed_runtime_fetch, self(), force_refresh})

      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, :timeout}
      end
    end

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: ControlledTransport,
        inactivity_check_ms: 100_000,
        auth: Auth.Token.user("jwt-old")
      )

    transport = wait_for_transport(client)
    ControlledTransport.connect(transport)
    wait_until(fn -> Client.connection_state(client) == :connected end)
    assert :ok = Client.set_auth_fetcher(client, fetcher)
    assert_receive {:failed_runtime_fetch, fetcher_pid, false}

    task = Task.async(fn -> Client.subscribe(client, "messages:list", %{}) end)
    send(fetcher_pid, {:release, {:error, :network}})
    assert {:ok, _subscription} = Task.await(task, 1_000)
    wait_until(fn -> Client.connection_state(client) == :connected end)

    wait_until(fn ->
      ControlledTransport.messages(transport)
      |> Enum.map(&Jason.decode!(&1))
      |> Enum.any?(&(&1["type"] == "ModifyQuerySet"))
    end)

    messages = ControlledTransport.messages(transport) |> Enum.map(&Jason.decode!(&1))

    assert [%{"type" => "Connect"}, _user_auth, _logout_auth, %{"type" => "ModifyQuerySet"}] =
             messages

    assert Enum.count(messages, &(&1["type"] == "Authenticate")) == 2
    assert Process.alive?(client)
  end

  test "auth fetcher refresh flag is false initially and true on every reconnect" do
    test_pid = self()

    fetcher = fn force_refresh: force_refresh ->
      send(test_pid, {:refresh_sequence, force_refresh})
      {:ok, Auth.Token.user("jwt")}
    end

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 0.0 end],
        auth_fetcher: fetcher
      )

    transport = wait_for_transport(client)
    wait_until(fn -> Client.connection_state(client) == :connected end)
    assert_received {:refresh_sequence, false}

    Mock.close(transport)
    new_transport = wait_until_value(fn -> current_transport_pid(client, transport) end)
    wait_until(fn -> Client.connection_state(client) == :connected end)
    assert_received {:refresh_sequence, true}

    Mock.close(new_transport)
    newest_transport = wait_until_value(fn -> current_transport_pid(client, new_transport) end)
    wait_until(fn -> Client.connection_state(client) == :connected end)
    assert_received {:refresh_sequence, true}
    assert newest_transport != new_transport
  end

  test "late auth fetch results do not cross connection generations" do
    test_pid = self()

    fetcher = fn force_refresh: force_refresh ->
      send(test_pid, {:stale_fetch, self(), force_refresh})

      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, :timeout}
      end
    end

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 0.0 end],
        auth_fetcher: fetcher
      )

    old_transport = wait_for_transport(client)
    assert_receive {:stale_fetch, old_fetch_pid, false}
    Mock.close(old_transport)
    new_transport = wait_until_value(fn -> current_transport_pid(client, old_transport) end)
    assert_receive {:stale_fetch, new_fetch_pid, true}
    refute Process.alive?(old_fetch_pid)

    send(old_fetch_pid, {:release, {:ok, Auth.Token.user("jwt-old")}})
    Process.sleep(50)
    assert Mock.sent_messages(new_transport) |> Enum.map(& &1["type"]) == ["Connect"]

    send(new_fetch_pid, {:release, {:ok, Auth.Token.user("jwt-new")}})

    wait_until(fn ->
      Mock.sent_messages(new_transport)
      |> Enum.any?(fn payload ->
        payload["type"] == "Authenticate" and payload["value"] == "jwt-new"
      end)
    end)

    refute Enum.any?(Mock.sent_messages(new_transport), fn payload ->
             payload["type"] == "Authenticate" and payload["value"] == "jwt-old"
           end)
  end

  test "set_auth persists across reconnect without auth_fetcher" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 0.0 end]
      )

    transport = wait_for_transport(client)
    assert :ok = Client.set_auth(client, "jwt-manual")

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(fn payload ->
        payload["type"] == "Authenticate" and payload["value"] == "jwt-manual"
      end)
    end)

    Mock.close(transport)
    new_transport = wait_until_value(fn -> current_transport_pid(client, transport) end)

    wait_until(fn ->
      Mock.sent_messages(new_transport)
      |> Enum.any?(fn payload ->
        payload["type"] == "Authenticate" and payload["value"] == "jwt-manual"
      end)
    end)

    authentications =
      Enum.filter(Mock.sent_messages(new_transport), &(&1["type"] == "Authenticate"))

    assert [%{"baseVersion" => 0, "tokenType" => "User", "value" => "jwt-manual"}] =
             authentications
  end

  test "auth_fetcher returning nil clears previously fetched auth on reconnect" do
    auth_fetcher = fn force_refresh: force_refresh ->
      if force_refresh,
        do: {:ok, Auth.Token.none()},
        else: {:ok, Auth.Token.user("jwt-first")}
    end

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 0.0 end],
        auth_fetcher: auth_fetcher
      )

    transport = wait_for_transport(client)

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(fn payload ->
        payload["type"] == "Authenticate" and payload["value"] == "jwt-first"
      end)
    end)

    Mock.close(transport)
    new_transport = wait_until_value(fn -> current_transport_pid(client, transport) end)

    wait_until(fn ->
      Mock.sent_messages(new_transport)
      |> Enum.any?(fn payload -> payload["type"] == "Connect" end)
    end)

    refute Enum.any?(Mock.sent_messages(new_transport), fn payload ->
             payload["type"] == "Authenticate"
           end)
  end

  test "watch_all ignores ping and other non-transition messages" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000
      )

    transport = wait_for_transport(client)
    {:ok, _watch} = Client.watch_all(client)

    Mock.inject_server_message(transport, %{"type" => "Ping"})

    refute_receive {:convex_watch, _, _}, 200
  end

  test "watch_all emits a new snapshot when a query is removed" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000
      )

    transport = wait_for_transport(client)
    {:ok, _subscription} = Client.subscribe(client, "messages:list", %{})
    {:ok, watch} = Client.watch_all(client)
    watch_ref = watch.ref

    Mock.inject_server_message(transport, %{
      "type" => "Transition",
      "startVersion" => %{"querySet" => 0, "identity" => 0, "ts" => "AAAAAAAAAAA="},
      "endVersion" => %{"querySet" => 1, "identity" => 0, "ts" => "AQAAAAAAAAA="},
      "modifications" => [
        %{
          "type" => "QueryUpdated",
          "queryId" => 0,
          "value" => [%{"body" => "hi"}],
          "logLines" => []
        }
      ]
    })

    assert_receive {:convex_watch, ^watch_ref, %{{0, 0} => {:ok, [%{"body" => "hi"}]}}}

    Mock.inject_server_message(transport, %{
      "type" => "Transition",
      "startVersion" => %{"querySet" => 1, "identity" => 0, "ts" => "AQAAAAAAAAA="},
      "endVersion" => %{"querySet" => 1, "identity" => 0, "ts" => "AgAAAAAAAAA="},
      "modifications" => [
        %{"type" => "QueryRemoved", "queryId" => 0}
      ]
    })

    assert_receive {:convex_watch, ^watch_ref, %{}}
  end

  test "invalid query args fail immediately instead of hanging" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000
      )

    assert {:error, "Object keys must be strings"} =
             Client.query(client, "messages:list", %{bad: 1})
  end

  test "connect clientTs uses injected system clock instead of monotonic clock" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        monotonic_clock: fn -> -576_460_749_629 end,
        system_clock: fn -> 1_742_430_400_123 end
      )

    transport = wait_for_transport(client)

    wait_until(fn ->
      Mock.sent_messages(transport)
      |> Enum.any?(fn payload ->
        payload["type"] == "Connect" and payload["clientTs"] == 1_742_430_400_123
      end)
    end)
  end

  test "inactivity timeout triggers reconnect with injected clock" do
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, 0)

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        monotonic_clock: fn -> :atomics.get(clock, 1) end,
        inactivity_check_ms: 50,
        inactivity_timeout_ms: 1_000,
        backoff: [rng: fn -> 0.0 end]
      )

    transport = wait_for_transport(client)

    # Jump the clock past the inactivity timeout
    :atomics.put(clock, 1, 2_000)

    # Wait for the inactivity check to fire and trigger a reconnect
    new_transport = wait_until_value(fn -> current_transport_pid(client, transport) end)

    wait_until(fn ->
      Mock.sent_messages(new_transport)
      |> Enum.any?(fn p -> p["type"] == "Connect" end)
    end)

    assert :sys.get_state(client).last_close_reason == "InactiveServer"
  end

  test "transport start failure does not crash client and schedules reconnect" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: FailingTransport,
        inactivity_check_ms: 100_000,
        backoff: [base_ms: 1_000, rng: fn -> 0.5 end]
      )

    Process.sleep(50)

    assert Process.alive?(client)

    state = :sys.get_state(client)
    assert state.transport_pid == nil
    assert state.pending_reconnect_timer != nil
  end

  defp wait_until(fun, remaining \\ 20)

  defp wait_until(fun, remaining) when remaining > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, remaining - 1)
    end
  end

  test "invalid public auth input fails before reaching the client" do
    assert_raise ArgumentError, "auth and auth_fetcher are mutually exclusive", fn ->
      Client.start_link(
        deployment_url: "http://localhost:3210",
        auth: Auth.Token.user("jwt"),
        auth_fetcher: fn _opts -> {:ok, Auth.Token.none()} end
      )
    end

    assert_raise ArgumentError, "auth_token was removed; use auth: Auth.Token.t()", fn ->
      Client.start_link(
        deployment_url: "http://localhost:3210",
        auth_token: "jwt"
      )
    end

    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: ControlledTransport,
        inactivity_check_ms: 100_000
      )

    transport = wait_for_transport(client)

    assert_raise ArgumentError, "User credential must be a non-empty string", fn ->
      Client.set_auth(client, :not_a_jwt)
    end

    assert ControlledTransport.messages(transport) == []
    assert Process.alive?(client)
  end

  test "client-owned auth state does not expose credentials through inspect" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        auth: Auth.Token.user("jwt-secret-canary")
      )

    wait_until(fn -> Client.connection_state(client) == :connected end)
    state = :sys.get_state(client)
    authenticated_core = Core.set_auth(Core.new(), state.active_token)

    refute inspect(state) =~ "jwt-secret-canary"
    refute inspect(authenticated_core) =~ "jwt-secret-canary"
    assert inspect(state.active_token) =~ "<redacted>"
  end

  test "auth fetcher crash diagnostics do not expose callback reasons" do
    logs =
      capture_log(fn ->
        {:ok, client} =
          Client.start_link(
            deployment_url: "http://localhost:3210",
            transport_module: Mock,
            inactivity_check_ms: 100_000,
            auth_fetcher: fn _opts -> raise "jwt-secret-canary" end
          )

        wait_until(fn -> Client.connection_state(client) == :connected end)
        assert Process.alive?(client)
      end)

    assert logs =~ "Convex auth fetch failed; continuing anonymously"
    refute logs =~ "jwt-secret-canary"
  end

  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until_value(fun, remaining \\ 20)

  defp wait_until_value(fun, remaining) when remaining > 0 do
    case fun.() do
      nil ->
        Process.sleep(25)
        wait_until_value(fun, remaining - 1)

      value ->
        value
    end
  end

  defp wait_until_value(_fun, 0), do: flunk("value not available in time")

  defp wait_for_transport(client) do
    wait_until_value(fn ->
      case :sys.get_state(client).transport_pid do
        nil -> nil
        transport -> transport
      end
    end)
  end

  defp current_transport_pid(client, old_transport) do
    case :sys.get_state(client).transport_pid do
      nil -> nil
      ^old_transport -> nil
      transport -> transport
    end
  end
end
