defmodule Convex.Transport.WebSocketTest do
  use ExUnit.Case, async: false

  alias Convex.Transport.WebSocket

  test "send_text failure closes the transport and notifies the owner" do
    {port, server} =
      start_server(fn socket ->
        receive do
          {:stop, caller} ->
            :gen_tcp.close(socket)
            send(caller, :server_stopped)
        after
          1_000 ->
            :gen_tcp.close(socket)
        end
      end)

    {:ok, transport} = WebSocket.start_link(owner: self(), url: "ws://localhost:#{port}/socket")
    assert_receive {:convex_transport, ^transport, :connected}

    monitor = Process.monitor(transport)
    closed_socket = closed_tcp_socket()

    :sys.replace_state(transport, fn state ->
      %{state | conn: %{state.conn | socket: closed_socket}}
    end)

    assert :ok = WebSocket.send_text(transport, "hello")

    assert_receive {:convex_transport, ^transport,
                    {:closed, %Mint.TransportError{reason: :closed}}},
                   1_000

    assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}, 1_000

    send(server, {:stop, self()})
    assert_receive :server_stopped, 1_000
  end

  test "invalid websocket frames close the transport and notify the owner" do
    {port, server} =
      start_server(fn socket ->
        Process.sleep(50)
        :ok = :gen_tcp.send(socket, <<0x83, 0x00>>)

        receive do
          {:stop, caller} ->
            :gen_tcp.close(socket)
            send(caller, :server_stopped)
        after
          1_000 ->
            :gen_tcp.close(socket)
        end
      end)

    {:ok, transport} = WebSocket.start_link(owner: self(), url: "ws://localhost:#{port}/socket")
    assert_receive {:convex_transport, ^transport, :connected}

    monitor = Process.monitor(transport)

    assert_receive {:convex_transport, ^transport, {:closed, reason}}, 1_000
    assert inspect(reason) =~ "unsupported_opcode"
    assert_receive {:DOWN, ^monitor, :process, ^transport, :normal}, 1_000

    send(server, {:stop, self()})
    assert_receive :server_stopped, 1_000
  end

  defp start_server(on_socket) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_addr, port}} = :inet.sockname(listener)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.close(listener)

        request = recv_http_request(socket)
        key = extract_websocket_key(request)
        :ok = :gen_tcp.send(socket, handshake_response(key))

        on_socket.(socket)
      end)

    {port, server}
  end

  defp recv_http_request(socket, acc \\ "") do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
      recv_http_request(socket, acc <> chunk)
    end
  end

  defp extract_websocket_key(request) do
    [_, key] = Regex.run(~r/\r\nsec-websocket-key:\s*([^\r\n]+)/i, request)
    key
  end

  defp handshake_response(key) do
    accept =
      :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      |> Base.encode64(padding: true)

    [
      "HTTP/1.1 101 Switching Protocols\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Accept: ",
      accept,
      "\r\n\r\n"
    ]
  end

  defp closed_tcp_socket do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_addr, port}} = :inet.sockname(listener)
    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      send(parent, {:accepted_socket, socket})
    end)

    {:ok, client_socket} =
      :gen_tcp.connect(~c"localhost", port, [:binary, packet: :raw, active: false])

    receive do
      {:accepted_socket, server_socket} ->
        :gen_tcp.close(server_socket)
    end

    :gen_tcp.close(listener)
    :gen_tcp.close(client_socket)
    client_socket
  end
end
