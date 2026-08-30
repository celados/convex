---
type: Proposal
title: Admin authentication
description: Design complete User, Admin, and Admin-acting-as-user authentication for the Elixir client.
status: draft
version: 0.3
generated:
  by: codex/gpt-5
  at: 2026-08-30T08:17:00Z
resource: https://github.com/get-convex/convex-rs/tree/a0fd1682678ba77399fdb4b555542d2d45133140
review: ./admin-auth.review.md
---

# Admin authentication

## Decision

Model authentication as one opaque token and one auth source. The token describes what credential to send; the source describes whether that token is static or produced on each connection. This separation is required because identity version belongs to a socket connection, while desired authentication outlives reconnects.

The public API keeps the ordinary user path concise and gives admin authentication its own explicit entry point:

```elixir
Convex.set_auth(client, jwt)
Convex.set_auth(client, nil)

Convex.set_admin_auth(client, deploy_key)
Convex.set_admin_auth(client, deploy_key, identity)

Convex.set_auth_fetcher(client, nil)
Convex.set_auth_fetcher(client, fn force_refresh: force_refresh ->
  if force_refresh, do: {:ok, Auth.admin(key, identity)}, else: {:ok, Auth.user(jwt)}
end)
```

`identity` is created with `Convex.Auth.Identity.new/1`; direct `%Convex.Auth.Identity{}` construction is not public API.

Start options use the same model:

```elixir
Convex.start_link(deployment_url: url, auth: Auth.user(jwt))
Convex.start_link(deployment_url: url, auth_fetcher: fetcher)
```

`auth` and `auth_fetcher` are mutually exclusive. Supplying both is invalid at `start_link/1`. The existing unpublished `auth_token` option is removed rather than kept as a compatibility alias. Option shape and conflicts are validated before `GenServer.start_link/2` and raise `ArgumentError` in the caller process.

## Auth source and connection state

The client owns exactly one source:

| Source | Representation | Meaning |
| --- | --- | --- |
| Anonymous | `Auth.none()` | No credential is selected. |
| Static token | `Auth.user/1`, `Auth.admin/1`, or `Auth.admin/2` token | The same credential is used on every connection. |
| Dynamic fetcher | callback | A new token is fetched for the initial use and every reconnect. |

A fetcher returns:

```elixir
{:ok, Convex.Auth.Token.t()} | {:error, term()}
```

There is no separate `:none` sentinel: anonymous is `{:ok, Auth.none()}`.

All static setters and `set_auth_fetcher(nil)` atomically replace the current source. In particular, `set_auth(client, nil)` clears an old fetcher and cannot allow that fetcher to restore a previous identity on reconnect. Installing a fetcher also replaces a static token.

While the protocol is connected, a source change immediately authenticates with the new token. Before the first protocol connection, it only changes desired state and must not increment the connection's identity version. If an old fetch is still in flight, its result is discarded by connection-generation tag rather than applied to the newer source.

Replacing a connected static credential with a fetcher has two phases. The client first sends `Authenticate` with `Auth.none()` at the current identity version, incrementing that version and revoking the old credential. It then starts the fetch with `force_refresh: false`; no business message is dispatched until that fetch resolves. This immediate logout is a deliberate safety divergence from upstream's runtime fetcher installation path: a fetch failure must never leave requests running under the previous user or admin credential.

### Connection lifecycle

| Event | User/Admin token | `Auth.none()` |
| --- | --- | --- |
| Initial connection | Send `Authenticate(baseVersion: 0)` and set local identity version to 1. | Send no `Authenticate`; identity version remains 0. |
| Reconnect | Reset identity version to 0, then send the refreshed or static token at base version 0 and set version to 1. | Reset version to 0 and send no `Authenticate`. |
| Setter while connected | Send the token at the current identity version and increment once. | Send `Authenticate` with `tokenType: "None"` at the current version and increment once. |
| Setter before first connection | Store desired source only. | Store desired source only. |

This yields the same connected-session sequence as upstream for `User@0 -> None@1 -> Admin@2 -> Admin-acting-as-user@3`.

### Authorization barrier

Transport being open is not protocol readiness. A connection has a separate auth-resolution phase after `Connect` and before any query, mutation, action, or subscription modification is dispatched:

1. open the transport and send `Connect`;
2. resolve the current-generation static token or fetcher result;
3. emit `Authenticate` for User/Admin, or make the explicit anonymous decision for `Auth.none()` or fetch failure;
4. replay outstanding queries and requests;
5. allow new business messages.

