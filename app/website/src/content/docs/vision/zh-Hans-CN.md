---
title: 视觉
description: vision_fallback profile 槽如何工作——agent 何时回退到视觉能力模型、运维者绑定什么使其可用。
section: User guide
order: 42
---

某些回合携带图像——截图、照片、agent 需要读取的图表。当主模型无法处理图像时，AIGateway 回退到 `vision_fallback` profile 槽上绑定的模型。本页是该回退的运维者视角。

先把决定性的性质说清楚：`vision_fallback` 是**回退，不是默认图像路径**。若主模型原生处理图像，它直接处理；`vision_fallback` 仅在主模型不能时被触及。从不看图像的 agent 不需要绑这个槽——留空省钱。

## profile 槽

`vision_fallback` 是十个 model profile 槽之一，可选。只有 `primary`、`light`、`heavy` 必需。该槽绑到能处理图像的模型——通常来自同一 provider 家族的多模态 LLM 或专用视觉模型。

如何绑定槽见 [Provider 与模型](../providers-and-models/)。

## 回退何时触发

回退是自动的。当回合携带图像、且主模型的响应表明它无法处理时，AIGateway 把请求中含图像的部分路由到 `vision_fallback` 模型。agent 不决定回退；网关检测主模型的局限并路由。agent 看到视觉模型的输出，和看到主模型的输出一样——回退对 agent 的循环是透明的。

## 绑定什么

- **把 `vision_fallback` 绑到有视觉能力的模型**——当 agent 处理图像（读截图的客户支持 agent、处理图表的研究 agent、检查 UI 渲染的 QA agent）。
- **留空**——当 agent 从不看图像。这个槽存在不花钱，直到一个含图像的回合试图回退到它、发现没有模型绑定——那时图像被丢弃、agent 不带它继续。
- **尽可能选与 `primary` 同一 provider 家族的模型。** 讲同一 API 的视觉模型降低主回合与回退间格式不匹配的风险。

## 成本意识

视觉模型通常比纯文本模型每 token 更贵。回退只在含图像的回合触发，所以成本与 agent 看到图像的频率成正比。偶尔收到截图的 agent 只在那些回合付回退费；持续处理图像的 agent 应考虑把 `primary` 自身绑到有视觉能力的模型，这样根本没有回退开销。

成本杠杆见[成本管理](../cost-management/)。

## 本指南不是什么

它不是计算机视觉教程——模型读图像的能力是 provider 的事，不是 Ankole 的。它不是工具参考——没有 `vision` 工具；回退是 AIGateway 的路由决定，不是 function call。它也不是 provider 视觉模型文档的替代；模型名和其图像能力由 provider 文档。

## 下一步

- profile 槽及如何绑定，读 [Provider 与模型](../providers-and-models/)。
- 做回退的 AIGateway 路由，读 [AIGateway](../ai-gateway/)。
- 成本意识，读[成本管理](../cost-management/)。
