---
title: Provider 与模型
description: 如何把模型接进 agent——配置 AI provider，再把 provider 的模型通过具名的 profile 槽绑到 agent 的能力上。
section: User guide
order: 12
---

一个 agent 在背后没有模型之前什么都做不了。接上模型是一项两步的运维工作：先配置控制面将调用的 AI provider，再通过具名的 profile 槽把该 provider 的模型绑到 agent 上。本页对照真实的 Console 路由，走完这两步。

先把决定性的性质说清楚：provider 凭证住在控制面，永远不进 agent 的环境。一个 model profile 把 agent 绑到一个*选择符*上——控制面在调用时把选择符解析到真实的 provider，而 agent 永远看不到凭证。

## 第 1 步：新增一个 AI provider

一个 provider 是控制面将调用的上游——一个 OpenAI 兼容端点、一个 Anthropic 风格 API、一个本地模型服务器，或一个内置的 provider 种类。用以下命令新增或替换：

```bash
curl -X PUT https://ankole.example.com/api/v1/ai-gateway/providers/<provider_id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "provider_kind": "...", "options": { ... } }'
```

`<provider_id>` 是你之后指代这个 provider 的名字。`provider_kind` 选择由哪个 adapter 处理调用；用 `GET /ai-gateway/provider-kinds` 列出本部署支持的种类。`options` 带着端点和加密的选项详情——包括凭证——这些是 provider adapter 所需要的。它们由控制面加密存储；不要放进 agent 的 WorkerEnv。

完整的路由界面——列出、替换、删除 provider——在 [Console API 参考](../console-api/)。

## 第 2 步：把 model profile 绑到 agent 上

agent 不直接调用 provider。它通过具名的 profile 槽调用，每个槽映射到一种能力。支持的槽：

| profile 槽 | 能力 |
|---|---|
| `primary` | agent 用以推理的主 LLM |
| `light` | 用于短促、高频任务的更廉价 LLM |
| `heavy` | 用于硬综合的更强 LLM |
| `coding` | 用于代码密集工作的 LLM |
| `vision_fallback` | 主模型处理不了图像时使用的 LLM |
| `embedding` | embedding 模型 |
| `rerank` | rerank 模型 |
| `web_search` | web 搜索 provider |
| `web_fetch` | web 抓取 provider |
| `image_generate` | 图像生成模型 |

`primary`、`light` 和 `heavy` 是**必需**的——缺这三个的 agent 不可运行。其余可选；agent 用不到某项能力，就让那个槽空着。

把一个 profile 绑到 agent 上：

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/model-profiles/primary \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "selector": "...", "provider_id": "..." }'
```

一个 profile 的值是一个选择符，控制面在调用时按已配置的 provider 解析它。用 `GET /agents/:agent_uid/model-profiles` 列出 agent 当前的 profile，用 `DELETE /agents/:agent_uid/model-profiles/:profile` 移除一个。

## Codex 订阅默认值

跑 Codex 回合的 agent，其 `primary` 槽带着 Codex 订阅字段——`model`、`model_reasoning_effort`（`minimal | low | medium | high | xhigh | max | ultra`）和 `fast_mode`。运维者不设置时，控制面应用文档约定的默认值，让一个新 agent 仍可运行。想要不同行为，就在 `primary` profile 上覆盖它们。

## 调用时如何解析

一个回合跑起来时，Agent Computer 向 AIGateway 请求模型。AIGateway 读取 agent 上它所需能力的 profile，按 provider 绑定解析选择符，并路由这次调用。有两类解析失败值得知道，因为不改配置直接重试没有用：

- `422 unknown_model_selector`——该选择符没有为这个 agent 绑定。检查 profile 是否指向你确实配置过的 provider id。
- `422 model_binding_not_configured`——能力和名称已绑，但 provider 绑定不完整。检查 provider 行的 options。

两者都是配置问题，不是临时故障。路由、错误信封和 OpenResponses 请求形态的更深处机制，在 [AIGateway](../ai-gateway/) 开发者页。

## 一个完整示例

假设你想要一个 agent：用强模型推理，短回复时回退到更廉价的模型，并能做 embedding 和 web 搜索：

1. 为 LLM 配置一个 provider（`PUT /ai-gateway/providers/acme-llm`），为 embedding 配置一个（`PUT /ai-gateway/providers/acme-embed`），为 web 搜索配置一个（`PUT /ai-gateway/providers/acme-web`）。把每个 provider 的凭证放进各自的 `options`。
2. 把 agent 的 `primary`、`light`、`heavy` 绑到 `acme-llm` 上的选择符。这三个是必需的。
3. 把 `embedding` 绑到 `acme-embed` 上的一个选择符，把 `web_search` 绑到 `acme-web` 上的一个。
4. 通过一个 signal binding 发一条真实消息，观察这次回合用上了解析后的模型。

## 回合失败时怎么办

一次回合以 upstream 错误失败时，profile 绑定通常不是第一个要查的。从模型向外查：先确认 provider 的 options 仍然有效（凭证会轮换），再确认 profile 上的选择符匹配 provider 实际提供的模型，然后才去看 agent 的其余配置。Console 的 `/ai-gateway/conversations` 路由显示一次近期回合做过的模型调用，这是看哪个 profile 解析到了哪个 provider 的最快途径。

## 下一步

- provider 和 model-profile 的路由表，读 [Console API 参考](../console-api/)。
- 解析与路由的内部机制，读 [AIGateway](../ai-gateway/) 开发者页。
- 这些 profile 所附着的 agent，读 [Agent](../agents/)。