The public connection state remains `:connecting` during auth resolution and becomes `:connected` only after the authorization decision. New API calls may enter the GenServer and update local request bookkeeping while auth is unresolved, but their outgoing messages remain behind the dispatch gate. `Connect` and `Authenticate` are the only messages allowed through before resolution completes.

On reconnect, `Authenticate` always precedes query/request replay. On runtime fetcher replacement, `Authenticate(None)` precedes the fetch, and no business message can use the revoked credential while the fetch is pending.

### Fetcher execution

The fetcher may perform I/O. It never runs in the `Convex.Client` GenServer process. Each connection attempt starts a monitored, non-linked task through a task supervisor. The task carries a generation derived from both connection and auth-source revisions. Reconnection, transport closure, or source replacement invalidates older generations; late results are ignored and cannot overwrite newer desired state.

The initial or runtime installation calls the fetcher with `force_refresh: false`. Each reconnect calls it with `force_refresh: true`. A fetch result is accepted only when all of these hold:

- its generation is still current;
- its source is still the same fetcher;
- it returns `{:ok, Auth.Token.t()}`;
- the token passes internal invariant validation.

Expected `{:error, reason}` returns, task crashes, and invalid fetch results are normalized to an auth-fetch failure. The client retains the fetcher, does not reuse an older credential, and continues that connection anonymously, matching upstream reconnect behavior. It logs a fixed credential-free diagnostic and tries the fetcher again on the next reconnect. Raw error reasons are not placed in logs or crash reports because an arbitrary callback reason can contain a credential.

## Token model

`Convex.Auth.Token` is opaque outside its constructor module:

```elixir
Auth.user(jwt)
Auth.admin(deploy_key)
Auth.admin(deploy_key, identity)
Auth.none()
```

Internally it has `type`, `credential`, and `acting_as`, but direct construction is not public API. Constructors validate in the calling process and raise `ArgumentError` for invalid public input before a GenServer call or socket write. The internal serializer additionally returns `{:error, reason}` for an invalid directly-built struct; it does not raise and does not crash the client.

Valid combinations are:

| Type | Credential | Acting as |
| --- | --- | --- |
| `:user` | Required binary. | Always nil. |
| `:admin` | Required binary. | Optional identity. |
| `:none` | Always nil. | Always nil. |

Credentials are high-secret values. `Auth.Token` has a custom Inspect representation that replaces `credential` with `<redacted>`; `acting_as` remains visible because it is protocol identity metadata.

## Acting-as identity

`Convex.Auth.Identity.new(keyword_or_map)` mirrors upstream `UserIdentityAttributes` at the wire boundary, while using JSON-native Elixir values for custom claims. It validates standard fields, custom claims, and reserved-key collisions in the calling process and raises `ArgumentError` on invalid input.

An identity must provide either:

- non-empty `token_identifier`; or
- both non-empty `issuer` and `subject`.

If `token_identifier` is present, it takes precedence, matching upstream. Requiring non-empty strings is a deliberate Elixir validation choice; upstream accepts an empty transparent string. The optional standard fields are:

- `issuer`
- `subject`
- `name`
- `given_name`
- `family_name`
- `nickname`
- `preferred_username`
- `profile_url`
- `picture_url`
- `website_url`
- `email`
- `email_verified`
- `gender`
- `birthday`
- `timezone`
- `language`
- `phone_number`
- `phone_number_verified`
- `address`
- `updated_at`

String fields must be binaries; verification fields must be booleans. `updated_at` remains an opaque RFC3339 string rather than a DateTime because upstream does not parse it during client serialization.

When `token_identifier` is absent, `Identity.new/1` requires both `issuer` and `subject`, normalizes the identifier to `issuer <> "|" <> subject`, and stores that value. Outbound serialization always emits the normalized `tokenIdentifier`, even when the identity was constructed from issuer and subject; the original optional `issuer` and `subject` fields remain subject to the normal nil-omission rule.

### Custom claims

`custom_claims` is a map with non-empty binary keys and JSON-encodable values. It does **not** serialize as a `customClaims` object. It is flattened into the top level of `actingAs`, matching the official JSON adapter:

```elixir
Identity.new(
  token_identifier: "convex|user",
  custom_claims: %{"isAdmin" => true, "roles" => ["admin"]}
)
```

wire shape:

```json
{
  "tokenIdentifier": "convex|user",
  "isAdmin": true,
  "roles": ["admin"]
}
```

The following reserved keys cannot be used as custom claim keys:

