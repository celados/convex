# Convex TODO

This file tracks deliberate implementation tradeoffs and follow-up work.

Add an item here when all of the following are true:

- The current implementation is intentional and acceptable for now.
- The choice leaves a known tail: spec drift, dependency risk, missing cleanup, or a planned replacement.
- A future session could easily miss the issue by only reading the code.

Each item should answer:

- What was chosen
- Why it was acceptable at the time
- What risk or limitation remains
- What should trigger revisiting it
- What the next concrete step is

## Hex Publish Readiness

| Item | Status | Notes |
|------|--------|-------|
| `package` metadata in mix.exs | Done | description, licenses, links, files |
| LICENSE file | Done | MIT |
| `@moduledoc` on public types (Int64, Bytes, ConvexError) | Done | |
| `@moduledoc false` on internal modules | Done | Protocol.Optional was missing it |
| Trailing-slash defense in `sync_url/1` | Done | Codex fix |
| Confirm GitHub repo URL in mix.exs | Done | Repository transferred to `celados/convex` |
| Update README installation to hex dep | Blocked | Can't do until first `mix hex.publish` succeeds |
| Hex.pm account + API key | Blocked | Requires manual `mix hex.user register` or `mix hex.user auth` |
| `ex_doc` dependency for hexdocs | Not started | Add `{:ex_doc, "~> 0.35", only: :dev, runtime: false}` when ready |
| Transport crash isolation (monitor vs link) | Not started | Low risk; transport always stops with `:normal` today, but a Mint crash would cascade. See audit notes below |

## Open Items

### [x] Audit Mint transport against spec — completed 2026-03-21

No spec-compliance issues found. Three minor improvements identified and applied (trailing slash, moduledocs, package metadata). One architecture note deferred:

- **Transport process link vs monitor**: The client `start_link`s the transport, so a non-normal transport crash kills the client. Current code always stops with `:normal`, making this theoretical. Fix when robustness matters (e.g., production use under adversarial network conditions).

### [x] Optimistic updates — won't implement

- Decision: backend clients should not expose optimistic updates.
- Rationale: optimistic updates trade correctness for perceived latency. Frontend UIs can tolerate a rollback; backend logic acting on unconfirmed state risks irreversible side effects. The `optimistic_results` field in Core remains an unused placeholder — it may be removed in a future cleanup.

### [x] Sync against official `convex-rs` — completed 2026-08-30

- Audited the Elixir implementation against `get-convex/convex-rs@e4eb7e2` at its March baseline and `a0fd168` at upstream `main`.
- The only client-semantic change was clearing a query's cached result when its last subscriber drops. Elixir already did this; the Core regression test now locks the behavior.

### [x] Complete admin authentication — completed 2026-08-30

- Implemented User, Admin, Admin-acting-as-user, static auth, dynamic fetchers, reconnect replay, and credential redaction as specified in `docs/admin-auth.md`.
- Runtime fetcher replacement deliberately revokes the previous credential before asynchronous fetching. This is an Elixir-side safety improvement over the current upstream runtime replacement path.
