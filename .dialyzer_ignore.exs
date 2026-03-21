[
  # Mint.WebSocket.recv/3 delegates to Mint.HTTP.recv/3 which CAN return
  # {:error, conn, reason, responses}, but Dialyzer's type inference
  # through the wrapper doesn't see this branch.
  {"lib/convex/transport/websocket.ex", :pattern_match}
]
