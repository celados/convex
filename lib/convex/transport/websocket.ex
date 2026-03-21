defmodule Convex.Transport.WebSocket do
  @moduledoc false

  use GenServer
  require Logger

  @behaviour Convex.Transport

  @upgrade_timeout 10_000

  defstruct [:owner, :conn, :websocket, :request_ref, closing?: false]

  # ── Transport behaviour ──────────────────────────

  @impl Convex.Transport
  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    url = Keyword.fetch!(opts, :url)
    headers = Keyword.get(opts, :headers, [])
    GenServer.start_link(__MODULE__, {owner, url, headers})
  end

  @impl Convex.Transport
  def send_text(pid, text) do
    GenServer.cast(pid, {:send_text, text})
  end

  @impl Convex.Transport
  def close(pid) do
    GenServer.cast(pid, :close)
  end

  # ── GenServer callbacks ──────────────────────────

  @impl GenServer
  def init({owner, url, headers}) do
    uri = URI.parse(url)

    {http_scheme, ws_scheme} =
      case uri.scheme do
        "ws" -> {:http, :ws}
        "wss" -> {:https, :wss}
      end

    path =
      case uri.query do
        nil -> uri.path || "/"
        query -> (uri.path || "/") <> "?" <> query
      end

    port = uri.port || if(http_scheme == :https, do: 443, else: 80)

    # Connect in passive mode so we can synchronously complete the upgrade handshake.
    # This ensures start_link blocks until the WebSocket is ready and prevents
    # messages from being dropped during the upgrade window.
    with {:ok, conn} <-
           Mint.HTTP.connect(http_scheme, uri.host, port, protocols: [:http1], mode: :passive),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, headers),
         {:ok, conn, websocket} <- await_upgrade(conn, ref),
         {:ok, conn} <- Mint.HTTP.set_mode(conn, :active) do
      send(owner, {:convex_transport, self(), :connected})
      {:ok, %__MODULE__{owner: owner, conn: conn, websocket: websocket, request_ref: ref}}
    else
      {:error, reason} -> {:stop, reason}
      {:error, _conn, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast({:send_text, text}, state) do
    case send_frame(state, {:text, text}) do
      {:ok, state} -> {:noreply, state}
      {:error, state, reason} -> close_with_reason(state, reason)
    end
  end

  def handle_cast(:close, state) do
    _ = send_frame(state, :close)
    Mint.HTTP.close(state.conn)
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        case handle_responses(%{state | conn: conn}, responses) do
          {:ok, state} ->
            if state.closing? do
              do_close(state)
            else
              {:noreply, state}
            end

          {:close, state, reason} ->
            close_with_reason(state, reason)
        end

      {:error, conn, reason, _responses} ->
        close_with_reason(%{state | conn: conn}, reason)

      :unknown ->
        {:noreply, state}
    end
  end

  # ── Synchronous upgrade handshake (passive mode) ──

  defp await_upgrade(conn, ref) do
    await_upgrade(conn, ref, _status = nil, _headers = nil)
  end

  defp await_upgrade(conn, ref, status, headers) do
    case Mint.WebSocket.recv(conn, 0, @upgrade_timeout) do
      {:ok, conn, responses} ->
        process_upgrade_responses(conn, ref, status, headers, responses)

      {:error, conn, reason, _responses} ->
        {:error, conn, reason}
    end
  end

  defp process_upgrade_responses(conn, ref, status, headers, []) do
    # Haven't seen :done yet — recv again
    await_upgrade(conn, ref, status, headers)
  end

  defp process_upgrade_responses(conn, ref, _status, headers, [{:status, ref, status} | rest]) do
    process_upgrade_responses(conn, ref, status, headers, rest)
  end

  defp process_upgrade_responses(conn, ref, status, _headers, [{:headers, ref, headers} | rest]) do
    process_upgrade_responses(conn, ref, status, headers, rest)
  end

  defp process_upgrade_responses(conn, ref, status, headers, [{:done, ref} | _rest]) do
    Mint.WebSocket.new(conn, ref, status, headers)
  end

  defp process_upgrade_responses(conn, ref, status, headers, [_other | rest]) do
    process_upgrade_responses(conn, ref, status, headers, rest)
  end

  # ── Active-mode response handling (post-upgrade) ──

  defp handle_responses(state, []), do: {:ok, state}

  defp handle_responses(%{request_ref: ref} = state, [{:data, ref, data} | rest]) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        case handle_frames(%{state | websocket: websocket}, frames) do
          {:ok, state} -> handle_responses(state, rest)
          {:close, state, reason} -> {:close, state, reason}
        end

      {:error, websocket, reason} ->
        Logger.warning("WebSocket decode error: #{inspect(reason)}")
        {:close, %{state | websocket: websocket}, reason}
    end
  end

  defp handle_responses(state, [_response | rest]) do
    handle_responses(state, rest)
  end

  # ── Frame handling ──

  defp handle_frames(state, []), do: {:ok, state}

  defp handle_frames(state, [{:text, text} | rest]) do
    send(state.owner, {:convex_transport, self(), {:text, text}})
    handle_frames(state, rest)
  end

  defp handle_frames(state, [{:ping, data} | rest]) do
    case send_frame(state, {:pong, data}) do
      {:ok, state} -> handle_frames(state, rest)
      {:error, state, reason} -> {:close, state, reason}
    end
  end

  defp handle_frames(state, [{:close, _code, _reason} | rest]) do
    handle_frames(%{state | closing?: true}, rest)
  end

  defp handle_frames(state, [{:error, reason} | _rest]) do
    Logger.warning("WebSocket frame error: #{inspect(reason)}")
    {:close, state, reason}
  end

  defp handle_frames(state, [_frame | rest]) do
    handle_frames(state, rest)
  end

  # ── Internal ──

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         state = %{state | websocket: websocket},
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      {:ok, %{state | conn: conn}}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}

      {:error, conn, reason} ->
        {:error, %{state | conn: conn}, reason}
    end
  end

  defp do_close(state) do
    _ = send_frame(state, :close)
    Mint.HTTP.close(state.conn)
    send(state.owner, {:convex_transport, self(), {:closed, :normal}})
    {:stop, :normal, state}
  end

  # Once frame encoding/sending fails, the connection state is no longer trustworthy.
  # Notify the owner immediately so the client can reconnect instead of timing out requests.
  defp close_with_reason(state, reason) do
    Mint.HTTP.close(state.conn)
    send(state.owner, {:convex_transport, self(), {:closed, reason}})
    {:stop, :normal, state}
  end
end
