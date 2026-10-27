---
title: 运维技巧
description: 日常运维 Ankole 的实用高频技巧——涵盖日志美化、日志级别调整、找回激活码、模型档案调优、密钥轮换与异常回合恢复。
section: Guides
order: 308
---

本页汇总了一批日常运维 Ankole 时经常用到的小技巧。这些经验单独拿出来不足以撑起一篇专题指南，但在实际排障与调优时却能帮你少走不少弯路。

## 本地用 pretty 模式读日志

控制面默认向标准输出打印单行结构化 JSON 日志——便于日志采集系统解析入库，但在本地终端直接肉眼阅读却很吃力。本地开发调试时，可通过管道将日志流交给 devkit 自带的格式化工具处理：

```bash
bun run dev   # 一个终端
bun run kit logs pretty < /path/to/log-stream   # 或把日志文件管道给它
```

生产环境请保留原始结构化 JSON 供日志平台采集检索，本地开发排查时再配合 `kit logs pretty` 阅读。

## 找 bug 前先收窄日志级别

环境变量 `ANKOLE_LOG_LEVEL` 默认为 `info`。复现疑难问题时可临时将其调低至 `debug`，排查完毕后请务必改回 `info`——长期开启 `debug` 不仅会刷出海量日志，还会拖慢服务响应。合法取值为 `debug | info | warning | error`；若填入其他非法字符串，服务在启动阶段就会直接报错退出，绝不会静默忽略。

## 不开终端也能拿到激活码

如果首次打开初始化设置页面需要输入激活码，但手头看不到 `bun dev` 终端（或控制面容器）刚启动时的滚动输出，可直接运行以下命令查询：

```bash
bun run kit show bootstrap-activation-code          # 本地
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"   # Compose
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane | grep "SETUP ACTIVATION CODE"   # Helm
```

请直接通过上述初始化流程实际读取的来源获取激活码，不必自行翻查数据库表。

## 把 model profile 槽当拨盘

每个 Agent 内置的八个模型档案槽位——`primary`、`light`、`heavy`、`coding`、`vision_fallback`、`web_search`、`web_fetch` 与 `image_generate`——都可以当作灵活调节成本与速度的旋钮：

- **按任务轻重调节 `primary`**：主要负责日常快速问答的 Agent，可将 `primary` 绑定到响应更快、单价更低的轻量模型；对推理深度与成稿质量要求更高的岗位，再换绑旗舰模型。
- **为 `light` 绑定真正低延迟的高性价比模型**：该槽位专为高频、低风险的内部辅助路径设计，无需动用昂贵的大模型。
- **按需配置 `vision_fallback`**：只有当 Agent 需要读取图片、且主模型自身不支持多模态视觉输入时才需填写；否则直接留空即可。
- **独立按需开启 `web_search` 与 `web_fetch`**：两项能力彼此解耦，仅在 Agent 确实需要联网检索或抓取网页时再分别绑定。
- **在 AppConfigure 中统一配置 Brain 检索模型**：站点级的 `brain.embedding_model` 决定全站所有 Agent 共用的向量嵌入模型，租户级的 `brain.rerank_model` 则控制当前租户的检索重排模型。若将嵌入模型留空，系统会停用向量语义检索；若将重排模型留空，则直接沿用多路召回融合后的初始排序。详见 [Brain](../brain/)。

如果感觉某个 Agent 平时回复偏慢，往往是因为给它的 `primary` 槽位绑定了远超实际任务复杂度的重型模型。

## 轮换环境变量中的凭据

在 Console 中修改 Worker 环境变量后，新值会从**下一个回合**开始生效，不会热注入当前正在运行中的回合。因此，轮换密钥时请遵循以下顺序：

1. 在 Console 的“环境变量”页面填入新密钥并保存。
2. 等待当前仍在执行中的在途回合自然跑完（这些进程启动时已载入旧环境变量）。
3. 发起一条新消息触发新回合，验证新密钥已正常生效。

切勿根据保存配置那一刻仍在运行的在途回合来判断轮换是否成功——该回合尚看不到新写入的值。

## 只在必要时查看加密值

日常轮换敏感环境变量时，建议直接覆盖输入新值保存，不要为了确认旧内容而频繁点击解密查看；仅在排查线上故障、确有必要核对当前生效值时再点击“查看”。

