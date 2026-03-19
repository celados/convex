defmodule Convex.Transport.WebSocket do
  @moduledoc false

  use WebSockex

  @behaviour Convex.Transport

  @impl true
  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    url = Keyword.fetch!(opts, :url)
    headers = Keyword.get(opts, :headers, [])
    state = %{owner: owner}
    WebSockex.start_link(url, __MODULE__, state, extra_headers: headers)
  end

  @impl true
  def send_text(pid, text) do
    WebSockex.cast(pid, {:send_text, text})
  end

  @impl true
  def close(pid) do
    WebSockex.cast(pid, :close)
  end

  @impl true
  def handle_connect(_conn, state) do
    send(state.owner, {:convex_transport, self(), :connected})
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    send(state.owner, {:convex_transport, self(), {:text, payload}})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:send_text, text}, state) do
    {:reply, {:text, text}, state}
  end

  def handle_cast(:close, state) do
    {:close, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    send(state.owner, {:convex_transport, self(), {:closed, reason}})
    # Reconnect policy lives in Convex.Client so backoff/auth replay stay centralized.
    # Returning {:reconnect, ...} here would race with the owner-driven reconnect path.
    {:ok, state}
  end
end
