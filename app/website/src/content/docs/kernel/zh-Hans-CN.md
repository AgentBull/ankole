---
title: Rust Kernel
description: 共享的原生层——对授权、RuntimeFabric 传输和 AI 数据面原语的一份 Rust 实现，同时被 Elixir 控制面和 Bun worker 加载。
section: Concepts
order: 15
---

Ankole 跑在两个宿主运行时上——一个 Elixir 控制面和一个 Bun worker——有几样行为必须在两边意味着同一件事。Rust Kernel 就是这些共享原生语义的所在。本页对照 `app/kernel` 里的真实代码，画出这个 kernel。

先把决定性的性质说清楚：kernel 是一个 Rust crate，通过两层绑定被两个宿主加载，不是一个带 Elixir 适配的 Bun 包，也不是一个带 Bun 适配的 Elixir NIF。Rust 拥有底层语义；绑定只翻译宿主的类型、命名和错误。如果一样行为必须被两个运行时同时信任，它就先以 Rust 的形态住在这里，绑定在后。

## 两个宿主，一份实现

这个 crate 在互斥的 feature flag 下编译——`napi` 对 Bun 的 N-API，`nif_dev`/`nif_prod` 对 Elixir 的 Rustler——于是同一份源码编出两个原生 addon。一个全局 mimalloc 分配器被显式设定，因为一个被长时宿主运行时加载的原生 addon，必须在 N-API 和 NIF 构建之间保持分配器行为一致。

绑定面与此对应。Elixir 这边，`Ankole.Kernel` 是一个 Rustler 模块，在原生 crate 加载之前，它的函数都回落到 `:erlang.nif_error(:nif_not_loaded)`——`aead_encrypt`、`authz_authorize`、`runtime_fabric_router_start`、`universal_ai_client_open_nif`、`gen_uuid_v7`。Bun 这边，同一个 crate 以 N-API addon 发出。名字不同；行为一致。

## 为什么要有共享 kernel

kernel 的存在，是为了阻止 Bun 这边和 Elixir 这边对同一种原生行为发展出各自的含义。没有它，授权求值、fabric 组帧和 AI 流式会在两份实现之间 drifting，这一边做出的决定，可能会和那一边做出的决定相左。把受信任的行为用 Rust 写一次、绑定在后，正是让两个运行时彼此诚实的那件事。

## 共享面

四个模块承载共享语义：

- **`common/`**——宿主中立的原语：AEAD token 加密与解密、密钥派生、哈希、编码、UUID 帮助函数（含 `gen_uuid_v7`，对 Elixir 暴露为 `gen_uuid_v7/0`，对 Bun 暴露为 `genUUIDv7()`）、JWT 帮助函数、电话号码归一化。这些是两个运行时都会伸手去拿的小型受信任操作。
- **`authz/`**——只基于快照的授权求值。`authorize` 和 `authorize_all` 接受一个 `AuthzSnapshot`，返回一个 `AuthzDecision`；CEL condition 校验和 resource pattern 匹配也在这里。这就是 [Principal 与 AuthZ](../principal-authz/) 页里描述的、控制面为之装配快照的那个确定性求值器。
- **`runtime_fabric/`**——RuntimeFabric v1 信封协议：lane、持久性等级、关联规则，以及回合/控制/进度/RPC 体语义，全部在宿主编码的 protobuf 字节之上校验。唯一的结构声明是 `proto/envelope.proto`；每个宿主从它派生自己的编解码——Rust 用 `prost-build`，Elixir 用 `protox`，TypeScript 用 `protoc-gen-es`。没有哪个宿主自己发明结构。
- **`universal_ai_client/`**——一个 feature 门控的原生异步流式客户端，用于已准备好的 AI provider 请求：上游的 HTTP SSE/EventStream 和 WebSocket 传输、provider 响应归一化、下游的 SSE/WebSocket 分块编码、需求信用、取消。这就是 [AIGateway](../ai-gateway/) 用来与 provider 通信的 AI 数据面原语。

## ZeroMQ 传输

在 `runtime_fabric/transport/` 里，kernel 拥有 ZeroMQ ROUTER/DEALER 传输，按 auth、config、router、dealer 和 framing 模块拆分。控制面到 worker 的实时 fabric 真正跑在这里：

- **ZAP/PLAIN worker 鉴权**——一个 worker 用它的认证 key 鉴权之后，fabric 才接受它的流量。
- **强制路由发送**——一条无法被路由的发送会显式失败，而不是悄悄丢弃。
- **有界 socket 选项**——socket 的配置阻止无界队列及其带来的失败模式。
- **原始 `ANKOLE_FILE/1` worker 文件多部帧**——控制面与 worker 之间的文件传输骑在同一条传输上，作为区别于 RPC lane 的原始多部帧。

传输由 Rust 拥有，这是刻意的。这是唯一一个地方——丢一帧或错路由一次发送，就意味着一条 worker 回复落到错误的 session 上，所以受信任的行为住在这里，两个宿主都来调用它。

## 边界

kernel 与两个运行时的边界是清晰的，每一条都是共享语义规则的推论：

- **与 Actor Runtime。** 控制面拥有 actor 状态、activation 隔离栏和持久转写。kernel 拥有确定性的授权求值，以及承载回合、进度和 RPC 信封的传输。Actor Runtime 把一条 worker 回复拿去和隔离栏核对时，授权该 principal 的决定逻辑是 kernel 代码；隔离栏行本身则是控制面状态。
- **与 Agent Computer。** worker 拥有实时执行。kernel 拥有 worker 回合用来触及 provider 的 AI 流式客户端，以及承载 worker 进度帧和文件帧回来的传输。worker 不重新实现流式或组帧；它调用的是同一个原生面——和 Control Plane 在对称方向上会调用的那个一样。
- **与 AIGateway。** 网关拥有 provider 路由和凭证。kernel 拥有线上字节：HTTP 和 WebSocket 传输、响应归一化、调用方最终收到的分块编码。

## kernel 不是什么

它不是宿主特定行为的归宿。任何一个运行时单独需要的东西——一个 Phoenix plug、一个 Bun 工具、一条 console 路由——都留在那个运行时里；kernel 只取两者都必须信任的那部分。它不是 actor 状态或 provider 凭证的第二权威；那些归控制面。它也不是宿主可以替换的可选管线。整件事的意义在于：两个运行时对那些跨越彼此边界的行为共享同一个含义，而这个含义是 Rust。

## 下一步

- kernel 所跑的授权求值，读 [Principal 与 AuthZ](../principal-authz/)。
- kernel 承载信封所用的传输，读 [Actor Runtime](../actor-runtime/) 和 [Agent Computer](../agent-computer/)。
- kernel 所提供的 AI 流式，读 [AIGateway API](../ai-gateway/)。
