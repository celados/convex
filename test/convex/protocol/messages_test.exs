defmodule Convex.Protocol.MessagesTest do
  use ExUnit.Case, async: true

  alias Convex.Auth

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

  @enforced_structs [
    {StateVersion, [:query_set, :identity, :ts]},
    {Add, [:query_id, :udf_path, :args]},
    {Remove, [:query_id]},
    {Connect, [:session_id, :connection_count]},
    {ModifyQuerySet, [:base_version, :new_version, :modifications]},
    {Mutation, [:request_id, :udf_path, :args]},
    {Action, [:request_id, :udf_path, :args]},
    {Authenticate, [:base_version, :token]},
    {QueryUpdated, [:query_id, :value, :log_lines]},
    {QueryFailed, [:query_id, :error_message, :log_lines]},
    {QueryRemoved, [:query_id]},
    {Transition, [:start_version, :end_version, :modifications]},
    {MutationResponse, [:request_id, :success, :result, :log_lines]},
    {ActionResponse, [:request_id, :success, :result, :log_lines]},
    {TransitionChunk, [:chunk, :part_number, :total_parts, :transition_id]},
    {AuthError, [:error]},
    {FatalError, [:error]}
  ]

  describe "enforce_keys" do
    for {mod, keys} <- @enforced_structs do
      test "#{inspect(mod)} raises without required keys #{inspect(keys)}" do
        assert_raise ArgumentError, fn -> struct!(unquote(mod), %{}) end
      end

      test "#{inspect(mod)} constructs with all required keys" do
        fields = Map.new(unquote(keys), fn k -> {k, :test} end)
        assert %unquote(mod){} = struct!(unquote(mod), fields)
      end
    end
  end

  describe "Ping has no required keys" do
    test "constructs with empty fields" do
      assert %Ping{} = struct!(Ping, %{})
    end
  end

  describe "optional field defaults" do
    test "Add defaults journal and component_path to :absent" do
      add = struct!(Add, %{query_id: 0, udf_path: "m:f", args: []})
      assert add.journal == :absent
      assert add.component_path == :absent
    end

    test "Mutation defaults component_path to :absent" do
      m = struct!(Mutation, %{request_id: 0, udf_path: "m:f", args: []})
      assert m.component_path == :absent
    end

    test "Authenticate carries the opaque auth token" do
      token = Auth.Token.user("jwt")
      a = struct!(Authenticate, %{base_version: 0, token: token})
      assert a.token == token
    end

    test "QueryFailed defaults error_data and journal to :absent" do
      qf = struct!(QueryFailed, %{query_id: 0, error_message: "err", log_lines: []})
      assert qf.error_data == :absent
      assert qf.journal == :absent
    end

    test "MutationResponse defaults error_data to :absent and ts to nil" do
      mr = struct!(MutationResponse, %{request_id: 0, success: true, result: nil, log_lines: []})
      assert mr.error_data == :absent
      assert mr.ts == nil
    end

    test "ActionResponse defaults error_data to :absent" do
      ar = struct!(ActionResponse, %{request_id: 0, success: true, result: nil, log_lines: []})
      assert ar.error_data == :absent
    end

    test "Connect optional fields default to nil" do
      c = struct!(Connect, %{session_id: "uuid", connection_count: 0})
      assert c.last_close_reason == nil
      assert c.max_observed_timestamp == nil
      assert c.client_ts == nil
    end

    test "Transition optional fields default to nil" do
      t = struct!(Transition, %{start_version: %{}, end_version: %{}, modifications: []})
      assert t.client_clock_skew == nil
      assert t.server_ts == nil
    end
  end
end
