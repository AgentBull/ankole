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

## 轮换 WorkerEnv secret 而不弄断回合

Worker 环境改动在**下一个回合**生效，不在当前正在跑的回合上。所以：

1. 用 `PUT /worker-envs/:name`（或按 agent 形态）放新值。
2. 让任何进行中的回合跑完——它已经有它的环境。
3. 发一条新消息，验证新值生效。

不要从你保存时正在跑的回合判断 secret 改动；它看不到新值。

## 解密是单独权限——少用

`POST /worker-envs/:name/decryptions` 是一项单独授权的动作，不是读取的副作用。优先轮换 secret（设新值）而非解密旧的；每次解密可观测，且值会到达调用方。只在确实需要看存储值时用解密——为调试，或为脚本化轮换前确认那里的内容。

## 从卡住的回合恢复

一个看起来卡住的回合，通常在等模型或 provider，不在等 Ankole。在取消任何东西之前：

1. 查 `/ai-gateway/conversations` 该回合的近期模型调用——若有长间隔，provider 是瓶颈。
2. 查 worker 日志看是否有进行中的工具调用——慢工具看起来像卡住的回合。
3. 仅当回合确实楔住，agent 的 session 可被引导，或让回合超时；后台任务的取消是 `POST /background-agent-jobs/:id/cancel`，它让进行中的回合跑完。

激进取消是运维者制造半截副作用的方式。

## 安静地禁用 binding

`DELETE /agents/:agent_uid/signal-bindings/:binding_name` 是*禁用*，不是硬删除——配置可恢复。想在一个频道里让 agent 静音而不丢设置（凭证撤销、假日、事故）时用它。用 `PATCH` 重新启用。

## 每次升级前都备份

Helm 回滚不会反向执行数据库 migration。升级前那两分钟的 `pg_dump`，是"回滚了"和"从备份还原、丢了一天"之间的差别。命令见[升级](../updating/)。

## 把人设当作调谐面

当 agent 行为错——太吵、太静、跑题——人设（`MISSION.md`、`SOUL.md`、`DESIGN.md`）几乎总是对的杠杆，而不是改配置。编辑文档，观察一天，再编辑。配置改 agent 的*能力*；人设改它的*判断*，而错的通常是判断。

## 钉钉每个 agent 一个机器人

钉钉强制一条硬约束：每个 agent 一个启用 binding，每个 `clientId` 一个 agent。要扩展，从一开始就按一个 agent 一个机器人规划——同一 agent 上第二个 binding 以 `dingtalk_binding_already_exists` 失败，在第二个 agent 上复用 `clientId` 以 `dingtalk_app_already_bound` 失败。见[钉钉首机器人](../dingtalk-first-bot/)指南。

## Teams 总是需要公共端点

Teams 把消息作为 Bot Framework webhook 调用投递，不走长连接。Teams 机器人停止工作时，第一件要查的是公共 HTTPS 端点——证书过期、DNS 变更、入口停机，看起来都像"机器人不回复了"。Lark、Slack、钉钉用长连接，能熬过短暂的端点抖动；Teams 不能。

## 下一步

- 完整运维界面，读 [Console 运维操作](../console-operations/)和 [Console API 参考](../console-api/)。
- 环境旋钮，读[环境变量](../environment-variables/)。
- kit 命令，读 [kit CLI 参考](../kit-cli/)。
