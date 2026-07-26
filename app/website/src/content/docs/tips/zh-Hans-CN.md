---
title: 运维技巧
description: 运行 Ankole 时省时间的短小、经过验证的动作——读日志、限定 agent 范围、轮换 secret、从卡住的回合恢复、把 model profile 槽当拨盘用。
section: Guides
order: 308
---

这是一个动作杂烩，每一条都塞不进某一篇指南，但又常出现。每条都短、都扎根于 Ankole 的真实工作方式，且都比第一次踩坑时便宜。

## 本地用 pretty 模式读日志

控制面默认输出结构化 JSON 日志——适合摄入，难读。本地开发时，通过 devkit 的 pretty 打印器管道：

```bash
bun run dev   # 一个终端
bun run kit logs pretty < /path/to/log-stream   # 或把日志文件管道给它
```

生产里，保持 `ANKOLE_LOG_FORMAT=json`，让日志摄入器处理格式。pretty 打印器是本地便利，不是生产设置。

## 找 bug 前先收窄日志级别

`ANKOLE_LOG_LEVEL` 默认 `info`。为某次复现降到 `debug`，处理完调回去——留在 `debug` 的部署又吵又慢。合法值 `debug | info | warning | error`；非法值在启动时拒绝，不悄悄忽略。

## 不开终端也能拿到激活码

若 `bun dev`（或控制面容器）终端看不见、而设置页面要 code：

```bash
bun run kit show bootstrap-activation-code          # 本地
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"   # Compose
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane | grep "SETUP ACTIVATION CODE"   # Helm
```

不要从数据库猜 code——从设置流程实际使用的来源读。

## 把 model profile 槽当拨盘

十个 profile 槽不只是"主模型加它的朋友"。每一个都是拨盘：

- agent 主要答快问时，把 **`primary`** 调到更便宜的模型；质量比成本更要紧时调上去。
- 把 **`light`** 绑到真正廉价、快速的模型——它为高频低风险的路径而存在。
- 只在 agent 看图像时设 **`vision_fallback`**；否则留空，省下这个槽。
- **`web_search`** 和 **`web_fetch`** 相互独立——只在 agent 需要联网时绑它们。

一个"感觉慢"的 agent，常常是 `primary` 绑得太重，相对于它实际做的工作。

## 轮换环境变量中的凭据

Worker 环境改动在**下一个回合**生效，不在当前正在跑的回合上。所以：

1. 在 Console 的“环境变量”中输入新值并保存。
2. 让任何进行中的回合跑完——它已经有它的环境。
3. 发一条新消息，验证新值生效。

不要从你保存时正在跑的回合判断 secret 改动；它看不到新值。

## 只在必要时查看加密值

优先直接输入新值完成轮换，不要为了确认而查看旧值。只有在排查问题且确实需要核对现有内容时，才选择“查看”。

## 从卡住的回合恢复

一个看起来卡住的回合，通常在等模型或 provider，不在等 Ankole。在取消任何东西之前：

1. 查 `/ai-gateway/conversations` 该回合的近期模型调用——若有长间隔，provider 是瓶颈。
2. 查 worker 日志看是否有进行中的工具调用——慢工具看起来像卡住的回合。
3. 仅当回合确实楔住，agent 的 session 可被引导，或让回合超时；后台任务的取消是 `POST /background-agent-jobs/:id/cancel`，它让进行中的回合跑完。

激进取消是运维者制造半截副作用的方式。

## 安静地禁用 binding

`DELETE /agents/:agent_uid/signal-bindings/:binding_name` 是*禁用*，不是硬删除——配置可恢复。想在一个频道里让 agent 静音而不丢设置（凭证撤销、假日、事故）时用它。用 `PATCH` 重新启用。

## 每次升级前都备份

Helm 回滚不会反向执行数据库 migration。升级前那两分钟的 `pg_dump`，是“回滚了”和“从备份还原、丢了一天”之间的差别。备份与还原命令见[备份与还原](../backup-and-restore/)。

## 从正确的长期文档调整 Agent

Agent 的职责不清时改 `MISSION.md`；沟通方式或判断习惯不合适时改 `SOUL.md`；网页、幻灯片、文档或图表的视觉风格不统一时改 `DESIGN.md`。三个文件各管一件事，不要把行为要求塞进视觉设计系统。

## 钉钉每个 agent 一个机器人

钉钉强制一条硬约束：每个 agent 一个启用 binding，每个 `clientId` 一个 agent。要扩展，从一开始就按一个 agent 一个机器人规划——同一 agent 上第二个 binding 以 `dingtalk_binding_already_exists` 失败，在第二个 agent 上复用 `clientId` 以 `dingtalk_app_already_bound` 失败。配置方法见 [Quickstart](../quickstart/#4-连接聊天渠道并创建信号路由规则)。

## Teams 总是需要公共端点

Teams 把消息作为 Bot Framework webhook 调用投递，不走长连接。Teams 机器人停止工作时，第一件要查的是公共 HTTPS 端点——证书过期、DNS 变更、入口停机，看起来都像"机器人不回复了"。Lark、Slack、钉钉用长连接，能熬过短暂的端点抖动；Teams 不能。

## 下一步

- Console 的接口参考，读 [Console API 参考](../console-api/)。
- 环境旋钮，读[环境变量](../environment-variables/)。
- kit 命令，读 [kit CLI 参考](../kit-cli/)。
