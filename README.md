# Convex

Pure Elixir client for [Convex](https://convex.dev) — the backend application platform.

Connects to Convex deployments over WebSocket using the native sync protocol. Supports queries, mutations, actions, real-time subscriptions, authentication, and automatic reconnection with exponential backoff.

## Features

- **Pure Elixir** — no NIFs, no Rust dependencies
- **Real-time subscriptions** — live query results pushed to your processes
- **Consistent snapshots** — `watch_all` delivers atomic multi-query views
- **Automatic reconnection** — exponential backoff with jitter, full state replay on reconnect
- **Auth support** — static tokens, callback-based token fetchers, admin auth
- **Clean architecture** — pure state machine core (`Convex.Sync.Core`), effects at the edges

## Installation

```elixir
def deps do
  [
    {:convex, git: "https://github.com/ethan-huo/convex.git"}
  ]
end
```

## Quick Start

```elixir
# Start a client
{:ok, client} = Convex.start_link(deployment_url: "https://your-app.convex.cloud")

# One-shot query
{:ok, messages} = Convex.query(client, "messages:list", %{"channel" => "general"})

# Mutation
{:ok, _} = Convex.mutation(client, "messages:send", %{"body" => "hello from elixir"})

# Action
{:ok, result} = Convex.action(client, "ai:generate", %{"prompt" => "hello"})
```

## Subscriptions

Subscribe to a query and receive live updates as messages:

```elixir
{:ok, sub} = Convex.subscribe(client, "messages:list", %{"channel" => "general"})

# Your process receives:
#   {:convex, ref, {:ok, [%{"body" => "hello"}, ...]}}
#   {:convex, ref, {:error, "something went wrong"}}

receive do
  {:convex, ref, {:ok, messages}} ->
    IO.inspect(messages, label: "live update")
end

# Stop receiving updates
Convex.unsubscribe(client, sub)
```

## Watch All (Consistent Multi-Query View)

Get a continuous stream of consistent snapshots across all active subscriptions:

```elixir
{:ok, watch} = Convex.watch_all(client)

# Your process receives:
#   {:convex_watch, ref, %{subscriber_id => result, ...}}

receive do
  {:convex_watch, ref, snapshot} ->
    IO.inspect(snapshot, label: "consistent snapshot")
end

Convex.unwatch_all(client, watch)
```

## Authentication

```elixir
# Static token
Convex.set_auth(client, "your-jwt-token")

# Clear auth
Convex.set_auth(client, nil)

# Token fetcher (called on connect and reconnect)
{:ok, client} = Convex.start_link(
  deployment_url: "https://your-app.convex.cloud",
  auth_fetcher: fn force_refresh: force_refresh ->
    # Return a fresh token string, or nil to clear auth
    fetch_token(force_refresh)
  end
)
```

## Value Types

Convex has its own type system. The mapping between Elixir and Convex:

| Elixir | Convex | Notes |
|--------|--------|-------|
| `nil` | Null | |
| `true` / `false` | Boolean | |
| `"hello"` | String | |
| `3.14` | Float64 | |
| `42` | Float64 | Native integers encode as Float64 (matches JS `number`) |
| `Convex.Int64.new(42)` | Int64 | Explicit wrapper for BigInt fields |
| `Convex.Bytes.new(<<1,2,3>>)` | Bytes | |
| `[1.0, "two"]` | Array | |
| `%{"key" => value}` | Object | String keys only |

## Configuration

```elixir
Convex.start_link(
  deployment_url: "https://your-app.convex.cloud",

  # Auth (optional)
  auth_token: "static-jwt",                    # or use auth_fetcher
  auth_fetcher: fn force_refresh: _ -> "jwt" end,

  # Timeouts
  inactivity_check_ms: 5_000,                  # how often to check server liveness
  inactivity_timeout_ms: 30_000,               # max silence before reconnect

  # Backoff
  backoff: [base_ms: 100, max_ms: 15_000],

  # Transport (for testing)
  transport_module: Convex.Transport.WebSocket  # default
)
```

## Architecture

```
Convex.Client (GenServer)          — process orchestration, thin
  ├── Convex.Sync.Core             — pure state machine, no I/O
  │     ├── Convex.Sync.QueryToken — canonical query identity
  │     └── Convex.Sync.RequestManager — request lifecycle tracking
  ├── Convex.Protocol.Codec        — JSON wire format encode/decode
  ├── Convex.Value                 — Convex value type codec
  └── Convex.Transport.WebSocket   — WebSocket connection (behaviour)
```

The core state machine is a pure module — `(state, input) → {state, effects}`. All side effects (WebSocket I/O, process messaging, timers) are handled at the edges by `Convex.Client`.

## Status

Early stage. The sync protocol, value codec, and state machine are implemented and tested against the [convex-rs](https://github.com/get-convex/convex-rs) reference implementation. Not yet published on Hex.

## License

MIT