- `tokenIdentifier`
- `issuer`
- `subject`
- `name`
- `givenName`
- `familyName`
- `nickname`
- `preferredUsername`
- `profileUrl`
- `pictureUrl`
- `websiteUrl`
- `email`
- `emailVerified`
- `gender`
- `birthday`
- `timezone`
- `language`
- `phoneNumber`
- `phoneNumberVerified`
- `address`
- `updatedAt`

A collision is rejected before network I/O. Optional standard fields are omitted only when nil; empty strings and empty lists are intentionally preserved. `custom_claims` defaults to an empty map and adds no wire field when empty.

## Protocol messages

The internal `Authenticate` message carries the opaque token rather than duplicating `token_type`, `value`, and `acting_as` fields:

```elixir
%Authenticate{base_version: 0, token: Auth.admin(key, identity)}
```

Serialization produces:

- `User`: `tokenType: "User"` and `value`.
- `Admin`: `tokenType: "Admin"`, `value`, and optional `actingAs`.
- `None`: only `tokenType: "None"`.

Because the message owns an `Auth.Token`, its default Inspect remains credential-free. Core outboxes and client state therefore do not expose the credential through nested inspection. Codec errors continue to use the existing `{:ok, term()} | {:error, reason}` contract.

Protocol JSON and explicit transport captures necessarily contain the credential and are outside the redaction guarantee. Client-owned token/message/state structs, default logs, returned errors, and crash reports must not.

## Error and return boundaries

Public constructors and public setter arguments validate in the caller process and may raise `ArgumentError`. Valid setters return `:ok`; transport or serialization failures remain internal reconnect conditions rather than leaking credential-bearing error text.

Fetcher results are a runtime boundary, not public constructor arguments. Invalid fetcher results and task crashes must not kill `Convex.Client` or mutate desired auth. They become the anonymous-until-next-reconnect behavior described above.

`Convex.Auth.Token.t()` is opaque and `Convex.Auth.Identity.t()` exposes only its validated constructor surface. Directly constructing either remains unsupported; serialization defenses exist to keep malformed internal values from reaching the socket, not as a second public API.

## Non-goals

- No OAuth flow, JWT parsing, expiry parsing, or refresh scheduler.
- No admin-only function routing; Convex authorizes each function from the active identity.
- No compatibility alias for the unpublished `auth_token` option.
- No promise to redact explicit wire payloads, test transport captures, or caller-created identity metadata.

## Acceptance tests

The implementation is complete only when all of these pass:

1. Golden JSON tests for `User`, `None`, `Admin`, and `Admin` plus `actingAs`.
2. Identity tests proving custom claims flatten to `actingAs` top level, JSON scalar/list/object values work, empty strings are preserved, nil optional fields are omitted, reserved-key collisions are rejected, and issuer/subject can substitute for `tokenIdentifier`.
3. Core state tests for connected updates `User@0 -> None@1 -> Admin@2 -> Admin-acting-as-user@3`.
4. Fresh-connection and reconnect tests proving `Auth.none()` sends no `Authenticate` and leaves identity version at zero.
5. A regression test that calls a static setter before the first protocol connection and observes exactly one `Authenticate(baseVersion: 0)` on that connection.
6. Source-replacement tests proving user/admin/logout setters replace an old fetcher and old identities cannot return on reconnect.
7. Deferred-fetch ordering tests proving no business message leaves while initial or reconnect auth is unresolved, followed by exact `Connect -> Authenticate -> replay` order for User/Admin and `Connect -> replay` order for anonymous/failure.
8. Runtime replacement tests proving an old credential is revoked before a new fetcher waits, and a fetch failure cannot dispatch business messages under the old credential.
9. Fetcher call-sequence tests proving `force_refresh` is `false, true, true...`; failure, crash, and invalid results do not kill the client or reuse an old credential.
10. Stale-generation tests where an older fetch completes after reconnect or source replacement and is discarded.
11. Identity construction and golden-wire tests proving issuer/subject is normalized to a persisted `tokenIdentifier`, and that field is always emitted on outbound admin impersonation.
12. Invalid public input tests in the caller process: no client crash, no desired-state mutation, and no socket message.
13. Secret-canary tests over token, `Authenticate`, core outbox, client state, logs, returned errors, and crash reports; explicit wire payload capture is the allowed positive control.
14. Reconnect replay tests proving no old base-version `Authenticate` remains after partial sends or consecutive reconnects.
15. The existing `MIX_ENV=test mix check` gate remains green.

A live-deployment admin test is not an implementation gate. A future tagged integration test should assert the server-observed identity and custom claims, using a caller-supplied deploy key and no credential fixture in the repository.
