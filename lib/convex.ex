defmodule Convex do
  @moduledoc """
  Convex Elixir client facade.
  """

  alias Convex.Client

  defdelegate start_link(opts), to: Client
  defdelegate query(client, udf_path, args, opts \\ []), to: Client
  defdelegate mutation(client, udf_path, args, opts \\ []), to: Client
  defdelegate action(client, udf_path, args, opts \\ []), to: Client
  defdelegate subscribe(client, udf_path, args, opts \\ []), to: Client
  defdelegate unsubscribe(client, subscription), to: Client
  defdelegate watch_all(client, opts \\ []), to: Client
  defdelegate unwatch_all(client, watch), to: Client
  defdelegate connection_state(client), to: Client
  defdelegate watch_connection_state(client, opts \\ []), to: Client
  defdelegate unwatch_connection_state(client, watch), to: Client
  defdelegate set_auth(client, token), to: Client
end