## 从卡住的回合恢复

当某个回合表面上看起来“卡住不动”时，绝大多数情况下其实是在等待上游模型提供商返回响应，或是某个慢速工具尚未跑完，而非 Ankole 调度本身死锁。动手强制取消前，建议先按以下顺序排查：

1. 查询 `/api/v2/ai-gateway/conversations` 查看该回合最近的模型请求记录——若请求耗时极长仍未返回，说明瓶颈在上游模型提供商。
2. 查看对应 Worker 容器或 Pod 日志，确认是否有长耗时命令或外部工具正在运行——慢工具在界面上看起来就像回合停滞。
3. 确认回合确实彻底卡死后，可先尝试向该 Agent 会话发送运行中引导消息（Steer），或等待其触发闲置超时；若需取消后台 Agent 任务，请调用 `POST /api/v2/background-agent-jobs/:id/cancel`（该接口会等待当前正在执行的单轮动作安全收尾后再退出）。

盲目强行中断在途执行，往往是导致外部系统留下“改了一半”的残缺副作用的根源。

## 安静地禁用 binding

调用 `DELETE /api/v2/agents/:agent_uid/signal-bindings/:binding_name` 执行的是**软停用**而非物理删除，底层配置与关联关系均完整保留。遇到凭证紧急轮换、节假日静默或线上故障止血，希望让某个频道里的 Agent 暂时“闭麦”但又不想丢失原有路由配置时，可直接停用该绑定，事后通过 `PATCH` 接口即可一键恢复启用。

## 每次升级前都备份

执行 Helm 版本回滚只会退回容器镜像版本，**不会**自动反向回滚已经跑完的数据库迁移（Migration）。因此，每次升级版本前，请务必对控制面 PostgreSQL 数据库以及 `BASE_DB_URLS` 中配置的所有独立 Base 分片库执行 `pg_dump` 备份，并妥善离线保管部署引导密钥（`ANKOLE_SECRET_BASE`、`RELEASE_COOKIE` 与 `ANKOLE_FUNCTION_RUNTIME_TOKEN`）——这一步直接决定了遇到意外时究竟能“从容回退恢复”，还是被迫承受数据损失。完整备份与还原流程见 [备份与还原](../backup-and-restore/)。

## 从正确的长期文档调整 Agent

调优 Agent 表现时，请对号入座修改对应的长期配置文档：职责范围或交付标准界定不清时改 `MISSION.md`；沟通语气、行事分寸或推理习惯欠佳时改 `SOUL.md`；生成的网页、演示文稿、报告或图表的视觉风格不统一时改 `DESIGN.md`。三份文档各司其职，请勿把行为准则硬塞进视觉设计规范里。

## 钉钉每个 agent 一个机器人

钉钉渠道强制执行一对一绑定约束：每个 Agent 最多只能启用一条钉钉路由规则，且每个钉钉应用 `clientId` 只能绑定给唯一一个 Agent。如需部署多个钉钉机器人，请从一开始就按“一 Agent 一钉钉应用”规划——尝试在同一个 Agent 下启用第二条钉钉规则会报错 `dingtalk_binding_already_exists`，尝试将同一个 `clientId` 复用于第二个 Agent 则会报错 `dingtalk_app_already_bound`。详细接入步骤见 [Quickstart](../quickstart/#4-连接聊天渠道并创建信号路由规则)。

## Teams 总是需要公共端点

不同于飞书 / Lark、Slack 和钉钉可依赖出站长连接收发消息，Microsoft Teams 始终通过向你的实例发起入站 Bot Framework Webhook 请求来投递消息。因此，一旦发现 Teams 机器人突然失联不回复，请第一时间排查公网 HTTPS 回调端点——TLS 证书过期、DNS 解析变动或反向代理网关宕机，反映在用户侧全都是“机器人不回话了”。长连接渠道能扛过短暂的公网入口抖动，但 Teams 高度依赖入站链路畅通。

## 下一步

- 查阅管理控制台的完整 REST/JSON:API 规范，请参阅 [Console API 参考](../console-api/)。
- 查阅部署级环境变量说明，请参阅 [环境变量](../environment-variables/)。
- 查阅本地开发与运维工具箱命令，请参阅 [kit CLI 参考](../kit-cli/)。
