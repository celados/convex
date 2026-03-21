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

## Open Items

### [ ] Audit the current Mint transport against the spec before release

- Current choice: [mix.exs](./mix.exs) uses `mint_web_socket`, and [lib/convex/transport/websocket.ex](./lib/convex/transport/websocket.ex) is implemented directly on Mint.
- Why acceptable at the time: the transport migration is already done, and the current implementation is good enough to support reconnect/auth replay/state notification work while the rest of the client stabilizes.
- Remaining risk: the old TODO outlived the migration, which hid the real follow-up work. What remains now is not "replace websockex", but auditing the Mint transport for any remaining spec drift or lifecycle gaps before release.
- Revisit when: before public release, during dependency upgrades, or the next time transport lifecycle/backpressure/close-handling code is touched.
- Next step: review the current Mint transport behavior against `convex_spec.md`, then add or tighten tests around handshake, close semantics, and reconnect edge cases where needed.

### [ ] Design a public optimistic update API instead of shipping hidden local overlay behavior

- Current choice: only connection state notifications are exposed publicly; `Convex.Sync.Core.optimistic_results` remains an internal placeholder and `mutation/4` keeps server-authoritative semantics.
- Why acceptable at the time: the local spec and `convex-rs` reference both stop short of defining a stable user-facing optimistic update contract, so shipping an API now would be guesswork.
- Remaining risk: the spec still mentions optimistic query results internally, so future contributors could assume user-visible optimistic updates already exist when they do not.
- Revisit when: we agree on the public API shape for optimistic writes, rollback rules, reconnect behavior, and how local overlays compose with `watch_all`.
- Next step: write a concrete spec for optimistic updates first, then implement it as an explicit public API change instead of implicit `mutation/4` behavior.
