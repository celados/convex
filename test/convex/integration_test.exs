defmodule Convex.IntegrationTest do
  @moduledoc """
  Integration tests against a real Convex deployment.

  These tests are excluded by default. Run with:

      CONVEX_URL=https://your-app.convex.cloud mix test --include integration

  They use the `todos` module (todos:list, todos:add, todos:remove)
  which must exist on the target deployment.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  @timeout 10_000

  setup_all do
    url =
      System.get_env("CONVEX_URL") ||
        raise """
        CONVEX_URL environment variable is required for integration tests.
        Example: CONVEX_URL=https://your-app.convex.cloud mix test --include integration
        """

    %{url: url}
  end

  setup %{url: url} do
    {:ok, client} = Convex.start_link(deployment_url: url)
    # Give the WebSocket time to connect
    Process.sleep(500)
    %{client: client}
  end

  describe "query" do
    test "todos:list returns a list", %{client: client} do
      assert {:ok, todos} = Convex.query(client, "todos:list", %{}, timeout: @timeout)
      assert is_list(todos)
    end
  end

  describe "mutation" do
    test "todos:add creates a todo and todos:remove deletes it", %{client: client} do
      # Create
      assert {:ok, id} =
               Convex.mutation(client, "todos:add", %{"text" => "elixir_integration_test"},
                 timeout: @timeout
               )

      assert is_binary(id)

      # Verify it shows up in the list
      assert {:ok, todos} = Convex.query(client, "todos:list", %{}, timeout: @timeout)
      assert Enum.any?(todos, fn t -> t["text"] == "elixir_integration_test" end)

      # Clean up
      assert {:ok, _result} =
               Convex.mutation(client, "todos:remove", %{"id" => id}, timeout: @timeout)

      # Verify removal
      assert {:ok, todos} = Convex.query(client, "todos:list", %{}, timeout: @timeout)
      refute Enum.any?(todos, fn t -> t["text"] == "elixir_integration_test" end)
    end
  end

  describe "subscribe" do
    test "receives reactive updates when data changes", %{client: client} do
      {:ok, subscription} = Convex.subscribe(client, "todos:list", %{})
      ref = subscription.ref

      # Wait for the initial value
      assert_receive {:convex, ^ref, {:ok, initial_todos}}, @timeout
      assert is_list(initial_todos)

      # Mutate — should trigger an update
      {:ok, id} =
        Convex.mutation(client, "todos:add", %{"text" => "subscribe_test"}, timeout: @timeout)

      # Wait for the reactive update
      assert_receive {:convex, ^ref, {:ok, updated_todos}}, @timeout
      assert Enum.any?(updated_todos, fn t -> t["text"] == "subscribe_test" end)

      # Clean up
      Convex.unsubscribe(client, subscription)
      {:ok, _result} = Convex.mutation(client, "todos:remove", %{"id" => id}, timeout: @timeout)
    end
  end

  describe "watch_all" do
    test "emits consistent snapshots across subscriptions", %{client: client} do
      {:ok, sub} = Convex.subscribe(client, "todos:list", %{})
      {:ok, watch} = Convex.watch_all(client)
      watch_ref = watch.ref

      # Should receive a snapshot once the query resolves
      assert_receive {:convex_watch, ^watch_ref, snapshot}, @timeout
      assert is_map(snapshot)

      # Clean up
      Convex.unwatch_all(client, watch)
      Convex.unsubscribe(client, sub)
    end
  end
end
