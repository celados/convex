defmodule Convex.Sync.CoreTest do
  use ExUnit.Case, async: true

  alias Convex.Protocol.Messages.{MutationResponse, QueryUpdated, StateVersion, Transition}
  alias Convex.Sync.Core

  test "duplicate subscribe reuses query and emits no extra server message" do
    state = Core.new()
    {state, subscriber_1, nil} = Core.subscribe(state, "messages:list", %{})
    {state, messages} = Core.take_outbox(state)

    assert subscriber_1 == {0, 0}
    assert length(messages) == 1

    {state, subscriber_2, nil} = Core.subscribe(state, "messages:list", %{})
    {_state, messages} = Core.take_outbox(state)

    assert subscriber_2 == {0, 1}
    assert messages == []
  end

  test "mutation completes only after transition reaches response ts" do
    state = Core.new()
    {state, _subscriber, _initial} = Core.subscribe(state, "messages:list", %{})
    {state, _request_id} = Core.prepare_mutation(state, "messages:send", %{"body" => "hi"})
    {state, _messages} = Core.take_outbox(state)

    assert {:ok, state, %{}, %{}} =
             Core.receive_message(
               state,
               %MutationResponse{
                 request_id: 0,
                 success: true,
                 result: %{"ok" => true},
                 ts: 5,
                 log_lines: []
               }
             )

    transition = %Transition{
      start_version: %StateVersion{query_set: 0, identity: 0, ts: 0},
      end_version: %StateVersion{query_set: 1, identity: 0, ts: 5},
      modifications: [%QueryUpdated{query_id: 0, value: [%{"body" => "hi"}], log_lines: []}]
    }

    assert {:ok, _state, %{0 => {:ok, [%{"body" => "hi"}]}}, %{0 => {:ok, %{"ok" => true}}}} =
             Core.receive_message(state, transition)
  end

  test "rebuild for reconnect replays auth, queries, and pending requests" do
    state = Core.new()
    state = Core.set_auth(state, "jwt-token")
    {state, _subscriber, _initial} = Core.subscribe(state, "messages:list", %{})
    {state, _request_id} = Core.prepare_action(state, "ai:generate", %{"prompt" => "hello"})
    {state, _drained} = Core.take_outbox(state)

    {_state, [auth, modify_query_set, action]} =
      Core.rebuild_for_reconnect(state, {:token, "jwt-token"})

    assert auth.token_type == "User"
    assert modify_query_set.base_version == 0
    assert action.request_id == 0
  end
end
