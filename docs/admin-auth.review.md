---
type: Review
title: Review of complete Convex authentication proposal v0.3
description: Adversarial re-review of User, Admin, and Admin-acting-as-user authentication design.
resource: ./admin-auth.md
verdict: approve
version: 0.3
generated:
  by: codex/gpt-5.6-sol
  at: 2026-08-30T08:18:14Z
---

# 1. Verdict

Approve。v0.3 已把认证完成从“transport 已连接”中独立出来，并为 initial connection、reconnect 与 runtime fetcher replacement 定义了同一条 authorization barrier；Admin-acting-as-user 也已有唯一的 public construction 与 outbound normalization 契约。按当前文本实现并通过 acceptance matrix 后，User、Admin、Admin acting as a user 三种模式都能在不复用旧 credential、不乱序 replay、不泄漏 client-owned secret 的前提下工作。

本轮没有发现新的 blocking finding。B1–B7 在 v0.2 已关闭，相关决定在 v0.3 中保持不变（`docs/admin-auth.md:44-79,108-129,133-230,232-265`）。B8 已由明确的 revoke、readiness phase、dispatch gate、reconnect ordering、非链接受监控 task 与 connection/source revision generation 关闭（`docs/admin-auth.md:68,81-106,257-260`）。B9 已由 `Convex.Auth.Identity.new/1`、issuer/subject 持久化归一化及 outbound 必发 `tokenIdentifier` 关闭（`docs/admin-auth.md:35,133-165,169-212,261`）。

这些修订与指定 Rust snapshot 的关键行为一致：reconnect 先等待 fetcher，并把 `Authenticate` 放在 query replay 前（`/Users/dio/workspace/.scratch/convex-rs/src/base_client/mod.rs:246-294`）；`UserIdentifier::construct/2` 使用 `issuer|subject`（`/Users/dio/workspace/.scratch/convex-rs/sync_types/src/types/mod.rs:262-269`）；JSON input 在缺失 identifier 时执行该归一化，而 outbound 总是写入 identifier（`/Users/dio/workspace/.scratch/convex-rs/sync_types/src/types/json.rs:919-927,966-1003`）。v0.3 对 runtime fetcher replacement 先发 `Authenticate(None)` 是有意且合理的 Elixir 安全偏离：Rust 当前路径在 fetch 失败时不会主动撤销旧 identity（`/Users/dio/workspace/.scratch/convex-rs/src/base_client/mod.rs:598-625`），提案已明确记录这一差异（`docs/admin-auth.md:68`）。

# 2. Blocking findings

无。B1–B9 均已关闭，没有阻塞实现的未决协议、状态机或 public API 决策。

# 3. Non-blocking findings

## N1. Task failure normalization 应发生在受监督 task 内部

提案同时要求“task crash 被归一化”和“callback reason 不进入 logs/crash reports”（`docs/admin-auth.md:97-106,230,236,263`）。实现不能只依靠 caller 收到 `:DOWN` 后再清洗；callback 若先以包含 secret 的 reason 退出，OTP report 可能已经形成。应在 task wrapper 内捕获 raise/throw/exit 并只返回固定的 credential-free failure，成功收到 `{ref, result}` 后 `Process.demonitor(ref, [:flush])`，避免后续正常 `:DOWN` 被误判为第二次失败。

generation invalidation 已足以保证 correctness，但文本只要求忽略 late result（`docs/admin-auth.md:97-104`），没有要求终止失效或永久挂起的 task。实现宜在 source replacement、transport closure 和 reconnect 时取消可取消的旧 task，或明确由 fetcher 自行提供 I/O timeout，避免连续 reconnect 累积孤儿任务。这不改变 wire semantics，因此不阻塞 proposal approval。

## N2. 把 runtime replacement 的 version 与 watcher 行为加入精确断言

两阶段 runtime replacement 已明确先 `None`、后新 token（`docs/admin-auth.md:68,91-93`），但 acceptance item 8 只直接断言撤权与业务阻塞（`:258`）。实现测试宜再固定同一 socket 上的精确序列：旧 identity version 为 `n` 时发送 `None@n`，fetch 成功后发送新 token `@(n+1)`，各递增一次；并断言 public connection-state watcher 只收到一次 `:connecting` 和一次 `:connected`。现有 watcher 已承诺去重（`test/convex/client_test.exs:184-235`），新增 auth phase 不应退化该行为。

