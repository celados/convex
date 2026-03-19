defmodule Convex.ClientTest do
  use ExUnit.Case, async: false

  alias Convex.Client
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

  test "auth_fetcher is applied on the initial connection" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: Mock,
        inactivity_check_ms: 100_000,
        auth_fetcher: fn force_refresh: force_refresh ->
          refute force_refresh
          "jwt-initial"
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
  end

  test "auth_fetcher returning nil clears previously fetched auth on reconnect" do
    auth_fetcher = fn force_refresh: force_refresh ->
      if force_refresh, do: nil, else: "jwt-first"
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

  test "transport start failure does not crash client and schedules reconnect" do
    {:ok, client} =
      Client.start_link(
        deployment_url: "http://localhost:3210",
        transport_module: FailingTransport,
        inactivity_check_ms: 100_000,
        backoff: [rng: fn -> 0.5 end]
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
