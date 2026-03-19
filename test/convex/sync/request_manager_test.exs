defmodule Convex.Sync.RequestManagerTest do
  use ExUnit.Case, async: true

  alias Convex.Protocol.Messages.{Action, Mutation}
  alias Convex.Sync.RequestManager

  test "action responses complete immediately" do
    manager =
      RequestManager.new()
      |> RequestManager.track_request(1, :action, %Action{
        request_id: 1,
        udf_path: "ai:generate",
        args: %{}
      })

    assert {:ok, manager, %{1 => {:ok, "done"}}} =
             RequestManager.update_request(manager, 1, :action, {:ok, "done"}, nil)

    assert manager.ongoing_requests == %{}
  end

  test "successful mutation waits for transition" do
    manager =
      RequestManager.new()
      |> RequestManager.track_request(2, :mutation, %Mutation{
        request_id: 2,
        udf_path: "messages:send",
        args: %{}
      })

    assert {:ok, manager, %{}} =
             RequestManager.update_request(manager, 2, :mutation, {:ok, %{"ok" => true}}, 10)

    assert {manager, %{}} = RequestManager.finalize_completed_requests(manager, 9)

    assert {_manager, %{2 => {:ok, %{"ok" => true}}}} =
             RequestManager.finalize_completed_requests(manager, 10)
  end

  test "replay order sorts pending requests by timestamp descending" do
    manager =
      RequestManager.new()
      |> RequestManager.track_request(1, :mutation, %Mutation{
        request_id: 1,
        udf_path: "a:b",
        args: %{}
      })
      |> RequestManager.track_request(2, :mutation, %Mutation{
        request_id: 2,
        udf_path: "c:d",
        args: %{}
      })
      |> RequestManager.track_request(3, :action, %Action{
        request_id: 3,
        udf_path: "e:f",
        args: %{}
      })

    {:ok, manager, %{}} = RequestManager.update_request(manager, 1, :mutation, {:ok, "first"}, 10)
    {:ok, manager, %{}} = RequestManager.update_request(manager, 2, :mutation, {:ok, "second"}, 5)

    assert [%Mutation{request_id: 1}, %Mutation{request_id: 2}, %Action{request_id: 3}] =
             RequestManager.restart(manager)
  end
end
