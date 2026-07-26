---
title: 图像生成
description: 图像生成如何工作——image_generate profile 槽、验证端点的 ImageModelCatalog、为什么它是 AIGateway 内部能力而非 agent 调用的工具。
section: User guide
order: 39
---

图像生成是 AIGateway 的一项能力，从模型 prompt 产出图像。它不是 agent 直接调用的工具——它由 hosted-tool 准备路径组合进 Responses 请求，`image_generate` model profile 槽控制哪个 provider 服务它。本页是该能力的运维者视角。

先把决定性的性质说清楚：图像生成**是 AIGateway 内部的**。它不作为 worker 工具暴露。agent 不像调用 `web_search` 或 `command` 那样调用 `image_generate`；相反，当 hosted-tool 路径需要时，图像请求被组合进 Responses 请求，AIGateway 通过绑定的 provider 解析它。

## profile 槽

`image_generate` 槽是十个 model profile 槽之一，且是可选的。只有 `primary`、`light`、`heavy` 必需；`image_generate` 仅在 agent 需要生成图像时绑定。若部署中没有 agent 生成图像，留空即可——这个槽存在就是使用该能力的许可。

如何通过 Console 绑定槽见 [Provider 与模型](../providers-and-models/)。

## ImageModelCatalog

`ImageModelCatalog` 是图像模型端点及其能力的权威目录。它刻意与语言模型元数据分开，因为图像请求有自己的字段——quality、background 以及文本模型不使用的其他参数。目录在发送请求前验证 provider 端点能满足每个请求字段；当没有端点能满足字段时，图像请求被拒绝，而不是等模型返回错误。

目录有一小时缓存，端点元数据足够新以服务请求而不必每次调用都重新获取，又不至于太旧让 provider 变更的能力长时间不被发现。

## 运维者做什么

- **绑定 `image_generate` profile** 到提供图像生成的 provider。槽未绑，hosted-tool 准备路径无法组合图像请求。
- **不要期望 agent 工具集里有名为 `image_generate` 的工具。** 能力是内部的；模型通过 Responses 组合触发它，不通过 function call。
- **留意成本。** 图像生成按张计价；一个每回合生成多张图像的 agent 花得快。`image_generate` 槽未绑是最便宜的状态。

## 本指南不是什么

它不是图像生成的 prompt 工程指南——Responses 组合内的模型行为是人设的事。它不是工具参考——没有 `image_generate` 工具可文档。它也不是 provider 图像模型文档的替代；目录验证能力，但 provider 命名模型和字段。

## 下一步

- profile 槽及如何绑定，读 [Provider 与模型](../providers-and-models/)。
- 服务图像生成的 AIGateway 边界，读 [AIGateway](../ai-gateway/)。
- 成本意识，读[成本管理](../cost-management/)。
