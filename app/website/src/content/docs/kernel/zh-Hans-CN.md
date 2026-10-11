---
title: Rust Kernel
description: 由 Elixir 控制面通过 Rustler 加载的原生能力与 AI 传输库。
section: Developer guide
order: 109
---

Rust Kernel 是控制面的原生库，由 Elixir 通过 Rustler 加载。Bun Worker 使用自己生成的 protobuf 编解码器，不加载 Kernel 原生模块。

## 原生能力

`app/kernel` 提供以下能力：

- **`common/`**：加密、密钥派生、密码哈希、编码、UUIDv7 标识符、JWT 工具和电话号码规范化。
- **`authz/`**：基于显式快照的权限求值、CEL 校验和资源模式匹配。控制面提供[Principal 与 AuthZ](../principal-authz/)所述的数据。
- **`universal_ai_client/`**：上游 HTTP SSE/EventStream 与 WebSocket 传输、响应规范化、下游 JSON 文本块编码、需求额度、取消和超时。
- **`object_store/`**：基于本地目录或 S3 兼容桶的文件服务存储。
- **`program_runner/`**、**`brain_markdoc/`** 和 **`model_image/`**：程序化工具执行、Brain 正文分析和模型图像转换。
- **`signals_gateway/`**：基于传入上下文的路由策略求值。

## 所有权

控制面拥有持久状态、权限数据、提供方选择、凭证和领域提交权。Kernel 接收已准备的输入，不查询 PostgreSQL、不调度 Agent，也不拥有 Worker socket。

RuntimeFabric 的结构和协议版本 9 在 `proto/ankole/runtime_fabric/v1/envelope.proto` 中声明。Elixir 使用 Protox，Worker 使用 protobuf-es。两端在发送时写入声明的版本，在接收时检查版本。领域消费者检查执行权限；跨语言 golden fixture 校验编解码一致性。

## 构建与传输

开发、测试和生产共用 Cargo feature `nif`。Rustler 在 `src/nif_exports.rs` 中转换 BEAM 值和错误。JSON 形状的值与二进制数据在边界上保留各自表示。

各环境的共享 reqwest client 都使用 HTTP/1.1 和 aws-lc-rs TLS。上游 WebSocket 使用独立连接。提供方策略和 transcript 提交仍由 [AIGateway](../ai-gateway/)负责。

Worker 生命周期和消息路由见 [Actor Runtime](../actor-runtime/)与 [Agent Computer Worker](../agent-computer-worker/)。
