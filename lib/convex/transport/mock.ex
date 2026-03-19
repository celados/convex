defmodule Convex.Transport.Mock do
  @moduledoc false

  use GenServer

  @behaviour Convex.Transport

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

  def sent_messages(pid) do
    GenServer.call(pid, :sent_messages)
  end

  def inject_server_message(pid, message) when is_binary(message) do
    GenServer.cast(pid, {:inject, message})
  end

  def inject_server_message(pid, message) do
    {:ok, encoded} = Jason.encode(message)
    inject_server_message(pid, encoded)
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    send(owner, {:convex_transport, self(), :connected})
    {:ok, %__MODULE__{owner: owner}}
  end

  @impl true
  def handle_call(:sent_messages, _from, state) do
    decoded =
      Enum.map(Enum.reverse(state.sent_messages), fn payload ->
        {:ok, json} = Jason.decode(payload)
        json
      end)

    {:reply, decoded, state}
  end

  @impl true
  def handle_cast({:send_text, text}, state) do
    {:noreply, %{state | sent_messages: [text | state.sent_messages]}}
  end

  def handle_cast({:inject, payload}, state) do
    send(state.owner, {:convex_transport, self(), {:text, payload}})
    {:noreply, state}
  end

  def handle_cast(:close, state) do
    send(state.owner, {:convex_transport, self(), {:closed, :normal}})
    {:stop, :normal, state}
  end
end
