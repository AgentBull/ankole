---
title: Rust Kernel
description: 由 Elixir 控制面通过 Rustler 加载的 Rust 原生能力库与 AI 传输层。
section: Developer guide
order: 109
---

Rust Kernel 是控制面的底层原生库，由 Elixir 通过 Rustler 加载调用；Bun Worker 则使用独立生成的 Protobuf 编解码器处理协议消息。

## 原生能力

`app/kernel/src` 提供以下底层能力：

- **`common/`**：提供 AEAD 加密、密钥派生、编码转换、哈希计算、UUIDv7 标识符生成、JWT 工具、电话号码规范化、倒数秩融合（RRF）、Token 估算以及 URL/IP SSRF 校验。
- **`authz/`**：基于控制面传入的显式快照执行权限求值、CEL 表达式校验与条件求值，以及资源模式匹配；相关权限数据由控制面按 [Principal 与 AuthZ](../principal-authz/) 所述模型提供。
- **`universal_ai_client/`**：负责上游 HTTP SSE/EventStream 与 WebSocket 传输、响应格式归一化、下游 JSON 文本分块编码，以及需求额度（demand）、取消和超时控制。
- **`object_store/`**：基于本地目录或 S3 兼容存储桶提供底层文件存取支持。
- **`page_document/`**：负责 Pod 页面的 XML 树校验、Wordgard 变更集应用及 UTF-16 差异计算。
- **`brain_markdoc/`** 与 **`markdown.rs`**：负责 Brain 正文分析与 Markdown 语法解析。
- **`model_image.rs`**：提供模型图像的解码、缩放与格式转换。
- **`web_proxy.rs`**：面向 Worker Chromium 会话提供本地回环 SOCKS5 `CONNECT` 代理，并对解析后的目标地址执行 SSRF 校验。
- **`signals/`**：根据传入的上下文对信号路由策略求值。

## 所有权

持久状态、权限数据、提供商选择、访问凭证以及领域事务的提交权均归控制面所有。Kernel 只接收控制面准备好的输入执行计算或传输，既不查询 PostgreSQL、不调度 Agent，也不持有 Worker Socket。此外，程序化工具调用（PTC）与 Pod Applet 后端函数的隔离 TypeScript 代码运行在无状态的 `ankole-function-runtime` 服务中，不在 Rust Kernel 内执行。

RuntimeFabric 的消息结构与协议版本 10 在 `app/kernel/proto/ankole/runtime_fabric/v1/envelope.proto` 中声明；Elixir 侧使用 Protox 编解码，Worker 侧使用 protobuf-es。通信双方在发送时写入声明的版本号，并在接收时校验版本；执行权限由各领域消费者负责检查，跨语言编解码一致性则由 Golden Fixture 测试保障。

## 构建与传输

编译时通过 Cargo Feature 区分目标宿主：`nif` 经由 `src/nif_exports.rs` 服务 Elixir 控制面，由 Rustler 在该模块内转换 BEAM 值与错误，同时在跨语言边界上各自保留 JSON 结构值与二进制数据的原始表示；`napi` 则经由 `src/napi_exports.rs` 服务 Worker 浏览器守护进程与宿主侧测试。

各运行环境的共享 `reqwest` 客户端统一采用 HTTP/1.1 与 `aws-lc-rs` TLS 实现，上游 WebSocket 则使用独立连接。提供商路由策略与对话记录（Transcript）提交仍由 [AIGateway](../ai-gateway/) 负责。

关于 Worker 生命周期与消息路由机制，请参阅 [Sessions](../sessions/) 与 [Agent Computer Worker](../agent-computer-worker/)。