## N3. 固定 `Identity.new/1` 的 input-key 与 unknown-field 契约

`Identity.new(keyword_or_map)` 已解决 constructor 缺失，但尚未说明 map 接受 atom keys、string keys，还是两者都接受，也未说明 unknown standard field 是拒绝还是忽略（`docs/admin-auth.md:133-165`）。建议采用一个规范输入形状，并拒绝 unknown fields；静默忽略拼写错误会产生 wire-valid 但 identity 不完整的 admin impersonation。这个细节可以在实现的 `@spec`、module docs 和 constructor tests 中固定，无需重新打开 B9。

## N4. 保持 admin credential 的产品级警示

Rust 把 `set_admin_auth` 标为 hidden API（`/Users/dio/workspace/.scratch/convex-rs/src/client/mod.rs:393-412`）。Elixir 公开独立入口是可接受的产品决定，但 public docs 应继续把 deploy key 标为 deployment-admin 级高权限 credential，并避免示例、Inspect、错误与 doctest 输出真实 key。提案现有 token/message redaction 边界足以支撑这一点（`docs/admin-auth.md:129,216-230`）。

# 4. Evidence checked

- Revised proposal：`docs/admin-auth.md:1-267`，version 0.3，全文复核；B8/B9 的 adjudication 均按实际文字重新验证，没有假定裁决成立。
- Existing public/client behavior：`lib/convex.ex:1-20`；`lib/convex/client.ex:1-716`。当前 dispatcher 只以 `transport_pid` 判断能否发送（`lib/convex/client.ex:503-509`），所以 v0.3 要求的 central authorization gate 是真实且必要的新 seam。
- Existing core/protocol behavior：`lib/convex/sync/core.ex:1-425`，其中 reconnect 目前按 auth、query、request 排序（`lib/convex/sync/core.ex:239-277`）；`lib/convex/protocol/messages.ex:1-116`；`lib/convex/protocol/codec.ex:1-319`。
- Existing tests：`test/convex/client_test.exs:1-581`、`test/convex/sync/core_test.exs:1-96`、`test/convex/protocol/messages_test.exs:1-112`，重点复核 connection watcher、initial auth、reconnect、auth replay 与 current `Authenticate` shape。
- Rust snapshot（题述 `get-convex/convex-rs@a0fd1682678ba77399fdb4b555542d2d45133140`）：`src/client/mod.rs:349-412,686-793`；`src/base_client/mod.rs:237-294,598-625`；`sync_types/src/types/mod.rs:262-355`；以及 wire fidelity 所需的 `sync_types/src/types/json.rs:867-1003`。

未运行测试套件：本轮是 proposal-only review，且没有实现变更。结论来自 v0.3 文本、当前 Elixir seam、现有测试边界与指定 Rust snapshot 的逐项比对。

# 5. Recommended changes

以下均为实现指导，不是修改 proposal 或改变 verdict 的前置条件：

1. 在一个 central dispatch boundary 实现 authorization gate；仅 `Connect` 与 `Authenticate` 可绕过，业务消息保留在 core/outbox 或单一 pending queue 中，避免把 readiness 判断散落到每个 public handler。
2. 用 credential-free task wrapper 统一返回成功或失败，正确处理 result/`:DOWN` 双消息，并在 generation 失效时清理可取消的 task。
3. 在 acceptance matrix 的 runtime replacement case 中加入 `None@n -> token@(n+1)` 与 connection-state watcher 去重断言。
4. 在 `Identity.new/1` 的 `@spec`、docs 与 tests 中固定 map key、unknown field、duplicate keyword 和 nested JSON encodability 的行为。
5. 保留 deterministic tests 作为无 secret 的硬 gate；题述 live deployment test 继续作为 caller-supplied、tagged integration test，而不是默认 gate（`docs/admin-auth.md:267`）。
