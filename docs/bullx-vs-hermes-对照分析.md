# bullx-agent ↔ hermes-agent 端到端对照分析

> 生成日期：2026-06-09 · 对照对象：`/Users/ding/Projects/bullx-agent`（TS/Bun，改进对象）vs `/Users/ding/Projects/hermes-agent`（Python，成熟参照系）

## 一、目的与方法

本文从 **端到端运行链路** 出发，把 bullx-agent `app/src` 下的 **198 个 TypeScript 实现文件**逐一走查，按链路切成 **16 层**；每走查到一个细粒度功能（函数/能力），就在 hermes 中定位对应实现，回答两个问题：

1. **hermes 是否处理了 bullx 没有处理、且会改变行为的 edge case？**（失败模式、竞态、恢复、限额、安全、平台差异）
2. **是否有可以快速借鉴的具体代码或设计？** 给出片段与落点。

**判定原则**（遵循 bullx 自身 `AGENTS.md` 的工程文化）：

- 只报告会**改变行为**的遗漏、矛盾、缺失 edge case；纯风格偏好与"我不喜欢这个取舍"视为噪音，不计入。
- bullx 已做得一样好或更好处，如实说明、不编造对称；hermes 无对应处写"无对应"。
- 凡 bullx 已 settle 的架构取舍（单 Installation、控制面/数据面分离、插件窄契约、PG 行驱动会话…），在取舍内部评估一致性，不 relitigate。

**重要前提**：hermes 是单用户本地 CLA agent，bullx 是多主体、服务端、面向企业网关的 Agent OS。两者在**鉴权/会话/配置/持久化/调度底座**上是不同量级——这些层 bullx 多数**结构性领先**；hermes 的价值集中在**被真实劣质模型/网络/平台反复教育出来的健壮性细节**与**工具层成熟度**。下文严格区分"架构选择差异"与"真实缺口"。

**定位决定威胁模型（重要）**：bullx 是**企业数字员工**而非个人数字助理——它本就是**被授权在企业内网中工作的可信主体**。因此 hermes 那套面向个人助理的「私网/内网/localhost 不可达」SSRF 封禁、以及沙箱式的危险操作限制，对 bullx 多数情况是**预期缺席的取舍，不应照搬**（默认封通用私网反而打断本职工作）。据此，下文 **A1/A7 已重定级为「定位相关取舍」而非必修**；真正**不随定位改变**的安全项里，仍保留待确认的是 OIDC 验签可见性(A3) 与 secret 不入模型上下文(A4)。唯一不被该定位消解的 SSRF 窄条是**云实例元数据(IMDS)凭证窃取**（会把权限从「员工身份」越权抬到「宿主节点身份」）与**提示注入驱动的出站外泄**，且这两点通常更适合在**基础设施层**（IMDSv2 hop-limit / NetworkPolicy / 出站代理）处理，与 bullx 依赖容器编排的部署假设一致。

## 二、总体判断（分层计分卡）

一句话：**bullx 在"持久化正确性 / 鉴权授权 / 并发模型 / 配置体系"上结构性领先；落后集中在三处——① Agent 循环与工具层的健壮性，② LLM provider 弹性（限频/多 key），③ 一簇安全硬化（SSRF、secret 通道、OIDC 验签可见性、bind 收敛）。**

| # | 层 | bullx vs hermes | 一句话 |
|---|---|---|---|
| 1 | 进程启动 / Web / console | 持平 | bullx 鉴权+机密处理领先；hermes 进程可观测性+不可信网络硬化领先 |
| 2 | External Gateway 核心层 | 契约领先 / 渲染落后 | 投影/恢复契约更干净；**缺消息长度切分 + rich→plain 回退** |
| 3 | External Gateway 运行时 | 领先 | 入站/出站幂等、恢复更完整；出站重试耗尽 dead-letter 与告警已补齐 |
| 4 | Agent 主循环 / Harness | 结构领先 | 循环骨架更干净；孤儿 tool-pair 修复、空回复 nudge、迭代上限+grace **已于本期实现**（`agent-loop.ts` + 单测）；余项见 §4 |
| 5 | 上下文压缩 / 渲染 | 持平 | 可审计/可重放领先；触发估算、摘要失败兜底、历史媒体剥离与 base64 估算已补齐，剩余防抖动等细节 |
| 6 | 运行时生成 / 命令 | 持久化正确性领先 | 租约/fence/恢复更强；`/stop` 卡死强清已补齐，`/steer` 本轮注入经复核为已有 out-of-band note 语义 |
| 7 | 会话 / ambient / 每日重置 | 内核领先 | 并发/生命周期更结构化；ambient 批窗硬上限已补齐 |
| 8 | Clarify 反问 | 更细 / 缺交互类型 | 卡片/门禁更细；**无 secret 掩码 / sudo 通道**（安全相关） |
| 9 | Computer 工具 | 落后 | 补丁 fuzzy/CRLF 已补齐；仍缺大输出落盘、进程可观测性 |
| 10 | 杂项工具 + Web | 工具对等 / Web 出站防护属定位取舍 | todo/check_back_later 领先或对等；Web 缺通用 SSRF 封禁**是企业数字员工定位下的预期取舍**（仅 IMDS/出站外泄那一窄条值得评估，多属基础设施层） |
| 11 | Library / Skills / Soul | 存储领先 / 安全条件性缺 | PG 存储+per-agent 覆盖更强；skill_append 审计与 frontmatter 诊断已补齐，自建技能安全仍属条件性缺口 |
| 12 | Computer 服务 + LLM provider | 沙箱取舍 / provider 落后 | 沙箱控制面更干净；provider 错误分类/重试已补齐，仍缺限频头解析/多 key |
| 13 | 插件 + 调度器 | 底座领先 / cron 硬化落后 | 插件窄契约合理、调度底座更强；cron deadline 与 catchup fast-forward 已补齐 |
| 14 | Principals / 鉴权 / 授权 | 大幅领先（结构性） | 真正的多主体授权 OS；hermes 无对应，仅借点状鉴权硬化 |
| 15 | 配置 / i18n / setup | 领先 | DB+registry+Zod 消灭一堆 edge case；缺**配置值版本迁移**、i18n 回退链 |
| 16 | 通用基础设施 + DB Schema | 领先 | PG+KMS+AEAD 更工业级；日志脱敏、SQL params 收敛、set-null FK 索引、jittered backoff 已补齐 |

## 三、跨层最高价值借鉴清单（按优先级，可直接转 backlog）

下表是从 16 层中提炼的、**会改变行为且落点清晰**的借鉴项。优先级：**A=安全/数据正确性（应尽快修）**，**B=健壮性高 ROI**，**C=增强/运维/前瞻（按需）**。"层"列指向下文章节号。

### A. 安全 / 数据正确性

> **定位校正**：bullx 是企业数字员工，被授权在企业内网工作，故 **A1/A7 的「私网/内网不可达」防护是预期缺席的取舍，非必修**——下表已据此重定级。A3/A4 仍需保留。

| 项 | 层 | 问题 | 落点 |
|---|---|---|---|
| **A1 Web 出站防护（定位相关取舍，非必修）** | §10 | `webfetch.ts:66` 对模型可控 URL 裸 `fetch`。**作为企业数字员工，可达内网/私网是预期行为，不应默认封禁。** 真正不被定位消解的只有两窄条：① **云实例元数据(IMDS 169.254.169.254)** 凭证窃取——把权限从「员工身份」越权抬到「宿主节点身份」；② 提示注入下的 confused-deputy（外部内容驱动出站，见 A7） | 这两点通常更适合在**基础设施层**处理（IMDSv2 hop-limit / NetworkPolicy / 出站代理），与 bullx 依赖容器编排的部署假设一致。若要在应用层兜底，**仅对 IMDS 网段做永久封禁**即可，**不要**封通用私网。记录为**显式取舍** |
| **A3 OIDC id_token 验签不可见（自查）** | §14 | 主体层生成了 nonce 并透传，但**本层看不到任何 id_token 验签**——alg 白名单/aud/iss/nonce 全委托 plugin adapter | 确认 adapter 做了 alg 白名单(防 `alg:none`)、aud==client_id、iss pin、回传 nonce==cookie nonce；否则等于裸 auth-code |
| **A4 Clarify 无 secret/sudo 通道** | §8 | bullx 只有 clarify 一种"问用户"原语；用它录密钥/密码会把明文回显进模型上下文 | 新增 `secret-prompt` 交互类型：输入掩码、限发起人、答案**不进** tool result、值经 `aeadEncrypt` 落库；sudo 复用同款 |
| **A5 console 默认 bind 0.0.0.0 + 无 Host 头校验** | §1 | Bun `listen` 只给 port → 默认全网卡；console 是高权限面（建删 agent/改 LLM 凭证），无 Host 校验易受 DNS-rebind | 默认 `hostname:'127.0.0.1'`（显式 env 才放开）+ `onBeforeHandle` 加 Host 头白名单 |
| **A7 URL 内嵌密钥外泄拦截（降级，非必修）** | §10 | `web_extract` 的 URL 来自模型，可能把上文 secret 拼进 query 外泄——**外泄方向不被「内网可达」定位消解**，但严重度低 | 抽取入口 percent-decode 后用密钥前缀正则扫描，命中即拒。低优先 |

### B. 健壮性 / 会改变行为的真实缺口（高 ROI）

> **本期已实现（已从下表移除）**：孤儿 tool_call/result 修复 + 空 assistant 兜底、工具后空回复 nudge 续跑、迭代预算硬上限 + grace 收尾——三项均落在 `app/src/ai-agent/core/agent-loop.ts`（配 `agent.ts`/`types.ts`/`runtime.ts` 接线 + `agent-loop.test.ts` 单测），详见 §4 顶部 callout。以下为**下一期**剩余项。

| 项 | 层 | 问题 | 落点 |
|---|---|---|---|
| **B2 大输出落盘** | §9 | 大输出永久丢中段，模型取不回 | 三级预算：超阈值落盘 worker 返回 preview+路径（`read_file` 取回）；ANSI 清理已补齐 |
| **B4 消息长度切分（含 fence 跨块）+ rich→plain 回退** | §2 | core 无任何按长度切分；接硬上限平台（Telegram 4096/Slack/企微）发长文本即被拒/截断。富格式失败无纯文本兜底 | core 新增 `splitForLength`（mdast 层 fence-safe 切分）+ adapter 发送层 try rich→catch→`markdownToPlainText` 回退 |

### C. 增强 / 运维 / 前瞻（按需）

| 项 | 层 | 一句话 |
|---|---|---|
| C3 配对码/激活码防重放套件 | §14 | 抄 `pairing.py`：盐+哈希存储、常数时间比较、lockout 前置、用一次即删、max-pending |
| C4 外部身份别名折叠 | §14 | 同一人多 ID 形态（WhatsApp LID/phone）归一，补"一人两主体行"盲点 |
| C5 配置值版本迁移 registry | §15 | bullx 有 DB 表迁移但无"key 改名/改形状"承接；做成幂等+记录已执行 id 的 per-key 迁移 registry |
| C6 i18n `normalizeLocale` 别名+逐段截短 | §15 | `zh-CN/zh/zh-Hans` 当前全被打回英文；补别名表+逐段截短回退链 |
| C7 周期内存监控 | §1 | 移植 `memory_monitor.py` 的 grep 友好 RSS 时间序列（`setInterval(...).unref()`） |
| C13 KMS/sealed-cookie 加 `kid` 版本 | §16 | 引入密钥轮换前先加 envelope，否则轮换=强制全员重登 + 存量密文报废 |
| C16 jina 并发扇出 | §10 | `jina.ts:40` 裸 `Promise.all` 改有界扇出；显式 provider 配置失败精确报错已补齐 |

## 四、覆盖矩阵（证明无遗漏）

198 个 `app/src/**/*.ts` 实现文件全部纳入对照，按端到端链路映射到 16 层：

| 层 | 覆盖的 bullx 文件/目录 |
|---|---|
| §1 进程启动/Web/console | `main.ts`、`core/{agent,http,index,spa-html,web-routes,web-server}.ts`、`console/{routes,service,localized-text}.ts` |
| §2 Gateway 核心 | `external-gateway/core/{capabilities,errors,events,index,markdown,projection,stream,types,visible-output-stream}.ts` |
| §3 Gateway 运行时 | `external-gateway/{adapter-registry,agent,agent-events,config,handlers,index,interactive-output,metadata,outbox,projection,routes,runtime}.ts`、`testing/mock-im-adapter.ts` |
| §4 Agent 主循环/Harness | `ai-agent/core/{agent-loop,agent,bullx,index,types}.ts`、`core/harness/{messages,system-prompt,skills,types}.ts`、`core/harness/session/session.ts` |
| §5 压缩/上下文 | `ai-agent/{compression,microcompact,token-estimate,context-renderer,trajectory}.ts`、`core/harness/compaction/{compaction,utils}.ts` |
| §6 运行时生成/命令 | `ai-agent/{runtime,commands,run-registry}.ts` |
| §7 会话/ambient/每日重置 | `ai-agent/{conversation-service,daily-reset,ambient,lifecycle-revisions,config}.ts` |
| §8 Clarify | `ai-agent/clarify-registry.ts`、`tools/{clarify-tool,clarify-format,choice-prompt}.ts` |
| §9 Computer 工具 | `ai-agent/tools/computer/*`（command/terminal/interactive-terminal/process/read-file/patch/v4a/diff/context/format/index） |
| §10 杂项工具+Web | `ai-agent/tools/{todo-tool,build-tool,check-back-later-tool,web-search-tool,web-extract-tool}.ts`、`ai-agent/web/*`（config/http/provider/registry/providers/{exa,jina,parallel,webfetch,index}） |
| §11 Library/Skills/Soul | `ai-agent/library/{service,tools,default-soul}.ts`、`core/harness/skills.ts`（与 §4 交叉） |
| §12 Computer 服务+LLM provider | `computer/{routes,service,tokens}.ts`、`llm-providers/service.ts`、`db-schema/{computer,llm-providers}.ts` |
| §13 插件+调度器 | `plugins/{catalog,config-json,config,discovery,index,runtime}.ts`、`scheduler/{headless-adapter,index,routes,runtime,schedule,service,store}.ts` |
| §14 Principals/鉴权 | `principals/**`（admin-auth/{access,api-routes,config,oidc,session}、agents、authorization/{grants,groups,memberships,request,service}、external-identities、human-users、identity-providers/*、principals） |
| §15 配置/i18n/setup | `config/{app-configure,env,i18n,i18n-locales,json-value-schema,system}.ts`、`setup/{bootstrap,config,plugins,routes,runtime-state,session}.ts` |
| §16 通用基础设施+DB Schema | `common/{async,database,db-migrate,di,errors,json,kms,lifecycle,logger,normalize,sealed-cookie}.ts`、`common/db-schema/*`（ai-agent/app-configure/authorization/external-gateway/library/principals/scheduler/index） |

> 说明：`*.test.ts` 测试文件由各层子代理按需阅读以理解语义，对照结论以实现文件为准。

---

## 五、各层详细对照

下文为 16 层的逐细粒度对照，每层含：简介 → 细粒度功能对照表（bullx 实现 / hermes 对应 / hermes 额外 edge case / 可借鉴 / 优先级）→ 重点可借鉴项（含代码片段与落点）→ 结论（落后/持平/领先）。



---

## 1. 进程启动 / Web 服务器 / 管理控制台

bullx 是 Bun/Elysia + 多 principal + 3 个 SPA（setup/sessions/console）的架构，console 本身（OIDC + KMS 密封 cookie + DB 后端的 admin-group 鉴权、机密永不回传、交互式配置会话）在**鉴权强度与机密处理**上明显领先 hermes 的单进程 dashboard。但 hermes 在**进程生命周期可观测/可恢复性**（OOM 监控、关闭取证、systemd 时序对齐、PID 抢占竞态、跨平台信号回退）和**面向不可信网络的边界硬化**（Host 头 DNS-rebind 防护、回环 CORS、非回环强制鉴权）上沉淀了大量真实事故修复，是 bullx 当前最值得借鉴的方向。

| 细粒度功能 | bullx 实现 | hermes 对应 | hermes 额外考虑的 edge case | 可借鉴的代码/思路 | 优先级 |
|---|---|---|---|---|---|
| 启动依赖顺序 | `agent.ts:35-110` 显式按 setup→library→providers→plugins→tools→gateway→scheduler→identityProviders 顺序启动；每步设 `*StartAttempted` 标志，失败时 `shutdownRuntime()` 逆序回滚 + DB 关闭。注释解释为何 gateway 必须先于 realtime listener | `run.py:4307 start()` / `19997-20060`：start→cron ticker→`wait_for_shutdown`。MCP 工具发现放进 executor 避免冻结 loop (`20034-20039`) | hermes 把"慢 MCP 发现"挪出事件循环线程避免冻结心跳；bullx 无此问题（无长连接心跳） | bullx 的「StartAttempted 标志 + 逆序回滚」比 hermes 更干净，**bullx 领先**。无需借鉴 | — |
| 优雅关闭 / drain | `agent.ts:42-81`：`shutdownRuntime` 停各 runtime 再 `closeDatabase({timeout:5})`，然后 `process.exit(0)`。**无 HTTP 在途请求 drain，且 Elysia listener 从未被显式 stop** | `run.py:6484-6811 _stop_impl`：标 `_draining`、通知活跃会话、`_drain_active_agents(timeout)`、超时则中断并写 `resume_pending` durable marker、写 `.clean_shutdown` marker | hermes 在 drain 超时前**预写 `resume_pending` 标记**，使被强杀的会话下次启动能自动恢复；区分"drain 完成"vs"超时中断"清不同 marker | bullx 是无状态 API+SPA host，不需要会话级 drain。但 **listener 未纳入关闭序列**是真实遗漏（见下"重点项3"） | P3 |
| 信号处理 SIGINT/SIGTERM | 已补齐退出码语义：无信号正常停为 0，SIGINT=130，SIGTERM=143，shutdown 失败仍 exit(1) | `run.py:19855-19974`：`loop.add_signal_handler` 注册 SIGINT/SIGTERM/SIGUSR1；**SIGINT→planned_stop（exit 0），意外 SIGTERM→exit 1 让 systemd Restart=on-failure 复活**（`20096-20101`） | bullx 采用容器/Unix 常见 signal exit-code 语义，不引入 marker 文件 | 已补齐 | — |
| 跨平台信号回退 | 无（依赖 POSIX 信号 + Bun） | `run.py:19509-19567,19988-19995` `_run_planned_stop_watcher`：Windows 上 `add_signal_handler` 抛 NotImplementedError，故用**文件 marker 轮询线程**驱动同一关闭路径；POSIX 上是无害安全网 | Windows 原生下 `gateway stop` 的 SIGTERM 永不触发 handler→会话静默丢失（issue #33778）。marker 必须校验 PID 属于自己 | bullx 当前定位 Linux 容器，优先级低；若未来上 Windows 桌面再议 | P4 |
| OOM / 内存监控 | 无（无周期 RSS 采样；仅靠外部 K8s/容器 metrics） | `memory_monitor.py` 全文：daemon 线程每 5min 输出单行 `[MEMORY] rss=…MB gc=… threads=… uptime=…`；start 时打 baseline、shutdown 时打 final；`resource.getrusage`→`psutil` 回退，都不可用则告警一次后禁用 | macOS ru_maxrss 单位是 bytes、Linux 是 KB 的差异；join 在锁外避免卡死关闭；读不到 RSS 就不空转线程 | **直接移植**：长跑进程缓存 agent/transcript/MCP 连接易缓慢泄漏，grep 友好的时间序列对排障价值极高（见"重点项1"） | P1 |
| 关闭取证 | 已补齐轻量同步快照：shutdown 日志包含 pid/ppid/uptime/loadavg，未引入同步 shell/ps | `shutdown_forensics.py` 全文 + `run.py:19885-19940`：同步 `snapshot_shutdown_context`（<10ms，纯 stdlib /proc 读：父进程 cmdline、是否 systemd、loadavg、tracer pid、takeover/planned-stop marker）+ 异步 detached `spawn_async_diagnostic`（ps auxf/pstree/dmesg→日志文件） | hermes 更厚的 detached 诊断可按运维需要另议；bullx 已补齐低成本快照 | 已补齐 | — |
| 端口绑定竞态 | 无显式处理：`app.listen({port})`，EADDRINUSE 直接抛、进程崩。无 PID 文件、无双实例互斥 | `run.py:19997-20026`：listen **前**用 `get_running_pid()` + `acquire_gateway_runtime_lock()` + `write_pid_file()`（`O_CREAT\|O_EXCL` 竞态）三重抢占；输者在碰任何外部服务前干净退出；`atexit` 注销 | 关闭 `--replace` 双实例竞态窗口：两个 `--replace` 都过了"等旧进程退出"，但只有 O_EXCL 赢家能开 Telegram/Discord socket | hermes 这层是为"独占外部长连接"设计；bullx 多实例可水平扩展（无状态），**不适用**，但单机部署可加一个 PID 锁防误启两份。注：hermes `start_server` 本身**不处理 EADDRINUSE**，让 uvicorn 崩——这点两边一样 | P4 |
| HTTP API 边界守卫 | `web-server.ts:66-84`：仅对 `/api/` 的**非安全方法**做 ① origin≠url.origin→403 ② 有 body 但 content-type 非 json→415。逻辑集中、可测（`serveStaticAssets:false`） | `web_server.py:325-385`：`host_header_middleware`（Host 头校验防 DNS-rebind）→`_dashboard_auth_gate`（OAuth）→`auth_middleware`（token），三层中间件链 | hermes 额外有 **Host 头白名单**防 DNS rebinding（GHSA-ppp5-vxwm-4cf7）：CORS/同源都挡不住——浏览器把 TTL-flip 到 127.0.0.1 的攻击者域名当成同源 | bullx 默认 **bind 0.0.0.0**（`listen` 只给 port，Bun 默认全网卡）+ 无 Host 校验 + 无 CORS：若 console 暴露到 LAN，DNS-rebind/跨站可达。**应补 Host 头校验**（见"重点项5"） | P1 |
| CORS / origin 校验 | `web-server.ts:71-75`：仅当请求带 `Origin` 且 ≠ 自身 origin 时 403，且**只对 mutating 方法**。无 CORS 响应头、无预检处理 | `web_server.py:203-208`：`CORSMiddleware allow_origin_regex=^https?://(localhost\|127\.0\.0\.1)(:\d+)?$`，显式只放行回环 | hermes 注释点明：bind 0.0.0.0 + `allow_origins=["*"]` 会让任意网站读写 config/secrets，故正则锁死回环 | bullx 的"无 Origin 头即放行"对**非浏览器客户端**是合理的（curl 不带 Origin），但对浏览器同源已足够；缺的是 bind host 收敛，而非 CORS 本身 | P2 |
| content-type 守卫 | `web-server.ts:77-83,140-145`：`requestHasBody`（content-length≠0 或有 content-type）→要求 `application/json`，否则 415。**集中实现，比 hermes 显式** | 无统一 content-type 守卫（FastAPI 按 route 的 pydantic/Form 解析隐式处理） | — | **bullx 领先**：这是干净的 CSRF/误投递防线（表单 POST 无法伪装 json） | — |
| idle timeout | `web-server.ts:150-152` + `agent.ts:89`：显式 `idleTimeout: 0`（禁用），为长 SSE/流式预留 | uvicorn 默认 `timeout_keep_alive=5s`；`ws_ping_interval/timeout` 默认开 | hermes 依赖 uvicorn 默认 keep-alive/WS ping 保活；bullx 主动关 idle 是有意取舍 | 各有取舍，无遗漏。bullx 若加 WS（如 console PTY）需自管 ping/超时 | — |
| 自重启 / 崩溃复活 | 无进程内重启；依赖 K8s/容器编排重启 Pod | `run.py:19943-19944 restart_signal_handler`（SIGUSR1）+ `restart.py`（exit code 75 = EX_TEMPFAIL 请 service manager 重启）+ `check_systemd_timing_alignment` | hermes 在**进程内**支持 in-place 重启（/restart、/update、模型切换），并用退出码与 service manager 协议化；启动时校验 systemd TimeoutStopSec≥drain+30s 否则告警（防 SIGKILL 打断 drain 被误判为 phantom kill） | bullx 走"不可变 Pod 重启"路线，进程内重启非其模型；**`check_systemd_timing_alignment` 思路**（启动时自检编排器超时配置）对裸机 systemd 部署可借鉴 | P3 |
| 鉴权模型（console vs dashboard） | `admin-auth/session.ts:1-60`：**KMS 密封**（非仅签名）cookie、OIDC 登录、7d TTL、`access.ts` 查 DB 的 builtin admin-group 成员资格。`routes.ts:429-436` 每路由 `requireConsoleAdmin`；`web-routes.ts:87-108` SSR 前先校验 session 再下发 console SPA | `web_server.py:183` `_SESSION_TOKEN=token_urlsafe(32)`（进程级临时 token，注入 SPA HTML），`8887-8937` 注入 `window.__HERMES_SESSION_TOKEN__`；非回环才启 OAuth gate | hermes 回环模式是"够用就好"的临时 token；只有暴露公网才上 OAuth（fail-closed：无 provider 则拒绝 bind，`web_server.py:9967-10011`） | **bullx 鉴权显著领先**（密封 cookie + OIDC + DB 角色 + per-route 守卫）。可反向给 hermes 借鉴，bullx 此处无需改 | — |
| 机密回传处理 | `service.ts:826-853 publicConfigForSetup`：密机字段**永不回传**前端，只给 `{present:true/false}` 占位；保存时空串/`{present:true}` 保留旧加密值，删 channel 才擦除 | `web_server.py:2730-2756 /api/env/reveal`：可**回传明文**机密，靠 ① session token ② 速率限制（30s 内 5 次）③ 审计日志 防滥用 | hermes 选择"可 reveal 但限频+审计"；bullx 选择"根本不回传" | **bullx 更保守、更安全**（无 reveal 攻击面，无需限频）。**bullx 领先** | — |
| 静态资源 / SPA 下发 | `web-server.ts:41-58` dev 用 Bun fullstack HMR、prod 用 `staticPlugin` 服务 `/assets`；`spa-html.ts` SSR 生成 3 套 SPA HTML，**手写 escapeHtml/escapeHtmlAttribute** 防注入，manifest 缓存（prod）| hermes `8887-8937` 单 `index.html` 注入 token + base-path（`X-Forwarded-Prefix` 支持反代子路径） | hermes 支持反代子路径前缀注入（`__HERMES_BASE_PATH__`）；bullx 按 cookie-session 边界给 setup/sessions/console **三套独立 HTML** | bullx 的 per-SPA SSR + 逐路由 cookie 边界比 hermes 单 SPA 更细，**bullx 领先**；若 bullx 要上反代子路径可借 base-path 注入 | P4 |
| Profile / 多实例隔离 | 无 `--profile` 概念；靠 env（`HTTP_PORT`/`DATABASE_URL`/`REDIS_URL`）+ 容器隔离，一个 Installation 一套 | `main.py:305-396 _apply_profile_override`：argparse 前拦截 `--profile/-p`，设 `HERMES_HOME` 再 import；校验 profile 名正则、防把 `-p no:xdist` 误读、profiles.py 出错绝不阻塞启动、sticky `active_profile` 文件 | hermes 单机多 profile 切换（coder/personal…），需在任何 import 前确定 HOME；大量防御（坏文件、非法名、回退默认）| bullx 架构是"一 Installation 一域"，profile 非其模型（CLAUDE.md 明确）。**不适用**，列此仅为说明取舍差异 | — |
| 进程级 IO 健壮性 | 无 `_SafeWriter` 等价物；Bun 下 stdout EPIPE 行为未显式兜底 | `process_bootstrap.py:63-150 _SafeWriter`：包裹 stdout/stderr，吞 broken-pipe 的 `OSError/ValueError`（systemd/docker/线程拆解竞态），防 print 崩溃 agent；`hermes_bootstrap.py` Windows UTF-8 兜底 | hermes 在 daemon/容器下 stdout pipe 失效时 `print()` 抛 `OSError [Errno 5]` 会崩 setup/run，尤其 except 里再 print 的双重故障 | bullx 跑 Bun（非 Python），EPIPE 处理机制不同；但"日志写失败不应崩主流程"的原则可在 logger sink 层留意（低优先级，Bun/pino 通常已兜底） | P4 |

### 重点可借鉴项

**1. [P1] 周期内存监控（grep 友好的 RSS 时间序列）—— 几乎可直接移植**
落点：bullx 新增 `app/src/core/memory-monitor.ts`，在 `agent.ts` 的 `startBullXAgent` 成功段启动、在 `shutdownRuntime` 里停止。bullx 是长跑进程，缓存 plugin catalog、AI agent tools、interactiveConfigSessions（`service.ts:289` 的 Map）、DB 连接池等，慢泄漏在单条日志里不可见。hermes `memory_monitor.py:83-127` 的单行格式直接照搬：
```ts
// 每 5min 一行，pino 结构化日志即可
setInterval(() => {
  const { rss } = process.memoryUsage()
  logger.info({ tag: 'MEMORY', rssMB: Math.round(rss / 1048576),
                uptimeS: Math.round(process.uptime()), heapUsedMB: ... },
              '[MEMORY] periodic')
}, ms('5m')).unref()   // unref 关键：不阻塞进程退出（对应 hermes daemon=True）
```
要点（来自 hermes）：start 打 baseline、shutdown 打 final（`memory_monitor.py:179,209`）；`.unref()` 对应 hermes 的 daemon 线程语义；interval 走配置而非硬编码。Node/Bun 下 `process.memoryUsage()` 比 hermes 的 `resource.getrusage` 跨平台差异处理更简单，移植成本极低。

**2. [P3] 把 Web listener 纳入关闭序列（真实遗漏）**
落点：`web-server.ts:147-154` `startWebServer` 与 `agent.ts:42-50` `shutdownRuntime`。当前 `app.listen()` 的返回（Bun `Server`）被丢弃，关闭时只停 runtime + DB，listener 靠 `process.exit(0)` 硬断——在途 HTTP 请求（含 console 写操作、interactive-config 轮询）会被截断。`main.ts:4-5` 也只是顺序 await 两个 start，没有把 web server 句柄交回组合根。建议：
```ts
// startWebServer 返回 server 句柄
export async function startWebServer() {
  const app = await createWebServer()
  const server = app.listen({ port: AppEnv.HTTP_PORT, idleTimeout: 0 })
  return server  // Bun Server，有 .stop(closeActiveConnections?)
}
// agent shutdown 中：先 server.stop() 停止收新请求并等在途完成，再停 runtime/DB
```
对照 hermes `run.py:6651-6811`：drain 活跃工作 → 关 adapter → 关 DB，是有序的。bullx 无会话级 drain 需求，但"先停 listener 再关 DB"能避免在途请求打到已关闭的 DB 连接（`closeDatabase({timeout:5})` 与在途查询竞态）。优先级 P3 因为 console 写操作短、影响面小。

**3. [P1] 收敛 bind host + 加 Host 头校验（面向 LAN/不可信网络的硬化）**
落点：`web-server.ts:149-152` 的 `app.listen({ port })`。Bun 缺省 `hostname` = `0.0.0.0`（全网卡），而 console 是高权限面（建/删 agent、改 LLM 凭证、管 principal）。bullx 当前**无 Host 头校验、无 CORS、bind 全网卡**——若 console 被暴露到 LAN，存在 DNS-rebinding 与跨站请求面。借 hermes `web_server.py:281-352`：
```ts
// 1) 默认 bind 回环，显式 env 才放开（对应 hermes --insecure 的有意 opt-in）
app.listen({ port: AppEnv.HTTP_PORT, hostname: AppEnv.HTTP_BIND_HOST ?? '127.0.0.1', idleTimeout: 0 })

// 2) onBeforeHandle 里加 Host 头白名单（防 DNS rebind，GHSA-ppp5-vxwm-4cf7）
const host = (request.headers.get('host') ?? '').split(':')[0].toLowerCase()
if (boundHost in {'127.0.0.1','localhost','::1'} && !LOOPBACK.has(host)) {
  set.status = 400; return { error: 'invalid host header' }
}
```
hermes 的论证（`web_server.py:329-335`）：CORS/同源都挡不住 DNS rebinding——浏览器把 TTL-flip 到 127.0.0.1 的攻击者域名视为同源，必须在应用层校验 Host。注意这与 bullx 现有 `origin !== url.origin` 检查（`web-server.ts:71-75`）**互补不重叠**：origin 防跨站读、host 防 rebind。**这是 bullx web 边界最实质的缺口**，尤其考虑到默认全网卡 bind。

### 结论

**整体持平、各有强项**：bullx 在 console 鉴权（KMS 密封 cookie + OIDC + DB 角色 + per-route 守卫）、机密处理（永不回传，无 reveal 攻击面）、API 边界守卫（集中的 origin + content-type 415 守卫）、多 SPA 逐 cookie 边界 SSR 上**明显领先** hermes 的进程级临时 token dashboard；退出码语义与轻量关闭快照已补齐。剩余最高 ROI 借鉴是：①周期内存监控（P1，近乎直接移植）②Host 头校验 + 默认回环 bind（P1，bullx 默认 0.0.0.0 是实质缺口）③Web listener 纳入关闭序列（P3）。


---

## 2. External Gateway 核心层

bullx 的 External Gateway 核心层（`app/src/external-gateway/core/`）走的是一条非常克制、定义清晰的路线：把"normalized fact → projection / input window / outbox"作为唯一职责，markdown 用 mdast AST 做规范中介，能力协商用一个 `requireOutboundCapability` 守卫，流式只保留一个"弱可见输出"的 Redis 流（明确声明可丢失，最终真相在 agent/outbox）。这套契约边界划得很干净，设计文档也明确写了"不是审计子系统""不做 provider 特定事件类型"。

hermes 没有"核心层 vs adapter"的对称分层——它把所有跨平台渲染/分帧/限流逻辑下沉到 `gateway/platforms/base.py`（基类，207k）+ 各平台子类。因此 hermes 的"核心层对应物"其实是 base.py 的若干基类方法 + `agent/markdown_tables.py` + 各平台的 `format_message`。对照下来，**bullx 在契约纯度和投影语义上明显更成熟**（projection 的 stale 保护、reaction raw-key 保留、tombstone 跨房间隔离、recovery 边界都很扎实），而 **hermes 在"把文本真正塞进具体 IM 平台"这一步积累了大量血泪 edge case**——长度切分、代码块跨切分、inline code 跨切分、UTF-16 计长、表格按平台降级、解析失败回退纯文本、流式近切分点自适应延迟。这些 hermes 处理了、bullx 核心层目前完全没有（bullx 把它们留给了尚未充分实现的各 adapter，目前只有 lark adapter，且 lark 用原生卡片/post 富文本，绕开了纯文本长度切分问题）。

注意一个公平前提：bullx 的设计是"core 给 AST，adapter 负责渲染到平台"。所以下表里很多"hermes 额外 edge case"严格说不是 bullx core 的职责遗漏，而是**bullx 整个 outbound 渲染链路目前缺失的能力**——但因为 core 显式导出了 `tableToAscii`/`parseMarkdown`/`BaseFormatConverter` 作为"共享渲染原语"，这些缺失的原语（长度切分、fence-aware chunk）正是应该落在 core 层供所有 adapter 复用的，所以放在本对照里讨论是恰当的。

### 细粒度功能对照表

| 细粒度功能 | bullx 实现 | hermes 对应 | hermes 额外 edge case | 可借鉴 | 优先级 |
| --- | --- | --- | --- | --- | --- |
| 能力协商（outbound 守卫） | `requireOutboundCapability` + `adapterSupportsCapability` 检查声明能力且方法是 function，否则抛 `UnsupportedChannelCapabilityError`（capabilities.ts:23-33） | base.py 用 `supports_code_blocks`/`supports_draft_streaming()` 等布尔 flag + 子类覆盖（base.py:1801,1906） | hermes 把能力做成"渲染降级开关"（如 `supports_code_blocks=False` 时 fence 走另一条降级路径），bullx 只做"支持/抛错"二元 | bullx 的二元守卫更干净；可借鉴 hermes 把部分能力做成"降级而非报错"的思路 | 低 |
| markdown → 平台特定渲染 | 统一走 mdast AST：`BaseFormatConverter.fromAst/toAst` + `renderPostable`（markdown.ts:405-528），adapter 各自实现 fromAst | 各平台手写 `format_message`：Slack→mrkdwn（slack.py:1505）、Telegram→MarkdownV2（telegram.py:4339）、Feishu→post/plain（feishu.py:2267） | Slack：占位符保护 code/inline/已有实体，再转 link `<url\|text>`、header→`*bold*`、HTML 实体转义（slack.py:1518-1574）。Telegram：MarkdownV2 全字符转义正则 `_MDV2_ESCAPE_RE`（telegram.py:168） | bullx AST 路线更可维护；但 hermes 的"占位符先保护 code/inline 再转义"是 bullx adapter 实现 fromAst 时绕不开的必抄模式 | 中 |
| **消息长度上限切分** | **无对应**。core 无任何按长度切分；唯一长度处理是 lark 卡片 summary 截断 80 字（streaming-card.ts:172） | `BasePlatformAdapter.truncate_message(content, max_length, len_fn)` 基类统一切分（base.py:4696）；各平台 `MAX_MESSAGE_LENGTH`：Telegram 4096、Slack 39000、Feishu 8000（telegram.py:346 / slack.py:319 / feishu.py:1414） | 自然切分点优先 `\n` 再空格；多块自动加 `(1/3)` 指示符（base.py:4818-4823） | **强烈建议**：把 `truncateMessage` 作为 core 共享原语，所有 adapter 复用 | 高 |
| **代码块跨切分** | 无对应 | `truncate_message` 内：切分落在 ```` ``` ```` 内时，在本块结尾补关闭 fence、下一块用原 language tag 重开 fence（base.py:4725-4814） | 逐行扫描判断结束时是否仍在 code block，记 `carry_lang` 跨块续传 | **强烈建议**：bullx 的 mdast 路线天然可在 AST 层做 fence-safe 切分，比 hermes 的文本扫描更优雅 | 高 |
| **inline code 跨切分** | 无对应 | `truncate_message`：若 split 前未转义反引号为奇数，回退到反引号前的空格/换行切，避免 MarkdownV2 出现未配对 `` ` `` 导致 parse error（base.py:4768-4787） | 处理 `\`` 转义计数 | 建议（取决于目标平台是否用 MarkdownV2） | 中 |
| **UTF-16 计长（Telegram）** | 无对应 | `utf16_len()`（base.py:125）作为 `len_fn` 传入 truncate；`_custom_unit_to_cp` 把 UTF-16 预算映射回 codepoint 切点（telegram.py:1867 等） | Telegram 按 UTF-16 code unit 限长，emoji/CJK 计数与 codepoint 不同 | 建议（接 Telegram/Slack 前必需） | 中 |
| **表格 → 平台降级** | `tableToAscii` / `tableElementToAscii`：所有不支持原生表格的平台统一降级为 padding 对齐的 ASCII 表（markdown.ts:182-235） | 分平台：Telegram 把 GFM 表重写成"`**行标题**` + `• 列名: 值` 项目组"（telegram.py:229-278）；`markdown_tables.py` 提供水平 ASCII + 过窄时垂直 `Header: value` 降级 + 软换行/硬断词（markdown_tables.py:105,145,211） | hermes 按"移动端可读性"分平台差异化降级；过窄宽度走垂直布局；检测 row-label 列 | bullx 的单一 ASCII 降级简单够用；若上 Telegram 可借鉴"表→bullet 组"提升移动端可读性 | 中 |
| **解析失败 → 回退纯文本** | 无对应（core 不渲染，无 try/catch 回退）；lark 卡片更新失败置 `degraded` flag（streaming-card.ts:153-156） | Telegram：MarkdownV2 parse 失败 catch BadRequest 后回退 plain text（telegram.py:1958）；Feishu：post payload 被 API 拒后 `_strip_markdown_to_plain_text` 回退（feishu.py:1803-1820） | "富格式失败不丢消息，降级纯文本重发"是核心鲁棒性 | **建议**：adapter 渲染/发送应有 rich→plain 回退；core 可提供 `markdownToPlainText`（已有 markdown.ts:301）作回退原语 | 高 |
| 流式分块 / 限频 | core 只有 `normalizeBullXStream`（过滤为 string/3 种 chunk，stream.ts）+ Redis 弱可见流 append/read（visible-output-stream.ts）。throttle 在 adapter：lark streaming-card 按 `intervalMs` + `bufferThreshold` 决定 `isDue`（streaming-card.ts:159-163） | `GatewayStreamConsumer.run()`：累积 + 按 `edit_interval` 限频渐进编辑 + `buffer_threshold` codepoint 去抖（stream_consumer.py:403,460-477） | hermes 额外：think-buffer 过滤、segment break、commentary、draft 流式、编辑失败时 tail flush（stream_consumer.py:236-305,981） | bullx 弱流 + adapter throttle 的拆分更干净；hermes 的渐进编辑细节（去抖/段落边界）可参考 | 中 |
| **流式近切分点自适应延迟** | 无对应 | Telegram/Feishu：批处理 flush 时若上一块长度 ≥ `_SPLIT_THRESHOLD`(4000) 则用更长 `split_delay`（几乎必有续块）；短消息用更短 fast/short 延迟分档（telegram.py:5310-5339 / feishu.py:3562-3580） | 按"是否快到切分点"自适应等待，减少把一条逻辑消息切成两条的概率 | 借鉴（接入会切分的平台时的体验优化） | 低 |
| 流式溢出处理（编辑中超限） | 无对应 | consumer 中：已有 message 编辑超 `_safe_limit` 时，先编辑首块再为余下开新消息；无 message 时直接 `truncate_message` 分块（stream_consumer.py:480-532） | flood/rate-limit 检测（`_is_flood_error`）+ 重试（stream_consumer.py:892,1277） | 建议（流式 + 长度限制叠加场景） | 中 |
| **flood / rate-limit 容错** | 无对应（core 无）；lark 卡片失败仅置 degraded | `_is_flood_error` 识别 "flood"/"retry after"/"rate"，编辑失败时按 flood 处理并更新 `_last_edit_time` 退避（stream_consumer.py:892-896,1277-1297） | 平台返回限流 → 退避而非丢失/狂刷 | 建议（adapter 层；接 Telegram/Slack 必需） | 中 |
| 可见 vs 隐藏输出 | core 显式：Redis 弱可见流是"in-progress 进度，可丢失"，最终 provider-visible 真相走 agent/outbox（visible-output-stream.ts:41-47 + 设计文档"Outbound and Recovery Boundary"） | hermes 用 `MessageChunk`(transport delta) vs `Commentary`(已完成文本) 区分；事件"只描述 transport，不持久化"（stream_events.py:25,43-83） | hermes 还区分 think-buffer（reasoning 不展示） | bullx 的"弱可见流 vs outbox 真相"边界划得比 hermes 更清晰；这是 bullx 的强项 | 低（bullx 已好） |
| emoji / reaction 规范化 | projection 保留 raw platform emoji 作 map key（`rawEmoji` 优先），normalized emoji 作展示值；alias 归一冲突时 rawEmoji 赢（projection.ts:112-128,348-362） | sticker_cache 缓存 sticker→描述（sticker_cache.py）；reaction 在各平台各自处理 | hermes 主要在 sticker 描述缓存上着力 | bullx 的 reaction raw-key 保留语义更扎实，是强项 | 低（bullx 已好） |
| 部分 / 失败流恢复 | core：Redis 流可丢，恢复走 agent/outbox；outbox 有 `platform_send_started_at` + reconciliation，失败置 `unknown_after_send` 不盲目重发（设计文档 / outbox.ts） | consumer 编辑失败 tail flush 防止已生成未展示文本丢失（stream_consumer.py:981-1012）；`_final_content_delivered` 标志确保只有真落地才算最终送达（stream_consumer.py:504-512） | hermes 在"流中途失败"的局部补救更细 | bullx 的 outbox reconciliation 是更强的恢复保证；hermes 的 tail flush 是流内细节，可作 adapter 参考 | 低（bullx 已好） |
| 消息投影（projection） | `DrizzleExternalGatewayProjectionSink`：latest-state upsert，stale 保护（按 sentAt 比较，旧的不覆盖新的，projection.ts:204-209），re-project 保留已有 reactions（projection.ts:160-167），delete 硬删，reaction 事件可先补投 message（projection.ts:68-81） | session.py / session_context.py 维护会话与消息上下文（56k / 7.7k） | — | bullx 的 projection 语义（stale 保护、reaction 保留、tombstone 跨房间隔离）非常成熟，是强项 | 低（bullx 已好） |
| 消息分帧 / 页脚 | **无对应**。core 无 footer/分帧概念 | `runtime_footer.py`：最终消息附 `model · context% · cwd` 页脚；流式已分块发完时作为独立尾消息发送（runtime_footer.py:18-23,91）；缺字段静默跳过（runtime_footer.py:103） | 只贴最终消息、不贴 tool-progress/流式中间帧；per-platform override | 借鉴（产品化体验，非核心契约） | 低 |

### 重点可借鉴项

下面 5 条是对 bullx **明确改变行为的缺失能力**，且落点清晰。前提：bullx core 已经把 `tableToAscii`/`parseMarkdown`/`markdownToPlainText`/`BaseFormatConverter` 导出为"共享渲染原语"（index.ts:23,43-60 / markdown.ts），所以这些能力应当作为新的 core 原语补齐，供所有 adapter 复用，而不是每个 adapter 各写一遍。

#### 1.（高）核心层缺"按长度切分 + 代码块跨切分"原语 —— 最关键缺口

bullx core 完全没有消息长度切分。任何接入有硬上限的平台（Telegram 4096、Slack 40000、企业微信/钉钉等）的 adapter 一旦直接发长文本就会被 provider 拒绝或截断。hermes 把它做成基类统一原语并处理了 fence 跨块：

hermes `gateway/platforms/base.py:4696` 核心逻辑（节选）：
```python
# 切分点落在 code block 内：本块补关闭 fence，下一块用原 lang 重开
prefix = f"```{carry_lang}\n" if carry_lang is not None else ""
...
in_code = carry_lang is not None
for line in chunk_body.split("\n"):
    if line.strip().startswith("```"):
        in_code = not in_code
        if in_code: lang = (line.strip()[3:].split() or [""])[0]
if in_code:
    full_chunk += "\n```"   # 补关闭 fence，块内自洽
    carry_lang = lang
# 多块加 (i/N) 指示符
```

落点：新增 `app/src/external-gateway/core/chunking.ts`，导出 `splitForLength(text, maxLen, { lenFn?, addIndicator? })`。**bullx 的优势**：它有 mdast AST（markdown.ts:268），可以在 AST 层按 block 边界切分，比 hermes 的纯文本逐行扫描更可靠（不会误判正文里的 ```` ``` ````）。`StreamOptions` 已预留 `updateIntervalMs`（types.ts:42），但没有 maxLength —— 建议在 adapter capabilities 上加一个 `maxMessageLength` 声明，core 切分原语据此工作。从 `core/index.ts` 一并导出。

#### 2.（高）adapter 渲染/发送缺"富格式失败 → 回退纯文本"

bullx core 有 `markdownToPlainText`（markdown.ts:301）但没人把它接成回退路径；lark adapter 发送失败只置 `degraded` flag（streaming-card.ts:153）而不重发纯文本，消息可能就此丢失。hermes 的每个平台都有这层兜底：

hermes Feishu（`gateway/platforms/feishu.py:1803-1820`）：post 富文本被 API 拒 → `_strip_markdown_to_plain_text(chunk)` 重发纯文本。
hermes Telegram（`gateway/platforms/telegram.py:1958`）：MarkdownV2 parse 失败 → catch 后 plain text 重发。

落点：bullx adapter 的发送函数应统一 try rich → catch → 用 core 的 `markdownToPlainText` 回退重发。这是"不丢消息"的鲁棒性底线，建议在 `BaseFormatConverter`（markdown.ts:427）旁加一个 `renderPostableWithPlainFallback` 模板方法，或在 adapter 发送层约定该模式。

#### 3.（中）`fromAst` 实现需要"占位符先保护 code/inline 再转义"模式

bullx 让 adapter 各自实现 `fromAst`（markdown.ts:415），但没给"如何安全转义"的范本。hermes Slack 的 `format_message` 是这类转换的标准范本，bullx 写 Slack/Discord/企微 adapter 时绕不开：

hermes Slack（`gateway/platforms/slack.py:1518-1565`）：先用 `\x00SL{n}\x00` 占位符把 fenced code、inline code、已有 `<...>` 实体、blockquote 全部抠出保护，再做 HTML 实体转义（注意先 unescape 防双重转义 slack.py:1564），最后回填占位符。

落点：虽然 bullx 走 AST（理论上 AST 遍历比正则占位符更干净，不需要保护 code span，因为 code 节点本就是独立节点类型），但**转义时机/双重转义**这个坑是共通的——在 `BaseFormatConverter` 加一个 `escapeText(raw): string` 抽象方法 + 文档说明"只转义 text 节点、不碰 inlineCode/code 节点的 value"，可避免每个 adapter 重踩。

#### 4.（中）表格降级：单一 ASCII 够用，但 Telegram 类移动端可借鉴差异化

bullx 的 `tableToAscii`（markdown.ts:182）对所有平台输出同一种 padding ASCII 表。这在桌面端 OK，但 Telegram/手机端等宽对齐经常崩。hermes 按平台/宽度差异化：

hermes Telegram（`gateway/platforms/telegram.py:229-278`）：GFM 表 → 每行渲染成 `**行标题**` + `• 列名: 值` 的 bullet 组，移动端可读。
hermes `agent/markdown_tables.py:211` `_render_vertical`：宽度过窄时整表转垂直 `Header: value` 块 + 软换行（markdown_tables.py:145）+ 硬断词（markdown_tables.py:164）。

落点：保留 `tableToAscii` 作默认；在 core 增设可选 `tableToBulletGroups(node)`（markdown.ts 内），让面向移动 IM 的 adapter 选用。**注意**：这是 bullx 已做出的合理 tradeoff（统一 ASCII 简单），按 CLAUDE.md "不为理论完备过度优化"，仅在真接 Telegram 时再补，列为中优先即可。

#### 5.（中）UTF-16 计长，接 Telegram 前的硬前提

bullx 所有长度相关逻辑（目前仅 lark summary 80 字 streaming-card.ts:172）都按 JS string `.length`，即 UTF-16 code unit ——巧的是 Telegram 也按 UTF-16，所以 JS 这里反而天然对齐。但 hermes 显式提醒了这个陷阱（Python `len` 是 codepoint，需 `utf16_len` 矫正，base.py:125）。bullx 的反向风险：若 core 切分原语（见第1条）改用 `[...str]`（codepoint 数组）或 `Intl.Segmenter` 计长，就会与 Telegram 的 UTF-16 上限不一致，导致 emoji/CJK 密集消息超限。

落点：实现第1条 `splitForLength` 时，**默认 lenFn 用 `s.length`（UTF-16）**并注释说明这与 Telegram 一致；若某平台（如某些按 grapheme/字节计长的）不同，再通过 `lenFn` 注入。这是个"别把已经对的东西改错"的提醒，配合第1条一起做。

### 结论

bullx External Gateway 核心层在**契约边界、projection 语义、recovery 边界、可见 vs 真相分离**这几个 bullx 团队真正在意的维度上，比 hermes 更成熟、更克制、更可解释——这些是 bullx 的强项，不应为了对齐 hermes 而引入复杂度（reaction raw-key 保留、tombstone 跨房间隔离、outbox reconciliation、Redis 弱流可丢这些都已经做对了，**保持现状**）。

bullx 真正缺的、且**确实改变 outbound 行为**的是"把规范化内容塞进具体 IM 平台"这一公里：**消息长度切分（含 code-fence 跨块）、富格式失败回退纯文本**这两项是高优先、近乎必做的 core 共享原语（第1、2条），否则任何带硬长度上限的新 adapter 都会在第一条长消息上出问题。其余（fromAst 转义范本、表格差异化降级、UTF-16 计长、flood 容错、流式自适应延迟）是接入具体平台时按需补齐的 adapter 层细节，不必提前在 core 一次做全——这与 bullx "为下一次改动设计、能删优于能加、不为理论完备过度优化"的取向一致。

一句话：**核心契约学不动 hermes（bullx 更干净），但 hermes 的"长度切分 + fence-safe 分块 + rich→plain 回退"是 bullx outbound 链路必须补的两块砖，且应落在 core 作共享原语而非每个 adapter 重写。**


---

## 3. External Gateway 运行时（出站/恢复/适配器）

对照范围：bullx 的 IM 入站→出站中枢（`runtime` / `handlers` / `outbox` / `agent-events` / `adapter-registry` / `interactive-output` / `metadata` / `projection`）对照 hermes 的 `gateway/run.py` + `gateway/platforms/base.py` + `gateway/{status,delivery,restart,pairing}.py` + 各平台 adapter。

### 公允评价（先说 bullx 哪里已经做得好）

bullx 的这一层是**经过认真设计的、持久化驱动的中枢**，而非临时拼凑。多数“恢复/幂等/去重”维度它已覆盖，且比 hermes 更结构化：

- **入站幂等**：`providerEventId = type:roomId:messageId:revision` 作为唯一键，`enqueue` 用 `onConflictDoNothing` + 回查既有行（agent-events.ts:89-133），provider 重投天然吸收。hermes 是进程内 `MessageDeduplicator`（TTL 5 分钟、2000 条上限、helpers.py:27-71）+ Telegram 专用的磁盘 marker（run.py:10984），重启后**入站去重记忆丢失**——bullx 用 DB 唯一键这点严格更强。
- **出站幂等/去重**：`(agentUid, bindingName, outboundKey)` 唯一行 + `recoveryState` 状态机（`not_started → send_attempt_started → unknown_after_send`）+ `tryReconcileExisting` 对账（outbox.ts:115-157, 483-502）。这是 hermes **完全没有的**——hermes 出站不落库，重发完全靠进程内 `_send_with_retry`。
- **崩溃恢复语义**：claim 故意不写 DB lease（agent-events.ts:288-294），进程死了行仍 pending；启动时 `recoverExternalGatewayBinding` + `dispatchPendingForBinding` 重投在途 outbox（runtime.ts:382-395, outbox.ts:92-113）。
- **删除/撤回竞态**：`recordInputTombstone`（24h TTL）处理“delete 先于 receive 到达”；`mutatePendingReceive(remove)` 硬删还在批窗内的 pending（而非标 done，避免假装 agent 看过）——handlers.ts:206-315、agent-events.ts:153-197。这块的细致程度**超过** hermes。
- **agent 运行中的中断/转向**：bullx 把执行侧放在 `ai-agent/runtime.ts`，`/stop /new /steer /compress /retry` 有完整的 abortController + fence + pendingSteering 物化 + clarify abort（runtime.ts:1119-1154 等）。**这块功能上与 hermes 对等**，只是分层不同（gateway 解析+批窗，runtime 执行）。
- **投影 latest-state**：`isStaleProjection` 用 sentAt 防乱序覆盖、reaction 与 message 独立生命周期不互相擦除、`for('update')` 行锁（projection.ts:142-209, 228-263）。

下面只列**会改变行为的遗漏 / 缺失 edge case**，不含“我不喜欢这个取舍”的噪音。

### 对照表

| # | Edge case / 维度 | hermes 行为（file:line） | bullx 现状（file:line） | 判定 |
|---|---|---|---|---|
| 1 | **超时不可重试**（非幂等 send 的 read/write timeout 可能已送达，重试=重复） | 显式排除 timeout 出重试集，仅 connect-timeout/连接类才重试；`_is_timeout_error` 单列（base.py:1658-1675, 3279-3347） | `markProviderFailure` 仅按“adapter 是否声明 outbound_idempotency”二分：声明则**一律 retryCount+1 重排**，不区分错误是 timeout 还是连接拒绝（outbox.ts:276-299）。声明幂等的 adapter 不会重复（有 idempotencyKey 兜底），但**未声明幂等**的 adapter 任何失败直接 `unknown_after_send`（永久 failed），无重试 | bullx 偏保守、安全；但对“声明了幂等却是慢响应 timeout”的场景会无脑重排，依赖 provider 侧 idempotencyKey 去重。**非缺陷，是被 idempotencyKey 兜住的取舍** |
| 3 | **格式化失败的纯文本降级** | send 因格式/权限失败（非网络）时，自动改发 `(plain text:)\n\n{content}` 兜底（base.py:3383-3393） | 无。post 失败统一走 `markProviderFailure` 或 `markUnsupported`，**不尝试降纯文本**。card/divider 有 `fallbackText` 字段但只在 unsupported 路径用，send 抛错时不触发 | **缺失 edge case**（中等价值）：富文本/markdown 渲染被 provider 拒时整条消息丢失，而非退化为可读文本 |
| 4 | **凭证锁 / 防两个进程共用同一 bot token** | `acquire_scoped_lock(scope, identity)` 文件锁，含 stale-PID/start_time/SIGTSTP-stopped/空文件等多重 stale 判定（status.py:582-682） | **无对应**。bullx 假设单 Installation，但同机两个进程或误启两份会让两个 runtime 抢同一 webhook/长连接，provider 侧表现为消息抖动/双发。`adapter-registry` 只防同进程内 factory id 重复（adapter-registry.ts:41-46），非跨进程凭证锁 | **缺失**，但与 bullx “单 Installation = 操作域”的定位一致；属**取舍内的已知空缺**，仅在多进程误启时咬人 |
| 4b | **限频 / token-bucket（出站节流）** | Signal 附件 token-bucket 模拟器，从 429 的 Retry-After 自校准 refill（signal_rate_limit.py:165-260）；webhook 路由级 fixed-window 限频返回 429（webhook.py:416-422） | 无任何出站限频/退避节流。`dispatchPendingForBinding` 一次拉 50 条顺序发，退避仅 `2s * retryCount` 在**失败后**生效（outbox.ts:101），无**主动**速率控制 | **缺失 edge case**：突发大量 outbox 行时会以最快速度打 provider，易触发对端限频；之后才被动退避 |
| 5 | **入站去重的内存上限 / 跨进程持久** | 进程内 TTL+max_size 双重裁剪（helpers.py:48-71） | DB 唯一键，**严格更强**（agent-events.ts:109）。tombstone 24h TTL（agent-events.ts:80） | **bullx 更好**，无需借鉴。仅注意：tombstone/agent_events 是 unlogged/无 GC 的话，长期增长需另有清理（不在本模块可见） |
| 6 | **photo/album 突发不打断当前 run** | PHOTO 类型消息进 `_pending_messages` 作为下一轮，不 interrupt（base.py:3972-3974） | 入站批窗 `NORMAL_RECEIVE_BATCH_WINDOW_MS=75ms` + `batchKey(room,thread)` 合并连发（agent-events.ts:79, 136-144, 397-427），天然把突发合一轮投递 | **bullx 用批窗等价覆盖**，机制不同但行为相近，无需借鉴 |
| 7 | **批合并的发送者归属**（共享群里两人同时说话不能合成一轮） | text-debounce 合并前用 `_can_merge_text_debounce_events` 校验同发送者，跨发送者 flush 切轮（base.py:3465-3477） | `claimReadyBatch` 在拼批时遇到 `actorKey != first.actorKey` 即 break（agent-events.ts:421-424），不同 actor 不进同批 | **bullx 已覆盖**，公允算对等 |
| 8 | **edit/recall 完整生命周期** | 各平台 adapter 自管 | recall→tombstone→投影删除→pending 撤除→已投递则补发 lifecycle 事件，全链路 + 详尽 debug 日志（handlers.ts:206-315） | **bullx 更系统化**，无需借鉴 |
| 9 | **streaming card 生命周期** | `GatewayStreamConsumer` 渐进 edit、draft 降级、flood 退避、finalize 能力探测（stream_consumer.py:79-187） | SDK 暴露 `beginStreamingCard/StreamingCardHandle`，由 `ai-agent/runtime.ts:1385` 消费；gateway 层只定义契约 | **存在且分层在 runtime**，本模块不负责，算对等 |

### 重点可借鉴项

下面 3 条是**会改变行为的真实缺口**，按 ROI 排序，给落点与最小改法。出站重试耗尽的 dead-letter 终态与 `retry_exhausted` 告警已于本期补齐，不再列为待办。

#### 2）超时错误的“可能已送达”不可重试语义（表#1）

bullx 的 `markProviderFailure` 只问“adapter 声明幂等吗”，不看错误**形状**。hermes 的核心洞察值得吸收（base.py:1658-1664 的注释）：**非幂等 send 上的 read/write timeout 可能已送达，盲目重试=重复**；只有连接类错误（connect refused/reset、connect-timeout）才确定未送达、可安全重试。

bullx 现状下，对**声明了 outbound_idempotency** 的 adapter 这不致命（idempotencyKey 会在 provider 侧去重）；但对**未声明幂等**的 adapter，bullx 走的是另一条：任何失败直接 `unknown_after_send` 永久 failed（outbox.ts:298）——反而比 hermes 更保守（宁可不发也不重复）。所以这条对 bullx 是**“可选精细化”而非缺陷**：若想让“未声明幂等”的 adapter 在**连接类**失败时也能安全重试一次（而非直接放弃），可引入 hermes 式的错误分类：

落点 `app/src/external-gateway/core/`（新增 `is-retryable-send-error.ts`）+ `outbox.ts` 的 `markProviderFailure`：

```ts
// 仅“确定未送达”的连接类错误才允许非幂等 adapter 重试一次
const CONNECT_ONLY = ['connectionrefused','connectionreset','connecterror','connecttimeout','econnreset','econnrefused']
function isDefinitelyUndelivered(err: unknown): boolean {
  const m = (err instanceof Error ? err.message : String(err)).toLowerCase()
  return CONNECT_ONLY.some(p => m.includes(p))  // 注意：'timed out'/'readtimeout' 不在内
}
```

然后在 `markProviderFailure` 里，未声明幂等但 `isDefinitelyUndelivered` 的，允许走一次有限重试而非立即 `unknown_after_send`。**先确认 SDK 的 adapter 抛错是否携带稳定的错误文案**——bullx 的错误是 `error.message` 自由文本（outbox.ts:281），分类可靠性取决于各 plugin，不如 hermes 那样有 `SendResult.retryable` 显式信号。更稳妥的做法是给 SDK 的出站结果加一个可选 `retryable: boolean`（对齐 hermes base.py:1547），由 adapter 自己判定，gateway 只读。

#### 3）格式化失败的纯文本降级（表#3）

hermes 在富文本 send 因格式/权限失败时，自动改发截断纯文本（base.py:3383-3393），保证用户至少看到内容。bullx 的 outbox 已经为每种 payload 算出了 `fallbackTextFromFinalPayload`（outbox.ts:614-626），但**只在 unsupported 分支消费**，真正 `postMessage` 抛错时不触发降级。

最小改法：在 `dispatchPostLike` 的 catch 里，对**非** `UnsupportedChannelCapabilityError` 的失败，且 payload 是 card/markdown 时，尝试以纯文本重发一次再落 `markProviderFailure`。落点 `app/src/external-gateway/outbox.ts:190-196`：

```ts
} catch (error) {
  if (error instanceof UnsupportedChannelCapabilityError) return this.markUnsupported(key, error.message)
  // 富文本渲染失败兜底：降级为纯文本再发一次（仅当 postable 非纯字符串时）
  if (typeof postable !== 'string' && input.adapter.postMessage) {
    try {
      const raw = await input.adapter.postMessage(input.intent.providerThreadId, text, outboundOptions(input.intent))
      return await this.markSent(key, raw.id)
    } catch { /* fall through */ }
  }
  return this.markProviderFailure(key, input.adapter, error)
}
```

取舍提醒：这会引入“先发卡片失败、再发纯文本”可能双发的风险，需配合幂等 key 或仅在“确定未送达”时降级——与第 2 条同源。**价值中等**，对纯文本/markdown 渠道收益最大。

#### 4）出站主动节流 / 突发限频保护（表#4b，可选）

bullx 的退避只在**失败后**生效（`2s * retryCount`，outbox.ts:101），没有**主动**速率上限。`dispatchPendingForBinding` 一次拉 50 条顺序 await 发出，恢复后的大批量 outbox 会以最快速度打 provider，易触发对端 429 → 全部失败 → 被动退避，形成抖动。

hermes 的 Signal token-bucket（signal_rate_limit.py:165-260）从 429 的 Retry-After 自校准 refill，是平台特定的；通用层面更轻的做法是给 `dispatchPendingForBinding` 加一个**每 binding 的最小发送间隔**或并发上限。这条**优先级最低**，仅在“单 binding 短时大量出站”才有意义，且最好等真实压测出现限频再加，避免过早优化（符合 CLAUDE.md 的 reality bias）。落点 `app/src/external-gateway/outbox.ts:92-113`。

### 结论

bullx 的 External Gateway 运行时是**持久化驱动、恢复语义完整**的一层，在**入站幂等（DB 唯一键 vs hermes 进程内 TTL）、出站幂等去重（outbox 状态机 + 对账，hermes 完全没有）、删除/撤回竞态（tombstone + pending 撤除）、agent 中断/转向（runtime 侧 abort+steer+fence）** 这些核心维度上**不输甚至优于** hermes，不应被“相对不成熟”一概而论。

重试耗尽 dead-letter 终态与告警已补齐。剩余会改变行为的缺口是：

1. **超时“可能已送达”语义**（表#1）——bullx 对未声明幂等的 adapter 已经很保守（直接放弃，不重复），但缺 hermes 式的“连接类错误可安全重试”精细化；建议先给 SDK 出站结果加 `retryable` 显式信号再做，不要靠错误文案猜。
2. **格式化失败纯文本降级**（表#3）——`fallbackText` 已算好但 send 抛错路径未用，中等价值。
3. **凭证锁（表#4）/ 出站主动限频（表#4b）**——与“单 Installation”定位一致的已知空缺，属取舍内、优先级最低，按需再加。

其余维度（批合并、photo 突发、streaming card、reaction 生命周期）bullx 已用不同机制等价覆盖，**无需借鉴**。


---

## 4. Agent 主循环与 Harness

这一层在 bullx 里覆盖：低层 agent 循环（`runLoop` 的 turn 编排 + 工具批执行 + steering/follow-up 注入）、有状态包装 `Agent`、消息类型与 `convertToLlm` 投影、session 树投影、system-prompt 的 skill 块、skill 加载器。对照系：hermes 的 `run_conversation`（`agent/conversation_loop.py`，4965 行）+ `run_agent.py`（5307 行）+ 一众 `agent/*.py` 辅助模块。

总体判断：bullx 的循环骨架干净、抽象漂亮（AgentMessage↔Message 边界清晰、hook 化彻底、并行/串行批执行优雅），但它把"模型总会守规矩"当默认假设；hermes 是被真实劣质 provider/弱模型反复教育出来的，循环里塞满了恢复路径。bullx 在**循环健壮性**上明显落后，在**循环结构与可读性**上领先。

> **本期已落地（不再列为待办）**：
> 1. **孤儿 tool_call/result 修复 + 空 assistant 内容兜底** → 新增 `agent-loop.ts:sanitizeToolPairs`，在 `streamAssistantResponse` 的 wire 边界统一修复（丢无主 toolResult、为缺结果的 toolCall 注入 stub、空 assistant 补占位）。刻意放在发送边界而非 `convertToLlm`，使 trajectory 重放与压缩 token 计数仍看到纯投影。
> 2. **工具后空回复 nudge 续跑** → `AgentLoopConfig.nudgeOnEmptyAfterTools`（runtime 默认开）：上一轮有 toolResult 且本轮 assistant 空时，注入一条 user nudge 续跑一次（每 run 至多一次），不再把模型打嗝当任务完成。
> 3. **迭代预算硬上限 + grace 收尾** → `AgentLoopConfig.maxTurns`（runtime `MAX_GENERATION_TURNS=100`）：到顶后剥离工具、注入"请总结"跑一轮 grace turn，把无限循环/硬截断变成可用总结。
>
> 三者均有单测 `app/src/ai-agent/core/agent-loop.test.ts`。下表与"重点可借鉴项"只保留**下一期**仍待处理的项。

| 细粒度功能 | bullx 实现 | hermes 对应 | hermes 额外考虑的 edge case | 可借鉴的代码/思路 | 优先级 |
|---|---|---|---|---|---|
| thinking-only 回合处理 | **无**。bullx 把 reasoning block 原样保留在 assistant content 里，`convertToLlm` 直接透传——若末块是 thinking，Anthropic 400 | `run_agent.py:3178 _is_thinking_only_assistant` + `agent_runtime_helpers.py:809 drop_thinking_only_and_merge_users`；循环内 `:4330` 还有 prefill 续跑 | "assistant 末块为 thinking" 被 Anthropic 拒（"final block cannot be thinking"）；wire 副本剔除、UI 副本保留 | 把 `_is_thinking_only_assistant` 的判定 + 丢弃合并逻辑加进 `convertToLlm`（或其后置 pass） | 中 |
| provider 错误分类与重试 | 已补齐最小分类器 + retryable 接线 + jittered backoff；完整 fallback provider 链与多 key 冷却仍未做 | `error_classifier.py`（1300+ 行，`classify_api_error`/按 status/code/message 三层分类）；`retry_utils.py jittered_backoff` 去相关退避；循环内空回复触发 `_try_activate_fallback` | bullx 已覆盖 429/5xx/timeout/auth/overflow 的最小恢复动作；hermes 仍在 provider fallback 链和多 key 状态机上更厚 | 多 key/fallback 按需评估 | 低 |
| 并行工具批的安全门 | 仅按 per-tool `executionMode`（`types.ts:36`）；默认全并行（`agent.ts:240`），**无读写路径冲突检测** | `tool_dispatch_helpers.py:103 _should_parallelize_tool_batch`：fail-closed 白名单 + 路径重叠分析（`_paths_overlap`）+ `_NEVER_PARALLEL_TOOLS` | 同一 turn 里两个写同一文件子树的调用并行 → 互相踩；非白名单工具默认串行 | 思路可借：在 `executeToolCalls` 前加"同名写工具/同路径参数 → 强制串行"。但 bullx"按工具声明"是更简单的刻意取舍，未必要全套路径分析 | 中 |
| 重复/超量 tool_call 去抖 | **无**。`agent-loop.ts:396` 原样执行 assistant 给的每个 toolCall | `run_agent.py:3289 _deduplicate_tool_calls`（同 name+args 去重）、`:3242 _cap_delegate_task_calls`（截断超量并发子任务） | 模型一个 turn 重复发同一调用 / 超出并发上限；浪费 token 与副作用 | `_deduplicate_tool_calls` 逻辑极小（按 `(name, JSON args)` set 去重），可加进 `executeToolCalls` 入口 | 低 |
| 中断（interrupt）模型 | 单一 `AbortSignal`（`agent.ts:322 abort()`）。批内 `signal?.aborted` 后 `break`，但**并行批已 prepared 的任务仍会 `Promise.all` 跑完**（`agent-loop.ts:520`） | `run_agent.py:2287 interrupt()`：thread-scoped 信号 + 扇出到 ThreadPool worker tids + 传播到子 agent；循环顶 `:838` 检查 `_interrupt_requested` 立即 break | 已在飞的并行工具/子 agent 收不到中断、跑到自身 timeout；多 agent 共进程时中断串扰 | bullx 的 signal 模型本身够用（单进程单 abortController），thread-scope 不适用 TS。仅"并行批中断后不再 await 未启动项"值得修 | 低 |
| steering 注入与 role 交替 | `agent-loop.ts:184` 在下个 assistant 响应前把 pending 注入为独立 message（`PendingMessageQueue`，`agent.ts:131`）。注入点固定在 turn 边界 | `conversation_loop.py:907` pre-API steer drain：回扫最后一条 tool 消息，把 steer **拼到 tool result content 里**；找不到 tool 消息就退回队列 | steer 在 API 调用中途到达、且当前 turn 不再有 tool 批时会"永远等不到注入点"；注入成独立 user 会破坏 tool→user 的 role 交替 | bullx 注入成独立 message 在其 turn 模型下是合法的（不会插在 assistant+toolCall 与 toolResult 之间），属不同取舍，**非缺陷** | 低 |
| 消息文本提取 / bash 渲染 | `bullx.ts:26 textFromAgentMessage`、`messages.ts:48 bashExecutionToText` | hermes 散落在 `prompt_builder.py`/display，无单一对应 | — | bullx 这里更内聚，**领先** | — |
| skill 加载与 frontmatter 校验 | `skills.ts:49 loadSkills`（递归、ignore 文件、name/description 校验、diagnostics） | `agent/skill_utils.py`/`skill_bundles.py` | 二者都做了校验；bullx 的 `Result` + diagnostics 更结构化 | 持平/略领先 | — |
| session 树投影 + 压缩裁切 | `session.ts:13 buildSessionContext`（root→leaf 路径投影、compaction 后从 `firstKeptEntryId` 起重放） | `conversation_loop.py` 内联 hydrate + `context_compressor.py` | bullx 把它做成纯函数，**领先** | — | — |

### 重点可借鉴项

**① thinking-only assistant 剔除（Anthropic 兼容）**
若 bullx 接 Anthropic 系 provider，`_is_thinking_only_assistant`（`run_agent.py:3178`）的判定 + `drop_thinking_only_and_merge_users`（`agent_runtime_helpers.py:809`）值得并入 `convertToLlm`：当某 assistant 回合只有 thinking 块、无可见文本、无 toolCall 时，从 wire 副本整条丢弃（UI transcript 保留），避免 "final block cannot be thinking" 的 400。

### 结论
bullx 在这一层的落后**集中在"循环健壮性/失败恢复"，而非结构**——turn 编排、AgentMessage↔Message 边界、hook 体系、纯函数化的 session/skill 投影反而比 hermes 更干净、更可维护。本期已落地最高 ROI 的循环修复与 provider retry 基础（孤儿 tool-pair 修复、空回复 nudge、迭代预算+grace、错误分类器、jittered backoff）。下一期剩余项按 ROI：① thinking-only assistant 的 wire 剔除（接 Anthropic 系 provider 时必需）；其余（完整 fallback 链、并行写路径安全门、重复 tool_call 去抖、并行批中断后不 await 未启动项）按需推进。


---

## 5. 上下文压缩 / 压实 / 渲染

对照 bullx-agent（TS/Bun，pi-ai 内核 fork）与 hermes-agent（Python）在「上下文压实 / 渲染 / token 估算 / trajectory」上的实现。

**两边架构差异（先厘清，避免错位对照）**：
- bullx 是**事件溯源式**：PG 行（messages + llm_turns）是唯一真相；压实只追加一条 `summary` 行 + 一个 `firstKeptEntryId` 锚点，**不重写历史**；渲染时把行重建为 `AgentMessage[]`，microcompact 只改"模型可见视图"。压实三层：① 渲染期 microcompact（清空旧可重导 tool result，无 LLM）② preflight `shouldCompact` 阈值触发摘要 ③ provider 溢出重试再压。摘要走 pi-ai fork 的 `compact()`（cut-point + split-turn + 迭代更新）。
- hermes 有**两套压缩器**：(a) `trajectory_compressor.py`（离线/批量，HuggingFace **真 tokenizer**，from/value 格式，给训练数据用）；(b) `agent/context_compressor.py`（**在线运行时**，2109 行，是 bullx 压实的真正对照系）。在线侧用 rough 字符估算（无真 tokenizer），但围绕它堆了大量生产边界处理：图片 token、历史媒体剥离、真实用量 vs 预估去抖、摘要失败确定性兜底、孤儿 tool-pair 修复、防抖动、温度锚定等。

bullx 的核心机制（事件溯源 + 缓存稳定的 microcompact + cut-point/split-turn 摘要 + 溢出重试 + JSON 密度修正）是**扎实且有自己亮点**的；hermes 在「估算精度、失败兜底、多模态、防抖动、孤儿修复」几个维度处理了更多 edge case。

| 细粒度功能 | bullx 实现 | hermes 对应 | hermes 额外 edge case | 可借鉴 | 优先级 |
|---|---|---|---|---|---|
| token 估算精度 | 字符/4 启发（`compaction.ts:220` `estimateTokens`）；JSON 密度补半（`token-estimate.ts:13-37`）；有 usage 时用 provider `usageTokens + trailingTokens`（`compaction.ts:165-193`） | 在线侧 rough `(len+3)//4`（`model_metadata.py:1816`）；**批量侧用真 HF tokenizer**（`trajectory_compressor.py:464-480`） | 离线侧真 tokenizer 精确计；rough 用**ceil 除法**避免短串估成 0（`model_metadata.py:1819-1825`，多条短 tool result 会系统性低估） | ceil 除法防 0（bullx `Math.ceil` 已是 ceil，✅）；真 tokenizer 仅离线，在线无对应 | 低 |
| 工具 schema 计入 token | ❌ 触发估算只算 messages，**不算 tool 定义**（`runtime.ts:1293` 仅传 `rendered.messages`） | `estimate_request_tokens_rough(messages, system_prompt, tools)`（`model_metadata.py:1904-1924`）把 system + 50+ tool schema（可达 20-30K）计入 | 漏算 schema 会**触发太晚**，doomed call 才靠溢出重试兜底 | 高：触发估算应加 system+tools 字符 | 中 |
| 触发用量排除 reasoning token | ⚠️ `calculateContextTokens = totalTokens \|\| input+output+cacheRead+cacheWrite`（`compaction.ts:120`），**`output` 含 reasoning/completion**，思考模型会虚高 | 显式只用 `prompt_tokens` 触发（`context_compressor.py:686-695,735`；测试 `test_compression_trigger_excludes_reasoning.py` #12026） | 思考模型（completion 含大量 reasoning）会**过早压缩**：40k prompt+80k reasoning>100k 阈值误触发 | 高：触发只看 input+cacheRead+cacheWrite，剔除 output | 中 |
| 真实用量 vs 预估去抖 | ❌ 无：每次重渲染都重新估算触发 | `should_defer_preflight_to_real_usage`（`context_compressor.py:698-726`）：rough 高估 schema 时，若 provider 上轮真 `prompt_tokens` 证明能装下且增长 <5%，**跳过重复压缩** | 避免 rough 高估导致每轮反复压缩 | 中：bullx 也有 schema 高估风险（若采纳上条） | 低 |
| 图片/多模态 token 计数 | 已补齐：`token-estimate.ts` 先把 `data:image/...;base64` 文本替换为稳定占位，再按每张图固定成本计入；runtime 触发估算也使用同一路径 | 双常量：触发 `_IMAGE_TOKEN_COST=1500`（`model_metadata.py:1836`）；预算 `_IMAGE_TOKEN_ESTIMATE=1600`（`context_compressor.py:101`，对齐 Claude Code）；统计时**排除 base64 原始字符**（`_estimate_message_chars` `model_metadata.py:1871-1901`） | 已避免 1MB base64 被按原始字符估成 ~250K token；结构化 image block 仍由基础 estimator 处理 | 无待办 | — |
| 历史媒体剥离（防 body 超限） | 已补齐：`context-renderer.ts` 在模型视图中锚定最后一条带图 user 消息，之前的 image/data-url 替换为稳定占位，并记录 `historical_media_strip` patch；PG 原始轨迹不变 | `_strip_historical_media`（`context_compressor.py:343-398`）：锚定**最后一条带图 user 消息**，之前所有图换占位文本（移植 kilocode#9434） | 已对齐 hermes 的核心行为，避免旧截图每轮重复进入 provider body | 无待办 | — |
| 可重导 tool result 清理（microcompact） | ✅ **亮点**：`microcompact.ts` 清空旧 `web_search/web_extract`，字节稳定占位符（`MICROCOMPACT_CLEARED_TEXT`），幂等单调、不动 PG、保护 `clarify` 用户答案 | `_prune_old_tool_results`（`context_compressor.py:754-996`）：按 tool 名生成**信息化**摘要（`[terminal] ran npm test -> exit 0, 47 lines`）、MD5 去重相同 result、截断超大 tool_call args（保持合法 JSON）、剥多模态 | hermes 不是清空而是**降级为单行摘要**（保留可读信息）；去重相同文件多次 read；截断 50KB write_file args 否则下游每轮 400；token-budget 保护尾部而非固定条数 | 中：①清空可升级为单行摘要 ②args 截断 ③相同 result 去重 | 中 |
| 摘要锚定（active task 不丢） | 部分：split-turn 时额外摘要 turn 前缀（`compaction.ts:596-608,666-693`）；focus 经 `customInstructions` 注入 | `_ensure_last_user_message_in_tail`（`context_compressor.py:1756-1774`）：**强制最近 user 消息进 tail**（#10896）；摘要模板 `## Active Task` 逐字引用最近未完成输入；反向信号（stop/undo）覆盖旧任务 | bullx 靠 prompt 文字让模型"保留最新指令"，**无结构保证**最近 user 一定在保留区；hermes 用 cut-point 硬保证 + 模板强制字段 + 反向信号处理 | 中：cut-point 强制最近 user 进保留区 | 中 |
| 温度/日期锚定 | ❌ 无 | `_temporal_anchoring_rule`（`context_compressor.py:1280-1296`）：给摘要器当前日期，要求把已完成动作改写成"已于 YYYY-MM-DD 完成"的过去式 | 否则 resume 后把"email John"当**未完成指令重发**；防御性取日期，时钟失败不阻断压实 | 中：长任务/数字员工场景价值高 | 低 |
| 摘要失败回退 | 部分：`compact` 返回 `err`，上层 throw（`compression.ts:81`），threshold 路径 catch+log 继续（`runtime.ts:1306`）；溢出路径未 catch | 多级：① cooldown（`context_compressor.py:1240` 失败后 30/60/600s 不再试）② 摘要模型挂→**回退主模型立即重试**（`:1497-1529`）③ 仍失败→**确定性本地兜底摘要**（`_build_static_fallback_summary` `:1001-1188`，抽取 user asks/tool 动作/文件/错误）④ `abort_on_summary_failure` 决定丢中段还是冻结 | bullx 摘要失败=整次压实失败（threshold 下静默跳过、继续用未压上下文等溢出兜底）；hermes 分错误类型（404/503/timeout/JSONDecode/流断）差异化处理，且**绝不无摘要丢中段**——本地兜底保留延续锚点 | 高：①aux 模型失败回退主模型 ②确定性兜底摘要 | 高 |
| 压缩中途改上下文安全性（缓存边界） | ✅ **设计正确**：microcompact 字节稳定 + 幂等，"只在压实时改上下文"由 microcompact 注释明确（`microcompact.ts:6,33`）；摘要是 mid-conv 行不进缓存前缀 | `prompt_caching.py`：`system_and_3` 固定 4 breakpoint；温度锚定注释明确"摘要不在缓存前缀，日期不破坏缓存稳定"（`context_compressor.py:1252-1255`） | hermes 把缓存策略**独立成纯函数**（`apply_anthropic_cache_control`），breakpoint 放 system+最后 3 条；两边都遵守"改上下文集中在压实点"硬规则 | 低：bullx 字节稳定已达成同等保证（缓存交给 pi-ai） | 低 |
| 压缩后仍超窗的二次处理 | ✅ provider 溢出重试：`isContextOverflow`→`overflow_retry`→再 `compress(provider_context_overflow)`，循环至 `maxOverflowRetries`（`runtime.ts:1513-1526,1556-1568`） | ① `should_compress` 防抖动：连续 2 次省 <10% 则停（`context_compressor.py:728-748`）② `try_shrink_image_parts_in_messages` 图片超大时**重编码缩图**（`conversation_compression.py:617-777`，4MB/8000px 双限，不可缩则不重试）③ 413 测试 `test_413_compression.py` | bullx 溢出重试是次数循环但**无防抖动**：若每次只省 1-2 条会反复触发；hermes 有效性 <10% 即退避并提示 `/new`；且图片超大有独立缩图恢复路径 | 高：①防抖动退避 ②图片超大缩图恢复 | 中 |
| 孤儿 tool-call/result 修复 | 隐式：cut-point 不在 toolResult 上切（`compaction.ts:275-277` toolResult 不作 cut；`findTurnStartIndex`） | 显式三方：`_sanitize_tool_pairs`（删孤儿 result + 补 stub result，`context_compressor.py:1602-1660`）+ `_align_boundary_forward/backward`（`:1662-1709`） | bullx 靠"不在 tool 边界切"避免产生孤儿；hermes 额外**事后修复**——删无对应 call 的 result、给丢了 result 的 call 补 stub，保证 API 永不收到 mismatch ID | 中：bullx 边界对齐已规避，但跨摘要场景可加事后校验 | 低 |
| trajectory 可重放/导出 | ✅ **亮点**：`reconstructLlmTurnTrajectory`（`trajectory.ts:71-126`）从 refs 精确重建每个 LLM 请求（`exactLlmRequest`）；`message_override` patch 重放 microcompact 视图；lease 选择导出（`selectExportableGenerationLeases`） | 无直接对应（hermes 状态在 SQLite session，导出走 batch_runner/from-value） | bullx 的 ref-based 精确重放 + model-view patch 是更强的可审计性 | — | bullx 领先 |
| 摘要器安全（密钥/语言） | prompt 让保留逐字标识符（`compression.ts:26`）；无显式 redact | 摘要器 preamble 强制 `[REDACTED]` 密钥 + **输出再 redact**（`context_compressor.py:1274-1277,1433`）+ 用户原语言不翻译 + 内容过滤友好措辞 | bullx 摘要文本可能**回显密钥**（摘要模型忽略指令时无二次防护）；hermes 双层 redact | 中：摘要输出过 redact | 中 |
| 摘要模型可行性预检 | ❌ 无 | `check_compression_model_feasibility`（`conversation_compression.py:64-183`）：会话启动即检查 aux 模型上下文窗口 ≥ 主模型阈值，否则告警/自动下调阈值 | aux 模型窗口 < 待摘要内容会**摘要失败或严重截断**；hermes 启动期预警并自动校正 | 低：bullx 单模型角色配置（light）较少踩此坑 | 低 |

### 重点可借鉴项

**1. 触发估算计入 system+tools，并从用量中剔除 reasoning（最高 ROI，两处小改）**
bullx 当前触发判断有两个低估/虚高源：(a) 只算 `rendered.messages`，漏掉 system prompt 和 tool schema（`runtime.ts:1293`）——50+ 工具时 schema 可达 20-30K token，导致**该压时没压**，只能等 provider 溢出 503 才靠重试兜底（浪费一次 doomed call）；(b) `calculateContextTokens` 的 `output` 项含 reasoning（`compaction.ts:120`），思考模型会**过早压缩**。
hermes 落点：`model_metadata.py:1904` 把 system+tools 计入；`context_compressor.py:735` 触发只看 prompt 侧。
bullx 落点：`token-estimate.ts` 的 `estimateContextTokensJsonAware` 增加 tools/system 项；`runtime.ts:1293` 把 active tool 定义的字符数加进去：
```ts
// token-estimate.ts —— 触发侧加上 tool schema 与 system 的粗估
export function estimateTriggerTokens(messages: AgentMessage[], systemPrompt: string, tools: JsonValue[]): number {
  const sys = Math.ceil(systemPrompt.length / 4)
  const toolChars = JSON.stringify(tools).length
  return estimateContextTokensJsonAware(messages) + sys + Math.ceil(toolChars / 4)
}
```
并把 `calculateContextTokens` 的 trigger 用法改为 `input + cacheRead + cacheWrite`（排除 `output`），cut-point 内部估算保持不变（仅影响"何时"，安全地更保守）。

**2. 图片估算剥 base64 + 历史媒体剥离已补齐**
本期已新增 `media.ts`：估算侧把 `data:image/...;base64` 文本替换为稳定占位并按每张图固定成本计入；渲染侧在 `context-renderer.ts` 锚定最后一条带图 user 消息，把更早的 image/data-url 替换为稳定占位并记录 `historical_media_strip` patch。该改动只影响模型视图，PG 原始轨迹和 trajectory 重建真相不变。

**3. 摘要失败的两级兜底：aux 模型失败回退主模型 + 确定性本地摘要**
bullx 摘要失败=整次压实失败：threshold 路径静默 catch+log 继续用未压上下文（`runtime.ts:1306`），溢出路径直接 throw。在 aux（light）模型临时不可用 / 超时 / 返回非 JSON 时，上下文会**继续无界增长**直到 provider 硬拒。
hermes 落点：`context_compressor.py:1497-1529`（aux 模型 404/503/timeout/JSONDecode/流断 → 回退主模型立即重试一次）；`:1001-1188` 仍失败则 `_build_static_fallback_summary` 本地抽取最近 user asks / tool 动作 / 文件 / 错误，**绝不无摘要丢中段**。
bullx 落点：`compression.ts:72-81` 的 `compact` 调用外包一层：catch 后若 light≠primary，用 primary 重试一次；再失败则生成确定性兜底摘要（从 `messagesToSummarize` 抽 user 文本 + tool 名 + `extractFileOpsFromMessage` 已有的文件列表）写入 summary 行，而非让中段历史在下次渲染时静默消失。bullx 已有 `formatFileOperations`/`computeFileLists`，兜底摘要可直接复用。

**4. 压缩防抖动退避（避免溢出重试空转）**
bullx 溢出重试是纯次数循环（`runtime.ts:1517-1523`），若一次压实只省 1-2 条消息（例如保留区已占满预算），会反复触发压实+重试直到耗尽 `maxOverflowRetries`，每次都付出一次摘要 LLM 调用。
hermes 落点：`should_compress`（`context_compressor.py:728-748`）追踪 `_ineffective_compression_count`，连续 2 次省 <10% 即停并提示用户 `/new` 或 `/compress <topic>`。
bullx 落点：在 `AiAgentCompressionService.compress` 返回值里已有 `tokensBefore`，可记录"压实前后 token 差"，在 `runtime.ts` 的溢出/threshold 触发前检查上一次有效性 <10% 则跳过自动压实、转为面向用户的告警（"上下文无法有效压缩，建议开新会话"）。对"数字员工长跑"场景尤其重要——避免悄无声息地烧 token 空转。

**5. tool result 清理升级为信息化单行摘要 + 大 args 截断（microcompact 增强）**
bullx microcompact 把旧 `web_search/web_extract` 整体**清空**为固定占位（`microcompact.ts:8-9`）——字节稳定性极好，但丢光了可读线索（模型连"搜过什么"都不知道，可能重复搜）。且 bullx **不处理超大 tool_call arguments**：一次 `write` 50KB 内容的 assistant 消息会完整留在上下文里直到滑出窗口。
hermes 落点：`_prune_old_tool_results`（`context_compressor.py:858-893`）按 tool 名生成 `[terminal] ran npm test -> exit 0, 47 lines` 式摘要；`:902-996` 把 >500 char 的 tool_call args 在解析后的 JSON 内截断（保持合法 JSON，否则下游每轮 400）；MD5 去重相同 result。
bullx 落点：把 `MICROCOMPACT_CLEARED_TEXT` 从纯占位升级为"工具名 + 极简结果指纹"（仍需字节稳定：用 tool 名 + 结果长度，不含时间戳）；并在 `microcompact` 或 `context-renderer` 加一个对超大 toolCall args 的截断 pass。注意保持幂等 + 字节稳定以不破坏 prompt cache（bullx 现有约束正确，增强时需延续）。

### 结论

**整体：基本持平，各擅胜场。**

- **bullx 领先**：事件溯源架构（PG 行为真相、压实只追加不重写）带来的**可审计性与可重放性**显著强于 hermes——`trajectory.ts` 的 ref-based 精确 LLM 请求重建 + `message_override` patch 重放 microcompact 视图，hermes 无对应物。microcompact 的「字节稳定 + 幂等 + 不动持久层」设计干净正确，缓存稳定性保证到位。cut-point/split-turn 摘要 + 迭代更新 + 溢出重试构成完整闭环。JSON 密度修正是个务实的小亮点。

- **hermes 领先（均为「改变行为」的 edge case，非理论完备性）**：① **真实用量 vs 预估去抖**——避免 rough 高估导致每轮反复压缩；② **防抖动**——避免无效压缩空转烧 token；③ 温度锚定、孤儿 tool-pair 事后修复、摘要输出二次 redact、aux 模型可行性预检等生产细节。本期已补齐触发估算主缺口、摘要失败两级兜底、base64 估算与历史媒体剥离。

**建议优先级**：剩余可借鉴项以防抖动、tool result 信息化摘要、温度锚定、摘要二次 redact 为主，均低于本期已补齐的触发估算、摘要兜底与多模态 body-size 防护。所有后续改动仍应延续 bullx「只在压实/渲染点改上下文、microcompact 字节稳定」的既定约束，不要为兜底引入破坏缓存前缀的非确定性内容。


---

## 6. 运行时：生成生命周期 / 命令 / 运行登记

**对照范围**：一次 LLM 生成从触发→落库→出站的完整生命周期，以及 `/stop /new /steer /compress /retry`（hermes 还有 `/queue /status`）的命令分发、运行中中断、生成期间消息排队。

- bullx（改进对象，TS/Bun）：`app/src/ai-agent/runtime.ts`(2154 行)、`commands.ts`、`run-registry.ts`
- hermes（参照系，Python）：`run_agent.py`(AIAgent 中断/steer)、`gateway/run.py`(命令分发 20148 行)、`agent/tool_executor.py`(steer 注入点)、`agent/agent_runtime_helpers.py`、`tools/interrupt.py`、`agent/iteration_budget.py`、`cron/scheduler.py`

### 总体判断

两边在这一层的**抽象选择截然不同**，是同一组问题的两种合理解：

- **bullx = 数据库为真相源**。生成租约（`generation.lease_id`）写在 `AiAgentConversations` 行里；`generationCanCommit` 在提交前重读行做 fence；`commitAssistantResult` 在一个 `DB.transaction` + `SELECT ... FOR UPDATE` 里原子完成「写 assistant 行 + 写 outbox + 物化 followup/steering + 翻出下一代 lease」。出站幂等靠 `outboundKey`→`idempotencyKey` + `onConflictDoNothing`。重启恢复靠 `recoverExternalGatewayBinding` 从 DB 重新拉起在途生成、重建丢失的 outbox 行。**这套天然抗进程崩溃、抗并发触发**。
- **hermes = 进程内对象 + 单调代际号**。`_running_agents[session_key]` 持有活跃 `AIAgent`；fence 用进程内单调计数器 `_session_run_generation`（`_begin_session_run_generation` / `_is_session_run_current`），在结果回流时**丢弃过期代的结果**（`gateway/run.py:9583`）。中断是**线程级信号**（`tools/interrupt.py` 按 `thread_id` 记录），能穿透到并发 tool worker 线程、子 agent，甚至 `force_close_tcp_sockets` 直接 `shutdown(SHUT_RDWR)` 打断卡在网络 I/O 的 httpx。重启恢复靠 `session_store.mark_resume_pending` 落一个持久标记，下次同 session 来消息时 auto-resume。

**结论先行**：bullx 在「持久化正确性」（租约/fence/事务提交/出站幂等/DB 恢复）上设计**更完整、更强**，hermes 无对应等价物（它的 fence 与运行登记都是进程内的，崩溃即丢）。但 hermes 在「**运行中交互的颗粒度**」上踩中了 bullx 目前**确有的几个行为缺口**：steer 的真正 tool 间注入、`/queue` 的多轮 FIFO、命令在 agent 真正卡死时如何穿透守卫、中断信号到 tool/子 agent 的传播。下面只报**改变行为**的缺口，不为对齐而加复杂度。

### 对照表

| 维度 | bullx | hermes | 判定 |
|---|---|---|---|
| 生成租约 / fencing（并发触发） | DB 行级 `acquireGenerationLease` + 提交前 `generationCanCommit` 重读 fence + `FOR UPDATE` 事务提交（`runtime.ts:1266,1506,1787`）。**强**：抗进程崩溃、跨实例 | 进程内单调代际号，回流时丢弃过期结果（`gateway/run.py:9583,16544`）。仅单进程内有效 | **bullx 更强**，hermes 无持久等价物 |
| abort-and-wait 竞态 | `abortAndWait` 触发 abort 后 `Promise.race([waitForIdle, timeout(5s)])` **真正等待结算**（`run-registry.ts:38`）；lease fence 作权威兜底 | `interrupt()` 仅置信号**不等待**（`run_agent.py:2287`）；靠 `_drain_active_agents` 在 shutdown 时统一 drain，平时靠代际号丢弃 | **bullx 在线 abort 更干净**；hermes 平时不等待，但有信号穿透补强（见下） |
| 中断信号传播深度 | `registry.abort` 只 `agent.abort()` + `abortController.abort()`（`run-registry.ts:26`）。依赖 core Agent 内部把 signal 传到 tool | 中断**线程级 fan-out**：本线程 + 全部并发 tool worker tid + 全部子 agent + `force_close_tcp_sockets` 打断卡死 I/O（`run_agent.py:2287-2330`、`agent_runtime_helpers.py` force_close） | **hermes 处理了 bullx 没显式处理的 edge case**（卡在网络 I/O / 并发 tool 的中断） |
| tool 边界 steer vs 排队 | `/steer` 永远走「排队为下一轮」：`appendPendingSteering` 或物化新 user 消息再起新生成（`runtime.ts:1138`）。**没有真正的"本轮 tool 间注入"** | `/steer` 真注入：`steer()` 暂存→tool 批次结束后 `apply_pending_steer_to_tool_results` 追加到最后一个 `role:tool` 结果（`run_agent.py:2364`、`tool_executor.py:753,766,1366,1401`） | **hermes 有 bullx 缺失的能力**：本轮内 steer。bullx 文案"No tool boundary to steer"承认了这点 |
| retry 上一轮 | `retryLastExchange`：定位最后 assistant→标记其后所有消息 `transcript_effect=superseded`→删除已出站卡片→以同 trigger 起 `retry_generation`（`runtime.ts:1636`）。**保留审计痕迹** | `_handle_retry_command`：找最后 user 消息→**物理截断** transcript 到之前→重发（`gateway/run.py:11646`） | **bullx 更稳健**（软删除+审计+撤回出站）；hermes 简单截断会丢历史 |
| overflow retry（超窗→压缩→重试） | 双层：起跑前 `shouldCompact` 预检压缩；跑完若 `isContextOverflow` 则 `overflow_retry`→压缩→`overflowAttempts+1` 重起，有 `maxOverflowRetries` 预算（`runtime.ts:1276-1309,1513,1556`） | 仅本地模型有「context window 太小」提示（`run_agent.py:2645`）；未见「超窗→压缩→自动重试」闭环 | **bullx 明显更完整**，hermes 无等价 |
| 出站幂等（outbound key） | `outboundKey`→`idempotencyKeyFromOutboundKey`→outbox `onConflictDoNothing`；流式卡片成功则写 `status:'sent'` 防重复 post（`runtime.ts:1806,1858,1874`） | 出站走 adapter，无 DB outbox 去重层；幂等性弱 | **bullx 更强** |
| 重启后在途生成恢复 | `recoverExternalGatewayBinding`：从 DB `findRecoverableGenerations` 重起在途生成 + `rebuildMissingAssistantOutbox` 补发丢失出站（`runtime.ts:897,927`） | `mark_resume_pending` 持久标记 + 下次消息 auto-resume（`gateway/run.py:6539`）；**不自动续跑**，等用户下条消息触发 | **方式不同**：bullx 自动续跑，hermes 惰性等触发。bullx 更主动 |
| scheduled/programmatic turn 去重 | `existingAssistantForTrigger`：按 `trigger_message_id` 查已存在 assistant，命中即跳过（`runtime.ts:787,814`）。**幂等** | cron 侧 `_submit_with_guard` 进程内 `_running_job_ids` 防同 job 并发（`cron/scheduler.py:2157`）；非「按 trigger 去重」而是「同 job 不并发」 | **bullx 的 trigger 去重更精确**；hermes 是粗粒度的 in-flight 锁 |
| `/queue` 排队语义 | **无 `/queue` 命令**。生成期间的普通 addressed 消息走 `appendPendingFollowup`，提交时**全部合并**成 followup 链一次性翻成下一代（`runtime.ts:1005,1903`） | `/queue` 是显式命令：FIFO「slot + overflow」，**每个 item 产生独立一轮 agent turn，不合并**（`gateway/run.py:2862-2960,7834`） | **语义差异**：bullx 合并 followup（一轮消化多条）；hermes `/queue` 每条独立一轮。两者都合理，但 bullx 无"逐条独立轮次"选项 |
| 命令在 agent 阻塞时穿透守卫 | `/stop`：`cancelGeneration`(DB fence) + `abortAndWait` + `clarify.abort`（`runtime.ts:1128`）。但若 core Agent 真卡死，abortAndWait 仅等 5s 超时后**靠 fence 让结果作废**，进程内对象仍在 | `/stop` **硬杀**：`_interrupt_and_clear_session` 直接清 `_running_agents` 槽解锁 session，注释明说"soft interrupt 对真卡死无效，强清"（`gateway/run.py:7801-7811`）；`/approve /deny` 直连 approval handler 因 agent 阻塞在 `threading.Event`（`gateway/run.py:7917`） | **hermes 显式处理了"executor 真卡死"**：硬清槽 + 特定命令绕过中断路径直达。bullx 靠 fence 作废结果，但内存里的 run 对象不强清 |
| 无活动生成时的命令 | `/steer` 无活动生成→物化为 user 消息 + 起新生成（`runtime.ts:1152`）；`/retry`/`/compress` 检查 `isActiveGeneration` 拒绝或执行 | `/steer` 无 running agent→降级排队为下一轮（`gateway/run.py:7883,7900`）；命令普遍有 sentinel(`_AGENT_PENDING_SENTINEL`)态处理"agent 还没起来" | 都覆盖，bullx 更倾向"立即起新生成"，hermes 倾向"排队等下一轮" |
| 子 agent 保护 | 无子 agent 概念（单 agent 运行时） | `interrupt`→若父 agent 正驱动子 agent，把 busy-mode 从 `interrupt` 降级为 `queue`，避免会话级 followup 摧毁数分钟子 agent 工作（`gateway/run.py:3471`，#30170） | bullx **无对应**（架构无子 agent，非缺陷） |
| 迭代预算 | 由 core Agent 内部控制（runtime 层不显式管） | `IterationBudget` 线程安全 consume/refund，父 90 / 子 50，`execute_code` 轮次 refund（`agent/iteration_budget.py`） | 不同分层，非缺口 |

### 重点可借鉴项

> 取舍原则：bullx 的 DB 租约/fence/事务/恢复体系**已settled且更强，不relitigate**。下面只挑 hermes 确实补了 bullx **当前行为缺口**、且不破坏现有持久化模型的点。

#### 1.（中价值，行为缺口）`/steer` 真正的"本轮 tool 间注入"——bullx 目前完全没有

bullx 的 `/steer` 在活跃生成时只会 `appendPendingSteering`，**等本轮整个跑完**才把它翻成下一轮的 user 消息（`runtime.ts:1138-1164` + `commitAssistantResult` 的 steering 物化 `runtime.ts:1877`）。它自己的反馈文案 `'No tool boundary to steer; queued as next turn.'` 诚实地承认了缺口：用户想"在 agent 跑长 tool 链时插一句话纠偏"，bullx 做不到，只能等下一轮。

hermes 的做法值得借鉴：steer 暂存到一个带锁的 slot，在**每个 tool 结果落地后**立即 drain，追加到最后一个 `role:tool` 消息的 content 末尾（带明确 marker，让模型知道这是用户插话不是 tool 输出），**不插新消息、不破坏 role 交替**：

```python
# agent/agent_runtime_helpers.py:2339  apply_pending_steer_to_tool_results
steer_text = agent._drain_pending_steer()
...
# 找本批最后一个 role:tool 消息，把 steer marker 追加到它的 content
marker = format_steer_marker(steer_text)
messages[target_idx]["content"] = existing_content + marker
# 若本批无 tool 结果（被中断全跳过）→ 把 steer 放回，让上层 fallback 当下一轮 user 消息投递
```

调用点（`agent/tool_executor.py:753,766`）：**每个** tool 结果后 drain 一次（`num_tool_msgs=1`），批末再兜底一次。

**落点（bullx）**：bullx 用的是 `@earendil-works/pi-ai` 的 core `Agent`，runtime 层通过 `transformContext` 钩子（`runtime.ts:1450` → `transformGenerationContext`）已经能在每轮调用前注入消息（它现在用来塞 todo 快照）。可在该钩子里 drain 一个新增的 `pendingSteering` 内存 slot（与现有 DB `pending_steering` 分离，DB 那条留作"无活跃生成时的下一轮"语义），把 steer 文本作为 `createCustomMessage` 追加。这样 `acceptCommand` 的 steer 分支里 `isActiveGeneration` 为真时，除了写 DB 还往内存 slot 推一份，文案就能从"queued as next turn"升级为"本轮 tool 后送达"。**注意**：仅当目标是补这个交互缺口才做；它确实增加了一处内存/DB 双写，是有成本的取舍。

#### 2.（中价值，行为缺口）`/stop` 对"executor 真卡死"的硬路径 + 阻塞命令绕过

bullx `/stop` = `cancelGeneration`(DB fence) + `abortAndWait`(等 5s) + `clarify.abort`（`runtime.ts:1128-1136`）。正常路径很好。但如果 core `Agent` 因某 tool 真卡死（同步阻塞、卡在网络），`abortAndWait` 只能等 5s 超时返回，**`registry` 里的 run 对象不会被强制清除**——靠 lease fence 让其最终产物作废。功能上 fence 保证了正确性，但**内存里那条 run 会一直占着 `runs.set(conversationId)` 直到它自己 finally 跑到 `registry.delete`**；若它永不返回，该 conversation 的内存槽就泄漏了（后续同 conversation 的命令 `abort/abortAndWait` 仍指向这条僵尸 run）。

hermes 明确处理了这个 edge case（`gateway/run.py:7801`）：

```python
# /stop must hard-kill the session when an agent is running.
# A soft interrupt doesn't help when the agent is truly hung — the executor
# thread is blocked and never checks _interrupt_requested. Force-clean
# _running_agents so the session is unlocked and subsequent messages process.
await self._interrupt_and_clear_session(..., interrupt_reason=_INTERRUPT_REASON_STOP, ...)
```

`_interrupt_and_clear_session`（`gateway/run.py:16597`）= interrupt 信号 + **invalidate 代际号** + 消费丢弃 pending + **无条件 `_release_running_agent_state` 清槽**。另外 `/approve /deny` 因 agent 阻塞在 `threading.Event` 上、interrupt 信号无法解锁，**直连 approval handler**（`gateway/run.py:7917`）——这是"命令在 agent 阻塞时穿透守卫"的精确处理。

**落点（bullx）**：`run-registry.ts` 增一个 `forceDelete(conversationId)`（无视 leaseId 直接 `runs.delete` + `abortController.abort`），在 `/stop` 的 `abortAndWait` 超时分支调用，确保即使 run 永不结算也不泄漏内存槽。这与 bullx 的"fence 是权威"哲学一致——内存槽本就只是 abort 句柄，清掉它不影响正确性。**低成本、纯削减泄漏**，推荐。

#### 3.（按需，语义补充）`/queue`：逐条独立轮次的 FIFO

bullx 生成期间的 addressed 消息一律 `appendPendingFollowup`，提交时**一次性合并**成 followup 链全部翻成下一代（`runtime.ts:1005-1022` + `commitAssistantResult` 的 followups 循环 `runtime.ts:1903-1927`，所有 followup 拼进同一个 nextGeneration）。即"agent 在忙时来 3 条消息→下一轮一次性看到 3 条"。

hermes 额外提供 `/queue`：**每条 `/queue` 产生独立的一整轮 agent turn，FIFO，不合并**（`gateway/run.py:2862` 注释 + `7834` 处理）。实现是"单 slot + overflow 列表"，每轮 drain 后 `_promote_queued_event` 把 overflow 头提进 slot 供下一轮递归消化。

**判定**：这是**语义差异不是缺陷**——bullx 的合并语义对 IM 群聊更自然（连发消息当一组上下文）。仅当 bullx 想支持"把 N 个独立任务排成 N 轮顺序执行"才需要；当前 followup 合并已覆盖主流场景。**不建议为对齐而加**，记录差异即可。

#### 4.（低价值，参考）中断信号到并发 tool / 子进程的传播

bullx `registry.abort` 只调 `agent.abort()` + `abortController.abort(reason)`（`run-registry.ts:26-31`），中断能否传到正在执行的 tool 取决于 core `Agent` + tool 是否监听 `AbortSignal`。hermes 的 `tools/interrupt.py` 是线程级 registry，`interrupt()` 显式 fan-out 到全部并发 tool worker tid（`run_agent.py:2300-2320`）+ `force_close_tcp_sockets` 打断卡在 httpx 的请求。

**判定**：这是 Python 线程模型下的必需补偿（无 async cancellation）。bullx 在 Node 单线程 + AbortSignal 模型下，只要 tool 实现都 `await` 且透传 signal 就天然中断，**不需要等价机制**。仅当 bullx 出现"某 tool 同步阻塞 event loop 导致 abort 不生效"时才需关注（届时是 tool 实现问题，不是 runtime 缺口）。**公允记为：不同并发模型，非缺口**。

### 结论

- **bullx 在这一层的核心（DB 租约 / 提交前 fence / `FOR UPDATE` 事务原子提交 / 出站 `outboundKey` 幂等 / `recoverExternalGatewayBinding` 重启恢复 / overflow 压缩重试 / `existingAssistantForTrigger` trigger 去重 / retry 软删除审计）整体比 hermes 更完整、更强、更抗崩溃**。hermes 的 fence（代际号）与运行登记（`_running_agents`）都是**进程内、崩溃即丢**的，没有 bullx 这套持久化正确性骨架。这点必须公允肯定，不应为"对齐 hermes"而削弱。
- hermes **确实补中了 bullx 当前的几个交互行为缺口**，按价值排序值得借鉴：
  1. **`/steer` 本轮 tool 间注入**（缺口 1）——bullx 文案已自认做不到，hermes 的 `apply_pending_steer_to_tool_results` 给了干净的"追加到最后 tool 结果、不破坏 role 交替"范式。中价值、有成本。
  2. **`/stop` 对真卡死 run 的内存槽强清**（缺口 2）——`run-registry` 加 `forceDelete` 兜底，低成本纯削减内存泄漏，与"fence 权威"哲学一致，**最推荐**。
- 其余（`/queue` 逐条 FIFO、中断信号线程级传播、子 agent 保护、`mark_resume_pending` 惰性恢复）多为**语义差异或不同并发/架构模型的产物，非 bullx 缺陷**，记录差异即可，不建议为对齐而引入复杂度。


---

## 7. 会话持久化 / 每日重置 / ambient 群聊批处理 / 生命周期修订

### 简介

两边的会话模型是两种不同的工程范式，对照时必须先承认这点，否则会得出不公允的结论。

- **bullx（PG 行驱动 + generation 状态机）**：会话/消息是 `AiAgentConversations` / `AiAgentMessages` / `AiAgentLlmTurns` 三张 Postgres 表。并发与"谁能提交本轮生成"靠 `generation` JSONB 里的 **lease 状态机**（`lease_id` / `heartbeat_at` / `expires_at` / `max_expires_at` / `cancelled_at`）在 SQL 谓词层面做乐观并发控制（`conversation-service.ts:316-365`）。撤回/删除、每日重置、ambient 介入都是围绕这台状态机的操作。结构化程度明显高于 hermes。
- **hermes（SQLite 单写者 + WAL）**：`SessionDB`（`hermes_state.py:377`）是一张本地 SQLite，靠 `_execute_write` 的 `BEGIN IMMEDIATE` + 抖动重试做单写者串行化（`hermes_state.py:566-616`），用 `compression_locks` 表 + TTL 做压缩互斥（`hermes_state.py:1033-1093`）。它的强项不在并发模型，而在**成熟度细节**：FTS5 全文检索（含 CJK trigram 回退）、软删除 rewind、session 血缘链回放、跨平台 recall 的多分支兜底。

结论先行：bullx 的**并发/生命周期内核更干净**，hermes 在**检索、CJK、recall 兜底、配置-行为一致性**这些"被时间磨出来的边角"上更完整。下面只报会改变行为的差异。

### 对照表

| 维度 | bullx (TS/PG) | hermes (Python/SQLite) | 判定 |
|---|---|---|---|
| 会话存储 | PG 三表，UUIDv7 主键，JSONB generation/metadata | SQLite `sessions`/`messages`，autoincrement id | 各擅胜场 |
| 并发 append / "谁能提交" | generation lease + SQL 谓词 CAS（`conversation-service.ts:316-365`） | 单写者 `BEGIN IMMEDIATE`+抖动重试（`hermes_state.py:566-616`） | bullx 更结构化 |
| 每日重置（定时） | `dailyResetBoundary` + rollover 新会话（`daily-reset.ts:16-66`） | `_should_reset` daily/idle/both/none（`gateway/session.py:790-832`） | 见 §重点1 |
| 重置时有在途运行 | **取消 lease + abort 进程**（`daily-reset.ts:22-27`） | **永不重置有活动进程的会话**（`gateway/session.py:799-802`） | 哲学分歧，见 §重点1 |
| ambient 批窗/防抖 | 已补齐：保留滑动窗，同时用 `firstSeenAt + hardCapMs` 设置硬上限，避免持续消息流饿死 recognizer | 防抖窗 + **硬上限** `first_ts+hard_cap`（`base.py:3455-3463`） | 已对齐 |
| 多消息合并 | recognizer 取最近 12 条 ambient 拼 prompt（`ambient.ts:115-127`） | 同发送者 text 合并 + 照片 burst 合并（`base.py:3465-3515, 3967-3991`） | 见 §重点2/3 |
| ambient 是否"主动介入" | **是**，LLM recognizer 决策 intervene（`ambient.ts:111-218`） | 防抖只做"聚合后再处理"，无主动介入决策器 | bullx 独有能力 |
| 撤回/删除 → 修订 transcript | lease 取消 + 软标 `transcript_effect` + 发删除 intent（`lifecycle-revisions.ts:25-136`） | yuanbao recall_guard 三分支 + 轮询补偿（`yuanbao.py:1264-1469`） | 见 §重点4 |
| recall 命中"正在处理中"的消息 | 靠 `isLatestTrigger` 判定后取消生成（`lifecycle-revisions.ts:85-112`） | 专门 Branch C：合成中断事件 + 延迟轮询补刀（`yuanbao.py:1336-1407`） | 见 §重点4 |
| recall 找不到精确 id | 精确 id 未命中时追加 introspection note，避免静默丢弃；内容匹配回退因 bullx 强制 provider refs 暂不需要 | id 命中 → **内容匹配回退** → 追加 system note（`yuanbao.py:1435-1469`） | 已覆盖 system note 兜底 |
| FTS 全文检索 | **无对应**（仅按 createdAt/id 排序取回） | FTS5 + CJK trigram + LIKE 短词回退（`hermes_state.py:2863-3173`） | 见 §重点3 |
| FTS 查询注入防护 | 不适用 | `_sanitize_fts5_query` 6 步消毒（`hermes_state.py:2775-2830`） | hermes 独有 |
| 软删除/回退历史 | `transcript_effect` 标记，rendered 视图过滤（`conversation-service.ts:258-265`） | `active=0` 软删 + `rewind_count`，可 include_inactive（`hermes_state.py:2605-2714`） | 思路一致 |
| 会话血缘回放 | rollover 写 `previous_conversation_id`，**但 render 不跨代** | `include_ancestors` 沿 `parent_session_id` 回放 + 去重（`hermes_state.py:2477-2599`） | 见 §结论 |
| FTS5 不可用降级 | 不适用 | 探测失败 → 关 FTS + 一次性告警（`hermes_state.py:465-481`） | hermes 独有 |
| WAL/网络盘降级 | PG 无此问题 | WAL 失败回退 DELETE 日志模式（`hermes_state.py:54-57`） | hermes 独有 |
| 配置-行为一致性 | `ambient.freshnessMs`、`dailyReset.retryMinutes` 死配置已删除，不保留兼容别名 | 配置项基本都有消费点 | 已清理 |

### 重点可借鉴项

#### 重点1 ——「重置撞上在途运行」是哲学分歧，建议显式确认而非照抄

bullx 每日重置遇到带 lease 的活跃会话时，**主动取消 lease 并 abort 进程**再 rollover：

```ts
// daily-reset.ts:22-28
if (conversation.generation.lease_id) {
  await this.conversations.cancelGeneration(conversation.id, 'daily_reset')
  this.registry.abort(conversation.id, 'daily_reset')
}
return this.conversations.rolloverConversation(route, 'daily_reset')
```

hermes 的选择正好相反——**有活动后台进程的会话永不被重置/清理**（reset、expire、prune 三处都先问 `has_active_processes_fn`）：

```python
# gateway/session.py:799-802  （_should_reset 开头；_is_expired 与 prune_* 同款守卫）
if self._has_active_processes_fn:
    session_key = self._generate_session_key(source)
    if self._has_active_processes_fn(session_key):
        return None  # 跳过重置
```

两者都自洽：bullx 因为有 lease fence + transcript_effect，**敢于打断**——被打断的那轮在 commit 处会因 lease 失配而无法落库，语义干净；hermes 没有这层 fence，所以选择**保守等待**，避免砍掉一个正在跑长任务的会话。这不是 bug，是各自并发模型推导出的必然策略。**落点**：不需要改 bullx 行为，但建议在 `daily-reset.ts` 顶部补一句注释，说明"打断在途运行是安全的，因为 lease 在 commit 处 fence + 整段 suffix 会被标 transcript_effect"，否则后人会把它误读成"每日重置会丢数据"。这是把已 settle 的 tradeoff 写清楚，不是 relitigate。

#### 重点3 ——跨会话检索完全缺失；如产品需要"搜历史"，FTS5 的 CJK 处理可直接借设计

bullx 取消息只有"按会话按时间序拉回"（`conversation-service.ts:252-275`、`ambient.ts:115-126`），**没有任何跨会话全文检索**。hermes 把它做成了一等公民，而且 CJK 处理非常成熟，对一个中文为主的部署尤其有价值：

```python
# hermes_state.py — 三条检索路径并存
#  1) 主路径 FTS5 BM25（messages_fts，unicode61 分词）
#  2) CJK 子串：messages_fts_trigram（trigram 分词，解决 unicode61 不切中文词的问题）
#  3) 极短 CJK 查询：LIKE 回退（trigram 对 1-2 字查询召回差）
# 见 _contains_cjk / _count_cjk (2843-2861) 决定走哪条；search_messages (2863-3173)
```

而且查询注入防护是真做过功的——`_sanitize_fts5_query`（`hermes_state.py:2775-2830`）6 步把 `"`、`():+{}^`、裸 `AND/OR/NOT`、`chat-send`/`P2.2` 这类带连字符/点号的词都正确处理，避免 `OperationalError`。**落点**：bullx 若要做历史检索，**不要照搬 SQLite FTS5**——PG 原生 `to_tsvector`/`websearch_to_tsquery` 更强，且 `websearch_to_tsquery` 自带查询消毒，省掉 hermes 整个 `_sanitize_fts5_query`。可借鉴的是 hermes 的**三层 CJK 策略**：PG 侧用 `pg_trgm` GIN 索引（对应 hermes 的 trigram 表）兜底中文子串，主路径用 `to_tsvector('simple', ...)`。这是设计借鉴，不是代码借鉴。注意：这是"新增能力"，按 CLAUDE.md「Prefer deletion over addition」，**只在确有跨会话搜索的产品需求时才做**，否则记为已知空白即可。

#### 重点4 ——recall 撞上「正在处理中」的消息：hermes 有专门的中断+补偿，bullx 的判定更脆

bullx 判断"被撤回的是不是当前正在生成的那条"靠 `isLatestTrigger`（三个条件的或/与组合），命中才取消生成：

```ts
// lifecycle-revisions.ts:80-112
const laterAddressedUser = rendered.slice(targetIndex + 1).some(r => r.role==='user' && r.kind==='normal')
const assistantForTarget = rendered.some(r => r.role==='assistant'
  && stringFromPath(r.metadata,['generation','trigger_message_id']) === target.id)
const isLatestTrigger = target.role==='user' && !laterAddressedUser
  && (conversation.generation.trigger_message_id===target.id || assistantForTarget)
if (!isLatestTrigger) { /* 只追加 introspection note */ }
else { await cancelGeneration(...); registry.abort(...); /* 标 transcript_effect + 发删除 intent */ }
```

hermes 走得更彻底：Branch C 检测到撤回的正是 `_processing_msg_ids[sk]`，会**合成一条强指令的内部中断事件**塞进 pending 让当前轮立刻收尾，并因为"中断时被撤回内容可能还没落库"而**调度一个延迟轮询任务**（最多 30×0.5s）等内容出现再补刀 redact：

```python
# gateway/platforms/yuanbao.py:1368-1371 + 1386-1403
# 中断后内容是 *之后* 才被持久化的 → 排一个延迟 redact
for _ in range(30):
    await asyncio.sleep(0.5)
    transcript = store.load_transcript(sid)
    for entry in transcript:
        if entry.get("role")=="user" and entry.get("content")==recalled_text:
            entry["content"] = cls._REDACTED; store.rewrite_transcript(...); return
```

差异本质：bullx 的 transcript_effect 是**提交时**统一打标，配合 lease fence，理论上不存在"内容已落库但没被标记"的窗口——所以**不需要** hermes 那个轮询补偿。这点 bullx 其实更优雅。**但有一个真实薄弱点**：`isLatestTrigger` 依赖 `rendered` 视图里能看到对应 assistant 的 `generation.trigger_message_id`，若该 assistant 还处于 `generating`/未落库状态（正是 recall 最容易撞上的时刻），`assistantForTarget` 会是 false，且 `conversation.generation.trigger_message_id===target.id` 是唯一兜底。**落点**：在 `lifecycle-revisions.ts:85-88` 的 `isLatestTrigger` 里，**显式把"当前活跃 lease 的 trigger_message_id 命中"作为最高优先信号**（即使 rendered 里还看不到 assistant），避免 recall 撞上"刚 ack、assistant 尚未入库"的竞态窗口落到"只追加 note 不取消生成"的错误分支。

#### 重点5 ——recall 精确 id 未命中时的兜底已补齐

bullx 入站时给 user/ambient 消息写入 `provider_refs.message_ids`，精确匹配命中率结构性高于 hermes；对"撤回了一条从未进过 transcript 的消息"这类未命中场景，当前 `lifecycle-revisions.ts` 已追加 `kind:'introspection'` 的提示消息，避免撤回事件被无声丢弃。因此 hermes 的内容匹配回退不需要照搬，system note 兜底也不再列为待办。

### 结论

- **内核对比**：bullx 的会话/并发内核（generation lease 状态机 + transcript_effect 软标 + rollover 显式血缘）比 hermes 的 SQLite 单写者**更结构化、更可推理**，多数生命周期边角（撤回打断、重置 fence、压缩可提交性）天然更干净，**不应为了"对齐 hermes"而倒退**。重点1/4 都印证这点。
- **真正该补的行为缺失（按优先级）**：
  1. **重点4 — `isLatestTrigger` 显式优先活跃 lease 的 trigger_message_id**：堵住"刚 ack、assistant 未入库"的 recall 竞态窗口。
  2. **跨会话检索 / 历史血缘回放**：是否需要取决于产品是否需要跨天记忆，不默认实现。
- **明确的「无对应」/已知空白**：bullx **无跨会话 FTS**（重点3）；bullx render **不跨 generation 回放历史**（rollover 后新会话从空起步，仅靠 `previous_conversation_id` 留痕，对照 hermes 的 `include_ancestors` 血缘回放）。两者是否要补取决于产品是否需要"跨天/跨会话记忆"，当前按 PG 行驱动 + 每日重置的设定，这是**有意的边界**而非缺陷，记录在案即可，不建议默认实现。
- **hermes 专属、bullx 用 PG 后天然不需要的**：WAL/网络盘降级（`hermes_state.py:54-57`）、FTS5 探测降级（`465-481`）、`BEGIN IMMEDIATE`+抖动重试（`566-616`）——这些是 SQLite 单写者范式的并发/部署补丁，PG + lease 模型不存在对应问题，**无需借鉴**。


---

## 8. Clarify 反问子系统

**对照范围**：向用户提问/选择题、交互卡片、阻塞等待回答（含超时心跳、群聊门禁、卡片锁、parked 生成、会话边界中止），以及 hermes 额外拥有的 **secret 掩码输入 / sudo 提权确认** 这类 bullx 缺失的交互原语。

### 简介

两边的核心机制高度同源（bullx 注释里也直说"mirrors hermes' clarify_gateway"）：clarify 工具在 `execute` 内**阻塞**，回答经带外（out-of-band）消息进来，由一个进程内 registry 解析 promise/Event。进程重启都丢弃 pending（靠恢复重问）。

但两边的**分层哲学不同**，导致 edge case 覆盖位置不同：

- **bullx**：把卡片协议（首响应锁定、responder scope、free-text 兜底、locked 状态）**声明式地塞进 `BullXInteractiveOutput` 结构**（`choice-prompt.ts`），由渠道插件统一渲染/落实。registry 设计偏细：`tryReserve` 同步占位防并发、`roomGate` 反向索引做群聊门禁、超时 + 心跳双定时器、`extendGenerationCeiling` 保住 run ceiling。
- **hermes**：clarify 原语（`clarify_gateway.py`）只管 Event + 超时轮询；**所有 UI/锁定/鉴权逻辑下沉到每个平台 adapter**（如 `telegram.py` 的 `send_clarify` + callback handler 各自实现按钮锁、授权门、已解析提示）。代价是每个渠道重复实现，收益是 clarify 原语本身极薄。
- hermes 把"问用户"拆成 **5 个并列原语**：clarify（开放/选择题）、approval（危险命令审批 once/session/always/deny）、slash_confirm（昂贵 slash 命令确认）、**secret（掩码密钥录入，不进模型）**、**sudo（提权密码）**。bullx 目前只有 clarify 一种。

### 对照表

| 维度 / Edge case | bullx | hermes | 判定 |
|---|---|---|---|
| 阻塞等待机制 | promise + registry resolve（`clarify-tool.ts:150`） | `threading.Event` + 轮询（`clarify_gateway.py:103`） | 等价 |
| 超时 | 600s 默认（`clarify-tool.ts:11,151`） | 600s（gateway，`clarify_gateway.py:245`）/ 120s（CLI/TUI，`callbacks.py:26`） | 等价（hermes CLI 更短） |
| 等待时心跳 / 防 watchdog 误杀 | `setInterval` 每 1s `touchGenerationHeartbeat`（`clarify-tool.ts:155`） | 1s 切片轮询 `touch_activity_if_due`（`clarify_gateway.py:129-132`） | 等价（动机相同，注释都点名 watchdog） |
| 保住 run ceiling | `extendGenerationCeiling(timeout+60s)`（`clarify-tool.ts:146`） | 无显式 ceiling 概念（靠 activity touch） | bullx 多一层 |
| 并发 clarify 防重 | `tryReserve` 同步占位，第二个立即抛错（`clarify-registry.ts:49`、`clarify-tool.ts:114`） | FIFO `_session_index`，多个可并存、取最旧（`clarify_gateway.py:165`） | **设计取向不同**（bullx 严格单飞；hermes 允许排队） |
| 群聊自由文本门禁（谁能答） | `roomGate` 路由 + 卡片 `responderScope:'any_room_member'`（`clarify-registry.ts:42`、`choice-prompt.ts:46`） | 文本拦截按 session_key（`run.py:7640`）；**按钮点击有 `_is_callback_user_authorized`**（`telegram.py:3446`） | **取向不同**（见下） |
| 交互卡片首次点击锁定 | 声明式 `policy.firstResponseWins` + `state.status:'answered'`（`choice-prompt.ts:46-53`） | adapter 手动：pop state + `edit_message_text(reply_markup=None)`（`telegram.py:3513,3526`） | 等价（bullx 声明式，hermes 命令式） |
| 自由文本 → 选项映射 | `mapAnswer`：数字/精确文本/原样（`clarify-format.ts:28`） | 数字/文本由 adapter+intercept 处理；选项文本回查 `_entries`（`telegram.py:3499`） | 大致等价（bullx 抽成纯函数更干净） |
| 不支持卡片的渠道回退 | `cardCapable` 分支 → 纯文本编号 prompt（`clarify-tool.ts:128`、`clarify-format.ts:7`） | adapter 各自渲染编号列表 + 文本 intercept（`clarify_gateway.py:27-30`） | 等价 |
| /stop 中止 | `abort()` → `{kind:'aborted'}`（`clarify-registry.ts:103`） | `clear_session` 空串 sentinel（`clarify_gateway.py:203`、`run.py:18534`） | 等价 |
| /new 取代 | `abort('superseded')`（`clarify-registry.ts:103`） | 同上 `clear_session`（不区分原因） | bullx 区分 aborted/superseded 更细 |
| 答案校验 | choices 裁剪 ≤4、trim、空过滤（`clarify-tool.ts:103`、`clarify_tool.py` 同形） | 同形（`clarify_tool.py:48-55`） | 等价 |
| 投递失败兜底 | （未显式处理 enqueue 失败 → 释放 reservation 后抛错，`clarify-tool.ts:209`） | send 失败 → `clear_session` + sentinel "[could not be delivered]"（`run.py:18250`） | hermes 更明确（见缺口①） |
| **secret/掩码输入（密码类）** | **无对应** | `set_secret_capture_callback` + `secret.request/respond`，`PasswordProcessor` 掩码，存 `.env` **不进模型**（`skills_tool.py:174,378`、`server.py:2236,5619`、`cli.py:14383`、`callbacks.py:66`） | **bullx 缺失**（见重点项 1） |
| **sudo 提权密码确认** | **无对应** | `set_sudo_password_callback` + `sudo.request/respond`，thread-local per turn（`server.py:2234,5614`、`run.py:4622`） | **bullx 缺失**（见重点项 2） |
| 危险命令审批（once/session/always） | 无对应（bullx 工具审批走别处，不在 clarify 子系统） | `approval.py` 完整原语 + 平台按钮（`telegram.py:2682`） | 不同子系统，仅记 |

### 重点可借鉴项

#### 1. secret/掩码输入：把"录密钥"做成独立交互原语，且承诺"绝不进模型"

这是 bullx clarify 子系统**最实质的缺口**。hermes 在 skill 缺少凭据时，不是用 clarify 让模型问密钥（那样密钥会进对话历史/被模型看到），而是用一条**独立的、掩码的、绕过模型的**录入通道：

- TUI 侧：`server.py:2236` 注册 `secret_cb(env_var, prompt, metadata)` → 阻塞 `secret.request` → 用户在 `secret.respond` 回填 → 直接 `save_env_value_secure(env_var, val)` 写盘。
- CLI 侧：`prompt_for_secret` 用 `PasswordProcessor()`（`cli.py:62,14383`）或 `masked_secret_prompt`（`callbacks.py:79`）做**字符掩码**，注释明写 *"The secret is stored in ~/.hermes/.env and never exposed to the model"*（`callbacks.py:70-71`）。
- 返回**结构化结果**而非裸字符串，模型只看到成功与否：

```python
# hermes tui_gateway/server.py:2240
val = _block("secret.request", sid, pl)
if not val:
    return {"success": True, "stored_as": env_var, "validated": False,
            "skipped": True, "message": "skipped"}
return {**save_env_value_secure(env_var, val), "skipped": False, "message": "ok"}
```

**落点**：bullx 若计划支持 plugin/skill 凭据录入（很可能需要，因为它也是 plugin 架构），应在 clarify 子系统旁**新增 `secret-prompt` 交互类型**，复用现有 registry/outbox/卡片骨架，但：(a) 卡片侧新增 `response.type:'secret'`（输入掩码、`responderScope` 限发起人）；(b) 回答**不写入 tool result 文本**、不进 `userResponse`，只回 `{ stored: true }`；(c) 值经 `aeadEncrypt()`（项目已有，见 CLAUDE.md）落库或写入 binding secret。`clarify-format.ts` 的 `renderClarifyPrompt` 当前会把答案明文回显进 prompt，secret 路径必须另走一条不回显的渲染。这是行为正确性问题，不是锦上添花。

#### 2. sudo 提权确认：把"密码型确认"与"选择型 clarify"分开

hermes 的 sudo 是又一条独立通道（`server.py:2234` `set_sudo_password_callback` → `sudo.request`/`sudo.respond`，`server.py:5614` 走 `password` 字段）。关键细节是它**thread-local per turn**（`run.py:4622` 注释：sudo 回调是 thread-local，避免终端 sudo prompt 落到 `/dev/tty`）。

**落点**：bullx 当前没有交互式提权。若未来终端/命令工具需要 sudo，**不要复用 clarify**（clarify 把答案明文回显且进模型），而应仿 secret 通道做 `sudo-prompt`：掩码、限发起人、答案不进模型、且**绑定到具体 run/turn**（bullx 已有 `leaseId`，比 hermes 的 thread-local 更干净，直接用 leaseId 作用域即可）。可作为重点项 1 的同款基础设施的第二个消费者。

#### 3. 投递失败的显式兜底（bullx 当前隐式）

hermes 在 clarify 卡片**发不出去**时主动清场并返回可读 sentinel，让模型改走默认而非干等到超时：

```python
# hermes gateway/run.py:18250
if not send_ok:
    _clarify_mod.clear_session(session_key or "")
    return "[clarify prompt could not be delivered]"
```

bullx 的 `clarify-tool.ts:208-211` 在 `enqueuePending` 抛错时会 `releaseReservation` 后 re-throw，但**注意**：成功 enqueue 到 outbox ≠ 成功送达渠道。若 outbox drain 后渠道侧投递失败（插件返回错误），bullx 目前没有把"投递失败"反馈回 parked promise 的路径——模型只能等满 600s 超时。

**落点**：在 outbox 投递结果回流处，对 `askedOutboundKey` 对应的 clarify entry 做一次"投递失败 → `resolveByConversation(convId, {kind:'timeout'})` 或新增 `{kind:'undeliverable'}`"。这是改变行为的缺口（10 分钟干等 vs 立即兜底），但仅当 bullx 渠道投递存在"成功入队后仍失败"的真实场景时才值得做——属于"omission inside the chosen design"，建议核实渠道投递语义后再决定。

#### 4. 按钮鉴权与"已解析"竞态的显式提示（hermes 在 adapter 层，bullx 在协议层）

hermes 在 Telegram 按钮回调里做了三件 bullx 靠协议字段表达、但**未必每个渠道插件都落实**的事：
- 未授权点击 → `"⛔ You are not authorized to answer this prompt."`（`telegram.py:3453`）
- 卡片已被解析（state 已 pop）→ `"This prompt has already been resolved."`（`telegram.py:3458`）
- 解析后**移除按钮 + 回显答主**（`telegram.py:3513,3523-3527`）

bullx 用 `policy.firstResponseWins` + `responderScope:'any_room_member'` + `state.status:'answered'`（`choice-prompt.ts:46-53`）把这些**声明**给插件，干净得多。**借鉴方向反过来**：这是 bullx 的优势，但要确保**渠道插件 SDK 契约**真的强制实现"首响应后锁按钮 + 拒绝越权点击 + 已解析回执"，否则声明式策略沦为空头支票。建议在插件一致性测试里加这三条断言（对应 hermes adapter 已手测的行为）。

#### 5. 自由文本 → 选项映射抽成纯函数（bullx 已做得更好，建议保持并补强）

bullx 的 `mapAnswer`（`clarify-format.ts:28`）把"数字 / 精确选项文本 / 原样自由文本"抽成无依赖纯函数并单测，比 hermes 散落在 adapter + intercept（`telegram.py:3499` 回查 `_entries`、`run.py:7649` 文本拦截）干净。**这是 bullx 领先项，无需借鉴**。唯一可补：hermes 的文本 intercept 显式**跳过 `/` 开头**（视为 slash 命令而非答案，`run.py:7649`），bullx 的群聊文本回答门禁逻辑（在 external-gateway handler，本次未读到）应确认同样不把 `/stop`、`/new` 误当 clarify 答案——否则用户想中止却被吞成答案。建议核实 bullx 群聊 intercept 是否有等价的 slash-skip 守卫。

### 结论

核心阻塞/超时/心跳机制两边等价，bullx 注释也明确以 hermes 为蓝本。bullx 在**几处反而更细**：`tryReserve` 严格单飞、`roomGate` 群聊门禁、aborted/superseded 区分、`extendGenerationCeiling` 保 ceiling、`mapAnswer` 纯函数化、卡片策略声明式（首响应锁/responder scope/locked 状态）——这些都公允地优于 hermes 散落 adapter 的实现。

**真正的缺口集中在"交互类型的数量"**：hermes 有 **secret 掩码录入**（重点项 1，绕过模型、字符掩码、结构化回包）和 **sudo 提权密码**（重点项 2，thread-local per turn），bullx 两者皆**无对应**。这不是 clarify 做得不好，而是 bullx 把"问用户"窄化成了一种类型；一旦 plugin/skill 需要凭据或命令需要提权，用 clarify 顶替会把密钥/密码明文塞进模型上下文——属于**会改变行为的安全相关缺失**，应优先补 secret 通道（sudo 可复用同款基础设施）。

次要缺口两条，均属"chosen design 内的 omission"、需先核实再动：投递失败兜底（重点项 3，避免 10 分钟干等）、群聊文本 intercept 的 slash-skip 守卫（重点项 5，避免把 `/stop` 吞成答案）。其余（按钮锁/鉴权回执）bullx 协议层已表达，借鉴方向是**加插件一致性测试**确保声明被落实，而非改 clarify 本身。


---

## 9. Computer 工具（终端 / 进程 / 文件 / 补丁）

bullx 的 Computer 工具是一套薄封装：`command`/`terminal`/`interactive_terminal`/`process`/`read_file`/`patch` 全部把脏活（执行、超时、kill、worker 文件 IO、tmux）下沉给 `@agentbull/bullx-computer` worker，TS 侧只做参数校验、输出截断、V4A 解析和 LCS diff。hermes 把同样的责任放在 `tools/*.py` 进程内，因此积累了大量"模型生成的脏输入/脏环境"的 edge-case 处理。补丁 fuzzy 匹配、行尾/BOM 保存与 ANSI 清理已于本期补齐，剩余明显差距集中在后台进程 notify-on-complete/watch、大输出落盘等可观测性与输出预算细节。反过来，bullx 的 `interactive_terminal`（tmux 可恢复会话）在 hermes 里**无对应**，是 bullx 领先项。

> 边界说明：bullx 把"执行/超时/kill/进程组"委托给 worker，hermes 把它放在 `environments/local.py` 等后端。这两者是同一层的不同实现，**不是 bullx 工具层的缺失**——下表只在"行为会被模型观察到、且 bullx 工具层能改"的地方标记落后；纯属 worker/后端实现的差异（如 SIGTERM→SIGKILL 进程组升级）单独说明、不计入工具层缺失。

| 细粒度功能 | bullx 实现 | hermes 对应 | hermes 额外考虑的 edge case | 可借鉴的代码/思路 | 优先级 |
|---|---|---|---|---|---|
| 大输出截断 | `format.ts:8` `truncateOutput` head40%/tail60%，硬上限 50K 字符，超出直接丢中段 | `terminal_tool.py:2334-2343` 同样 40/60，`tool_output_limits.py` 可配置 | hermes 还有**三级预算**：单工具截断→`tool_result_storage.py:122` 把超阈值结果**落盘到 sandbox** 返回 preview+路径→`enforce_turn_budget` 跨同一 turn 所有工具结果聚合落盘（200K）。bullx 只有第一级，大输出被永久丢弃，模型无法再取回 | 见"重点 1"。把 `maybe_persist_tool_result` 的"落盘+preview+路径"思路加到 `format.ts`/各工具，用 `read_file` 取回 | 高 |
| ANSI 清理 | 已补齐：`truncateOutput` 入口先 `stripAnsi`，清理 CSI/OSC/DCS 等终端控制序列后再截断 | `ansi_strip.py:35` `strip_ansi` 全 ECMA-48（CSI/OSC/DCS/8-bit C1），带 fast-path | 已覆盖 `command`/`terminal`/`process`/`interactive_terminal capture` 等返回给模型的输出视图，避免 ANSI 转义污染上下文 | 无待办 | — |
| 二进制文件检测 | `format.ts:40` `looksBinary`：仅查前 8KB 有无 NUL 字节 | `binary_extensions.py` 60+ 扩展名白名单 + `file_operations.py:748` 内容启发式（前 1000 字符 >30% 非打印） | hermes **扩展名优先**（无 IO），能拦住无 NUL 的二进制（已 gzip 的 `.docx`/`.pdf` 边界、UTF-16 文本等）；还单独把图片导向 vision 工具。bullx 的纯 NUL 检测会漏掉很多 | 见"重点 3"。加 `binary-extensions.ts` 常量 + 扩展名预检，叠加现有 NUL 检测 | 中 |
| 编码处理 | `buffer.toString('utf-8')` 无条件解码（`read-file-tool.ts:53`、`patch-tool.ts:73,136`） | 同样按 UTF-8，但 **BOM 显式处理** | hermes `file_operations.py:130` `_strip_bom`：读时剥离 leading U+FEFF（否则模型看到幽灵字符、补丁首行 exact match 失配），写回时按磁盘原文**恢复 BOM**。bullx 读到 BOM 会原样塞给模型，且 patch 的 `indexOf(hunk.search)` 会因首行带 BOM 而失配 | 见"重点 4"（与行尾合并）。`read-file-tool`/`patch-tool` 加 BOM strip/restore | 中 |
| 行尾差异（CRLF） | 已补齐：patch 写回前记录 UTF-8 BOM 与主导行尾，替换后恢复原格式 | `file_operations.py:893` `_detect_file_line_ending` + `_normalize_line_endings`，patch 后按磁盘原行尾整体归一（`patch_replace` `:1427-1429`） | 已对齐 hermes 的核心行为，避免 CRLF 文件被静默转 LF | 无待办 | — |
| 补丁 fuzzy 匹配 | 已补齐：replace 与 V4A hunk 均走 `findUniqueFuzzyMatch`，支持精确、trim、行边界 trim 与水平空白归一，并拒绝 ambiguous fuzzy match | `fuzzy_match.py:50` `fuzzy_find_and_replace`，**8 级策略链**（exact→line_trimmed→whitespace_normalized→indentation_flexible→escape_normalized→trimmed_boundary→unicode_normalized→block_anchor→context_aware） | bullx 已覆盖最常见的 whitespace drift 与唯一性保护；hermes 更深的 reindent/escape/context-aware 策略可按失败样本再补 | 按需增强，不列为当前缺口 | — |
| 补丁上下文不唯一 | replace 与 V4A hunk fuzzy 均要求唯一匹配；addition-only hunk 的 context_hint 校验仍可作为后续增强 | `patch_parser.py:240` `_validate_operations` 两阶段：addition-only hunk 也校验 context_hint 唯一性（`:269-281`），多 hunk 按顺序在模拟内容上推进验证 | 主要误改风险已由唯一 fuzzy 匹配收敛；纯 addition-only 锚点仍可细化 | 低优先级增强 | 低 |
| 补丁失配反馈 | 仅 `Could not find old_string`（`patch-tool.ts:78`），无"你是不是想改这里" | `fuzzy_match.py:780` `find_closest_lines`（SequenceMatcher 锚定首行，>0.3 相似度，带行号上下文）+ `format_no_match_hint`；`file_tools.py:1256` **连续失败计数**，#3 起升级提示"停止重试，改 write_file" | bullx 失配后模型只能瞎猜重试。hermes 给出最相近代码段 + 连续失败熔断，显著减少 patch 死循环 | 移植 `find_closest_lines` 到 `diff.ts`，patch 失配时附 hint | 中 |
| read-before-edit 强制 | **无**。`patch`/replace 直接读盘改盘，不检查模型是否先 `read_file`，也不检查并发 stale | `file_state.py` 进程内 `FileStateRegistry`：`check_stale`（写前查 sibling subagent 写过/mtime 漂移/从未读）、`record_read`/`note_write`、per-path 锁；`file_tools.py:1043` write/patch 包在 `lock_path` 内并附 `_warning` | bullx 多 agent 并发改同一文件无任何 stale 警告；模型可凭空 write 覆盖。hermes 三类 stale 警告 + per-path 串行化 read→modify→write | 见"重点（结论段）"。bullx 当前单 worker 串行，优先级中；若上多 agent 需补 | 中 |
| 后台进程生命周期 | `terminal(background=true)→process(poll/log/wait/kill)`。`backgroundIds` 仅本 run 内存集合（`context.ts`）。**无 stdin 写入**（工具描述明说不支持） | `process_registry.py` 完整 `ProcessSession`：PTY/Popen/sandbox 三态 kill、`write_stdin`/`submit_stdin`/`close_stdin`（`:1202-1254`） | bullx 后台进程**不能喂 stdin**（交互式安装/确认无法继续，只能 kill）。hermes 支持 PTY/pipe 双路 stdin + EOF。bullx 用 `interactive_terminal`(tmux) 绕开，但纯后台进程无此能力 | 若 worker 暴露 stdin API，给 `process` 加 `write`/`submit`/`close` action | 中 |
| notify-on-complete | **无**。后台进程跑完不通知，模型必须主动 `poll`/`wait`，长任务易"失明" | `process_registry.py:115` `notify_on_complete` + `completion_queue` + `drain_notifications`，`format_process_notification` 生成 `[IMPORTANT]` 注入下一 turn | bullx 无任何完成回调；hermes 工具描述（`terminal_tool.py:2557`）甚至强制长任务必须 `notify_on_complete=true`。这是长跑工作流可观测性的核心差距 | 需 run loop 支持事件注入，超工具层范围；记为架构缺口 | 中 |
| watch-on-pattern | **无** | `process_registry.py:191` `_check_watch_patterns`：输出匹配模式即通知，带 per-session 速率限制 + 连续 strike 熔断 + 全局熔断（`:319`），超限自动降级 notify_on_complete | bullx 完全没有"输出出现 X 就叫我"能力。hermes 这套带防刷屏熔断颇为成熟 | 同上，依赖事件注入；低优先 | 低 |
| 超时与 kill | 委托 worker：`timeoutMs` 传下去（`command-tool.ts:37`）。`process.wait` TS 侧用 `AbortSignal.timeout` 做 wait 上限（`process-tool.ts:35`） | `local.py:569` `_kill_process` 进程组 `SIGTERM→等1s→SIGKILL→等2s`，`os.setsid` 建组防孤儿；`wait` 把请求超时 clamp 到配置上限并回 note（`process_registry.py:1078`） | hermes 在**后端**做了优雅进程组 kill（防孤儿孙进程）；bullx 这层交给 worker——**属实现位置差异，非工具层缺失**。但 hermes `wait` 的"clamp 超时并明确告知"值得借鉴到 `process-tool.ts` | `process` 的 `wait` 超时 clamp + `timeout_note` 反馈 | 低 |
| 并发终端会话 | `terminal` 单一持久 shell（worker 维护 cwd/export）；`interactive_terminal` 多 tmux 会话并存（`list/start/send/capture/kill`） | hermes 单持久 shell；后台多进程靠 `process_registry`；**无 tmux/可恢复 TTY 会话** | **bullx 领先**：`interactive_terminal`（`interactive-terminal-tool.ts`）提供命名、可 list/capture/恢复的 tmux 会话，专供 Codex/Claude/REPL/installer 这类 TUI；hermes `mini_swe_runner.py` 明确"避免交互式命令"，无对应抽象 | 无（bullx 已更好） | — |
| 工作目录处理 | `splitWritePath`（`format.ts:49`）把 `/workspace/...` 锚定到 workspace；相对路径用传入 cwd | `file_tools.py:797` `_expand_path` 展开 `~`/`~user`（且**防 `~user` 注入**，`:823` 校验用户名），`_path_resolution_warning` 警告 worktree-cwd 漂移 | hermes 处理 `~` 展开 + worktree 路径漂移警告（相对路径解析到 terminal cwd 之外时提示）。bullx 不展开 `~`、无漂移警告 | `~` 展开可加到 `splitWritePath`；漂移警告依赖 worker 暴露真实 cwd | 低 |
| 路径穿越防护 | **无**。所有路径直传 worker，无 `..` 校验 | `path_security.py:37` `has_traversal_component` + `:15` `validate_within_dir`；`file_tools.py:1137` V4A patch header 的路径**专门拒绝 `..`**（patch 内容更易被注入污染） | bullx 完全依赖 worker 沙箱边界做隔离。hermes 在工具层对**来自补丁内容**的路径（攻击者可影响：skill/web extract/prompt injection）额外拦 `..`。bullx 若 worker 是强沙箱可接受；否则 V4A header 路径是个注入面 | 若 worker 非强隔离，给 V4A header 加 `..` 拦截（`v4a.ts` 解析后校验） | 低 |
| 原子写入 | 委托 worker `fs.writeFiles`（`patch-tool.ts:94,149`），TS 侧不保证原子 | `file_operations.py:839` `_atomic_write`：同目录 temp + `mv` 同盘原子 rename，保留原 mode，trap 清理 temp，stdin 喂内容免 ARG_MAX；patch 后**回读校验**写入确实落盘（`:1436-1466`） | hermes 防"写一半崩溃留半截文件"+ 防静默写失败（回读比对，含行尾归一）。bullx 取决于 worker `writeFiles` 是否原子 + 是否回读 | 若 worker 非原子，可加 patch 后回读校验（`patch-tool.ts` Phase 2 后） | 低 |

### 重点可借鉴项

**1. 大输出落盘（三级预算）— 放 `format.ts` + 各工具 execute**

bullx 现在大输出被 `truncateOutput` 永久丢中段，模型无法取回。hermes 的核心思路（`tool_result_storage.py:122`）：超阈值就写进 worker 文件、上下文只留 preview + 路径，模型用 `read_file` 取回全文。

```ts
// format.ts 新增（worker 落盘版）
export async function persistOrTruncate(
  computer: Computer, text: string, toolCallId: string,
  opts: { signal?: AbortSignal; threshold?: number } = {}
): Promise<string> {
  const threshold = opts.threshold ?? MAX_OUTPUT_CHARS
  if (text.length <= threshold) return text
  const path = `/tmp/bullx-results/${toolCallId}.txt`
  try {
    await computer.fs.writeFiles([{ path: `bullx-results/${toolCallId}.txt`, content: text }], { cwd: '/tmp', signal: opts.signal })
    const preview = text.slice(0, DEFAULT_PREVIEW)
    return `<persisted-output>\nFull output (${text.length} chars) saved to: ${path}\nRead it with read_file(offset,limit).\n\nPreview:\n${preview}\n...\n</persisted-output>`
  } catch {
    return truncateOutput(text) // 落盘失败回退现有截断
  }
}
```
落点：`command-tool.ts:40`、`terminal-tool.ts:64`、`process-tool.ts` 的 `log`/`wait` 把 `truncateOutput(...)` 换成 `await persistOrTruncate(...)`。

**2. ANSI 清理已补齐**

`format.ts` 已新增 `stripAnsi`，`truncateOutput` 会先清理 CSI/OSC/DCS 等终端控制序列再截断。该入口被 `command`、`terminal`、`process`、`interactive_terminal capture` 等模型可见输出路径复用，避免 ANSI 转义污染上下文或被模型写回文件。

**3. 二进制扩展名预检 — `read-file-tool.ts`**

```ts
// 新增 binary-extensions.ts（照搬 hermes 集合），read-file-tool.ts 在 readFileToBuffer 前先查：
if (hasBinaryExtension(params.path)) {
  return { content: [{ type: 'text', text: `Cannot read binary file '${params.path}'.` }],
           details: { path: params.path, found: true, totalLines: 0, truncated: false } }
}
```
叠加在现有 `looksBinary`(NUL) 之上，扩展名优先省一次 worker 读 + 拦住无 NUL 的二进制。

### 结论

bullx Computer 工具层在补丁鲁棒性和输出清理上已补齐本期最高风险项：fuzzy 唯一匹配、CRLF/BOM 保存与 ANSI 清理。剩余落后集中在**大输出/后台进程可观测性（落盘取回、notify-on-complete）**和更细的失配提示/二进制预检。唯一**领先**项是 `interactive_terminal`（tmux 可恢复会话），hermes 无对应。其余进程组 kill、原子写、路径穿越等差异，多数源于 bullx 把脏活下沉给 worker 的架构选择——只要 worker 守住沙箱与原子性即可接受，**不属于工具层缺失**。


---

## 10. 杂项工具（todo / build / check-back-later）+ Web 搜索/抓取子系统

> **定位校正（见 §一「定位决定威胁模型」与 §三 A1）**：本节关于 SSRF 的「高优先」定级是按个人助理威胁模型写的，对 bullx **应下调**——作为企业数字员工，可达内网/私网是**预期取舍**，不应默认封禁通用私网。真正值得评估的只剩**云元数据(IMDS)凭证窃取**与**提示注入出站外泄**那一窄条，且多属基础设施层（IMDSv2 / NetworkPolicy / 出站代理）。下文 hermes 的 `url_safety.py` 细节仍准确，但请按此重读其对 bullx 的适用性。

## 简介

这一组覆盖两个区域：**会话内杂项工具**（todo 计划表、`buildTool` 工厂、check_back_later 延后自唤醒）和 **Web 搜索/抓取子系统**（provider 链 + HTTP 重试 + HTML→markdown 抽取）。

总体结论先行：

- **todo**：bullx 与 hermes 是 1:1 同源实现（连描述文案、`MAX_TODO_*` 常量、dedupe-by-id、merge 语义、post-compression 重注入都逐字一致）。功能对等，无遗漏。
- **build-tool**：任务假设「agent 自建工具/技能脚手架」**不成立**。bullx `build-tool.ts` 只是一个 33 行的 *内部工厂 helper* `buildTool()`，给 `AgentTool` 填 fail-closed 默认值（`executionMode='sequential'`、`isReadOnly=false`、`isDestructive=true`），不是 agent 可见工具。它对应的不是 hermes 的 `skill_manager_tool.py`（那是真正的技能创作工具，1043 行，属另一对照组）；它对应 hermes 的 `tools/registry.py` 注册路径——而 hermes registry **完全不跟踪 read-only/destructive 元数据**（0 匹配）。这一点 bullx 反而更完善。
- **check_back_later**：bullx **是 durable 的**，且比 hermes 更强。bullx 用 Postgres 行（`schedulerStore.createCheckback`）+ 租约式领取（`claimDueCheckback`，`status='running'` + `leaseExpiresAt` + `FOR UPDATE SKIP LOCKED`），重启后由启动 `catchup` tick（`runtime.ts:76`）领取过期行。hermes 的 cron 是单进程 JSON 文件（`cron/jobs.py`）+ 一次性 grace 窗口，无多实例租约。两边都能扛重启，bullx 在并发/多实例上更稳。
- **Web 子系统**：**这是真正的差距所在。** bullx 的 web 抓取/搜索**完全没有 SSRF/私网防护、没有 website 黑名单、没有 URL 内嵌密钥拦截**。hermes 有完整的 `url_safety.py`（402 行）+ `website_policy.py`（282 行）+ 重定向后二次校验。**高优先级安全缺口。**

---

## 细粒度对照表

| 细粒度功能 | bullx 实现 | hermes 对应 | hermes 额外 edge case | 可借鉴 | 优先级 |
|---|---|---|---|---|---|
| **SSRF / 私网 IP 屏蔽** | **无对应**（`grep ssrf\|169.254\|is_private` 在 `app/src` 命中 0；`webfetch.ts` 直接 `fetch(url)` 无任何 IP 校验，`webfetch.ts:66`） | `url_safety.py` `is_safe_url` / `async_is_safe_url`（`url_safety.py:314,396`） | DNS 解析后逐 IP 校验 private/loopback/link-local/reserved/multicast/CGNAT(100.64/10)；云元数据 IP 永久封禁（169.254.169.254 / ECS / Azure IMDS / 阿里云 100.100.100.200，`url_safety.py:95`）；IPv4-mapped IPv6（`::ffff:x`）单独处理（`url_safety.py:195`）；DNS 失败 **fail-closed**（`url_safety.py:348`）；可配置 `allow_private_urls` 但元数据始终封 | **是（强烈）** | **高** |
| **URL 内嵌密钥拦截（外泄防护）** | 无对应 | `web_extract_tool` 入口（`web_tools.py:920-938`） | percent-decode 后用 `_PREFIX_RE`（sk-/token 前缀）扫描，命中即拒，防把 API key 塞进 URL 外泄 | 是 | 中 |
| **website 黑名单 / robots 类策略** | 无对应（无任何域名黑名单；也无 robots.txt 解析） | `website_policy.py` `check_website_access`（`website_policy.py:232`） | 用户可配 `security.website_blocklist`；通配子域 `*.x` 用 fnmatch、父域 `host.endswith(".x")`；配置错误 **fail-open**（typo 不致瘫痪所有 web 工具，`website_policy.py:259`）；共享黑名单文件可缺失跳过 | 视需求 | 低 |
| **重定向后二次 SSRF/策略校验（TOCTOU 缓解）** | 无对应（`webfetch.ts:69` `redirect:'follow'`，落地 URL 不再校验） | firecrawl provider per-URL 循环（`firecrawl/provider.py:526-548`）；`url_safety.py` 文档第 21 行说明 httpx event-hook 在 vision/gateway 重新校验每跳 | 抓取后取 `sourceURL`（最终落地 URL）再跑一次 `check_website_access`，命中即丢弃内容 | 是 | 中 |
| **provider 回退链** | 已补齐：显式 preferred provider 未注册/不支持/不可用时 fail-fast 并返回 provider id + 原因；未配置时仍按内置优先级→插件兜底 | `web_search_registry._resolve`：显式 config（**忽略 available 以给精确报错**）→ 单 provider 捷径 → legacy 优先级 walk（firecrawl→parallel→tavily→exa→searxng→brave-free→ddgs，`web_search_registry.py:122,133`） | hermes：显式配置即使 `is_available()=False` 也返回它，让用户看到「X_API_KEY 未设置」精确报错而非静默换源；`_is_available_safe` 包住 provider 抛错不影响整链（`web_search_registry.py:173`） | 无待办；Jina 有界扇出另列 | — |
| **缺 key 跳过 / available 判定** | `available()` 读 config 判 key；exa/parallel 缺 key 不可用，jina/webfetch 永远可用（`exa.ts:37`、`webfetch.ts:137`） | `is_available()`（不得发网络请求，注册期/每次 `hermes tools` 都调，`web_search_provider.py:91`） | hermes 在 ABC 里硬性约束 `is_available` 不能发网络（性能契约）；buggy provider 的 available 异常被吞（同上 `_is_available_safe`） | 否（bullx 已对等） | — |
| **限频 / 重试 / 退避** | `http.ts requestJson`：408/425/429/5xx 判 retryable，`withRetry` 3 次 abort-aware 退避（`http.ts:6,22`）；webfetch 单独 3 次重试（`webfetch.ts:119`） | LLM 摘要侧有指数退避（`web_tools.py:537,549`，cap 60s）；抓取侧重试在各 provider SDK 内 | hermes 抓取侧自身重试薄（依赖 Firecrawl 等托管），但 bullx 这里 **更完整**（统一 retryable 分类 + 408/425 也算） | 否（bullx 更好） | — |
| **超时** | `DEFAULT_TIMEOUT_MS=30s`（`http.ts:4`）；webfetch `FETCH_TIMEOUT_MS=30s`（`webfetch.ts:7`）；均 `createCombinedAbortSignal` 合并外部 signal | firecrawl 每 URL `asyncio.wait_for(..., 60)`（`firecrawl/provider.py:492`） | 两边都有；hermes 60s/URL 偏宽 | 否 | — |
| **响应体大小上限** | webfetch `MAX_RESPONSE_BYTES=5MB`（先看 content-length 再看实际 body 双重校验，`webfetch.ts:9,82,96`） | `web_tools.py`：`MAX_CONTENT_SIZE=2M chars` 超则直接拒，`MAX_OUTPUT_SIZE=5000` 硬截（`web_tools.py:367-376`） | 两边都有，策略不同；bullx 在 bytes 层防御（更早），hermes 在 chars 层 | 否（各有侧重） | — |
| **内容截断** | webfetch `MAX_CONTENT_CHARS=50000` + `…[truncated]`（`webfetch.ts:8,51`） | `web_tools.py` 多处 `[... truncated ...]`（`web_tools.py:635,695`），且优先走 LLM 摘要再截 | hermes 有 LLM 摘要压缩管线（抽取后 chunk→summarize→synthesize），bullx 是裸截断 | 视需求（重量级） | 低 |
| **二进制扩展名跳过** | 无对应（webfetch 靠 content-type 判 `isTextual`，`webfetch.ts:86`） | `binary_extensions.py` `has_binary_extension`（纯字符串，`binary_extensions.py:37`） | hermes 有 ~80 个扩展名 frozenset，用于 file_tools/diff（**注意：web 抽取侧并不用它**，主要在 file 工具）；bullx 的 content-type 判定其实覆盖了 web 抽取场景 | 否（场景不同） | — |
| **content-type 守门** | webfetch：非 textual（html/text/json/xml/空）直接报错；`looksLikeHtml` 嗅探（`webfetch.ts:46,85-93`） | 各 provider SDK 内部处理 | bullx 这里 **更细**（显式白名单 + 嗅探） | 否（bullx 更好） | — |
| **HTML→markdown 抽取质量** | `@mdream/js htmlToMarkdown({origin, clean:true})`；title 单独正则解析 + 实体解码（`webfetch.ts:30,102`）；注释承认 mdream 无正文隔离 | 走 Firecrawl/Jina 等托管抽取（含正文隔离），无本地 HTML 解析 | hermes 把抽取质量外包给 Firecrawl（有 readability/正文提取）；bullx 本地 mdream 质量略弱但零依赖、可兜底 | 否（取舍不同） | — |
| **搜索结果去重** | **无对应**（`web-search-tool.ts` 直接透传 provider 结果，无跨结果去重，`web-search-tool.ts:44`） | 搜索侧也基本透传（`web_tools.py:871` 直接 `provider.search`），无显式 dedup | 双方都无搜索结果 URL 去重；hermes 保留 `position` 字段但不去重 | 否（两边都缺，非 bullx 独有） | 低 |
| **抽取结果按 URL 对齐 / 部分失败** | exa 用 `normalizeUrl` 把结果/statuses 按 URL map 回原始 URL，缺失填 error（`exa.ts:67-78`）；webfetch/jina 每 URL 独立 try（`webfetch.ts:111`、`jina.ts:23`） | provider 返回 per-URL dict，含可选 `error`；SSRF 被拦的 URL 单独构造 error 结果再 merge 回（`web_tools.py:962-968,1042-1044`） | 两边都做了部分失败容错；hermes 把 SSRF-blocked 也作为一条 error 结果回给模型（可见性好） | 部分（SSRF error 结果回传模式可借） | 低 |
| **并发扇出控制** | webfetch `all(..., 3)` 限并发 3，避免对同主机 5 连发（`webfetch.ts:143`）；jina 是裸 `Promise.all`（无限并发，`jina.ts:40`） | firecrawl 是串行 per-URL for 循环（`firecrawl/provider.py:455`） | bullx webfetch 有界扇出做得好；但 **jina provider 漏了**（5 URL 并发打 r.jina.ai） | 否（但注意 jina 不一致） | 低 |
| **UA 轮换 / 反爬** | 按域 6h 缓存采样 desktop UA（`webfetch.ts:21`） | 无对应（托管 provider 自己处理） | bullx 独有，hermes 不需要（外包） | 否（bullx 特性） | — |
| **跨 provider URL 归一** | `normalizeUrl`（trim + 去尾斜杠，`http.ts:61`） | provider 内部各自处理 | 对等 | 否 | — |
| **todo merge 语义** | dedupe-by-id（保留最后一次、原位置）；merge 只更新 LLM 提供的字段；rebuild 保序去重；`MAX_TODO_ITEMS=256` / `MAX_TODO_CONTENT_CHARS=4000` 截断（`todo-tool.ts:80-114`） | **逐字同源**（`todo_tool.py:49-96`，常量、marker、文案全一致） | 无差异 | 否（已 1:1） | — |
| **todo 压缩后重注入** | `formatActiveSnapshot` 只注入 pending/in_progress（`todo-tool.ts:127`） | `format_for_injection` 同逻辑、同 marker（`todo_tool.py:106-138`） | 无差异 | 否 | — |
| **check_back_later durable（重启存活）** | **是**：Postgres 行 + 租约领取 + 启动 catchup（`store.ts:23,51`、`runtime.ts:76`） | JSON 文件 cron + 一次性 grace（`cron/jobs.py:317,426`） | hermes 一次性任务有 `ONESHOT_GRACE_SECONDS` + `_compute_grace_seconds`（按周期半值，clamp 120s~2h）防错过时 fast-forward；bullx 用 `lte(dueAt,now)` 天然领取过期行无需 fast-forward 逻辑 | 否（bullx 更强） | — |
| **check_back_later 互斥 after/at** | `.refine(Boolean(after) !== Boolean(at))` 强制恰好一个（`check-back-later-tool.ts:24`） | cronjob `schedule` 单字段（`30m` / ISO / cron 表达式），不区分 | bullx 语义更清晰（after 相对 / at 绝对 + 时区） | 否（bullx 更好） | — |
| **多实例并发领取** | `FOR UPDATE SKIP LOCKED` + 乐观更新 where 复查租约（`store.ts:66,79-87`） | 进程内 `threading.Lock`（`cron/jobs.py:41`，单进程） | bullx 支持多实例水平扩展，hermes 单进程 | 否（bullx 更强） | — |

---

## 重点可借鉴项

### 1.（高）补 SSRF / 私网 IP 防护 —— bullx 的最大安全缺口

bullx `webfetch.ts:66` 直接 `fetch(url, { redirect:'follow' })`，对 URL 不做任何 IP 解析校验。这意味着一个被注入的 prompt 或恶意页面可以让 agent 抓取 `http://169.254.169.254/latest/meta-data/iam/...`（云实例凭证）、`http://localhost:6379`（内网 Redis）、`http://192.168.x.x` 等。`web_extract` 是 agent 可直接调用的工具（`web-extract-tool.ts`），URL 完全来自模型，**这是教科书级 SSRF 面**。

hermes 的防护值得直接移植（`url_safety.py:314`）：

```python
# hermes url_safety.py — 核心思路
def is_safe_url(url):
    hostname = urlparse(url).hostname
    if hostname in _BLOCKED_HOSTNAMES:        # metadata.google.internal 永久封
        return False
    addr_info = socket.getaddrinfo(hostname, None, ...)  # 解析所有 A/AAAA
    for ... sockaddr in addr_info:
        ip = ipaddress.ip_address(sockaddr[0])
        if ip in _ALWAYS_BLOCKED_IPS: return False        # 169.254.169.254 等
        if _is_blocked_ip(ip): return False  # private/loopback/link-local/CGNAT
    return True   # DNS 失败则 fail-closed
```

**落点（bullx）**：新建 `app/src/ai-agent/web/url-safety.ts`，导出 `isSafeUrl(url): Promise<boolean>`。在 `webfetch.ts` 的 `fetchOne`（`webfetch.ts:111`，解析出 `domain` 后）先调一次；并在 `web-extract-tool.ts` 的 `execute` 里对每个 URL 预过滤，被拦的 URL 返回 `{ url, error: 'blocked: private/internal address' }`（沿用 hermes `web_tools.py:962-968` 的「拦截也作为一条 error 结果回传」模式，模型可见）。

TS 实现要点（对应 hermes 的坑）：
- 用 Node `dns.promises.lookup(host, { all: true })` 拿全部 IP；逐个用 `node:net`/手写判 private（`10/8`、`172.16/12`、`192.168/16`、`127/8`、`169.254/16`、`::1`、`fc00::/7`、`fe80::/10`、CGNAT `100.64/10`）。
- 云元数据 IP（`169.254.169.254`、`169.254.170.2`、`169.254.169.253`、阿里云 `100.100.100.200`、`fd00:ec2::254`）做**永久封禁集合**，即使提供 `allow_private_urls` 开关也封（hermes `url_safety.py:95` 明确这点）。
- **fail-closed**：DNS 解析失败、scheme 非 http(s)、解析异常 → 一律拦截（`url_safety.py:348,389`）。
- 注意 IPv4-mapped IPv6（`::ffff:169.254.169.254`），单独还原成内嵌 IPv4 再判（`url_safety.py:195`）——这是最容易漏的绕过点。
- bullx `webfetch.ts:69` 用 `redirect:'follow'`，落地 URL 不再校验 → **重定向 SSRF 绕过**。要么改成手动跟随重定向逐跳校验，要么至少对最终 `response.url` 再校验一次（参考 hermes firecrawl `provider.py:526` 对 `sourceURL` 二次 `check_website_access`）。

> 注意 hermes 自己也承认 DNS rebinding(TOCTOU) 在 pre-flight 层无法根治（`url_safety.py:15-19`），需要连接级校验或 egress 代理。bullx 落地到 pre-flight + 重定向二次校验即可覆盖 95% 现实威胁，**不必过度工程化**到 egress proxy。

### 2.（中）URL 内嵌密钥外泄拦截 —— 低成本高收益

`web_extract` 的 URL 来自模型，模型可能把上文出现过的 API key 拼进 query string 外泄。hermes 在抽取入口做了拦截（`web_tools.py:920-938`）：percent-decode 后用密钥前缀正则扫 URL，命中即拒。

**落点**：bullx 已有 `@agentbull/bullx-native-addons` 与凭证体系；在 `web-extract-tool.ts` 的 `execute` 开头对每个 URL 跑一次「已知密钥前缀 / 配置中的 secret 值」扫描（decode 后），命中则该 URL 返回 error。代码量极小（一个正则 + `decodeURIComponent`），与 SSRF 过滤放同一个预检函数里即可。

### 3.（中）provider 回退链：显式配置时「带病返回」以给精确报错

bullx `registry.select()`（`registry.ts:47`）在 preferred 不可用时**静默跳到下一个**。hermes 的取舍不同（`web_search_registry.py:181-197`）：**用户显式配置的 backend 即使 `is_available()=False` 也返回它**，让 dispatcher 抛出「`EXA_API_KEY` 未设置」这种精确错误，而不是悄悄换到另一个 provider（用户会困惑「我明明配了 exa 怎么用了 webfetch」）。

**落点**：`registry.ts` 的 `select`，当 `preferredId` 命中已注册但 `available()=false` 时，不要继续 fallback，而是抛带 providerId 的 `WebProviderError`（提示「provider X 已配置但缺 key」）。仅限「显式配置」路径这么做；未配置时的可用性 walk 保持原样。这是一个行为正确性改进，不是新功能。

### 4.（低）jina provider 并发扇出不一致

bullx webfetch 已用 `all(..., 3)` 限并发（`webfetch.ts:143`），但 jina provider 是裸 `Promise.all(args.urls.map(...))`（`jina.ts:40`），5 个 URL 会同时打 `r.jina.ai`（keyless 时限频更严）。

**落点**：`jina.ts` 把 `Promise.all` 换成 `app/src/common/async` 里的 `all(tasks, 2)`（与 webfetch 同款有界扇出）。一行改动，消除一处限频踩雷。

### 5.（可选/低）website 黑名单 —— 仅当产品需要用户级域名管控时

hermes `website_policy.py` 允许用户在配置里维护域名黑名单（含通配子域 `*.x`、父域后缀匹配），且**配置错误 fail-open**（typo 不致瘫痪所有 web 工具，`website_policy.py:259`）。bullx 目前无此能力。

这不是安全刚需（SSRF 才是），而是合规/产品策略需求。**若 bullx 暂无「让运维封某些域名」的诉求，不建议现在加**——它会引入一份新配置面与缓存失效逻辑，属「为想象中的 edge case 加复杂度」。先记录，按需再做。

---

## 结论

**杂项工具**：

- **todo** 与 hermes 完全同源，功能对等，无需改动。
- **build-tool** 任务假设有误——它是内部工厂 helper 不是 agent 工具；其 fail-closed read-only/destructive 默认模型反而比 hermes registry（无此元数据）更完善。无遗漏。
- **check_back_later** bullx 比 hermes 更 durable（Postgres + 租约 + SKIP LOCKED + 启动 catchup vs JSON 文件单进程），重启存活、多实例安全。无遗漏。

**Web 子系统**：bullx 在 **HTTP 重试/超时/content-type 守门/有界扇出/UA 轮换** 等工程细节上做得扎实，部分（重试分类、content-type 白名单）比 hermes 还细。但有 **三个改变行为/安全态的缺口**，按优先级：

1. **【高】完全缺失 SSRF/私网 IP 防护** —— `webfetch.ts` 裸 fetch 模型可控 URL，云元数据/内网可达。这是 webfetch 类工具的标志性高危面，必须补（落点 §1）。
2. **【中】缺 URL 内嵌密钥外泄拦截**（落点 §2）与 **重定向后不再校验**（§1 末尾）。
3. provider 显式配置失败精确报错已补齐；剩余可选项是 Jina 多 URL 抽取改有界扇出。

其余（搜索去重、website 黑名单、LLM 摘要压缩、binary 扩展名）要么两边都缺、要么场景不适用、要么属「按需再加」，**不构成 bullx 的责任缺口**。优先把 §1 的 SSRF 过滤补上即可。


---

## 11. Library / Skills / Soul

技能库存储与同步、技能在系统提示中的注入、默认人格 soul。

bullx 与 hermes 在**存储模型**上分歧明显：bullx 把技能落进 PostgreSQL（`LibrarySkills` / `LibrarySkillFiles` / `AgentSkillAssignments` / `AgentLibraryContainerEntries`），用 `genericHash` 做 content-hash 增量同步，per-agent enable/append 覆盖；hermes 是文件系统（`~/.hermes/skills/`）+ 旁车 JSON（`.usage.json` / `.bundled_manifest` / `.hub/lock.json`）。bullx 的 DB 模型在并发、版本、查询上更干净，是真实优点。

技能投影策略经复核不是缺口：bullx system prompt 只保留技能索引，完整正文在 `skill_use` 调用时进入 user-message/tool-result 路径，已经符合"正文不污染 system prompt 前缀"的缓存方向。真正仍属条件性的差距是生命周期与自建技能安全：bullx 当前没有 `skill_create`，因此 provenance/curator/AST 审计暂不构成当前 bug；一旦开放 agent 自建技能，这些才会变成真实缺口。

| 维度 | bullx 现状 | hermes 现状 (file:line) | 判定 |
|---|---|---|---|
| 技能注入位置 | system prompt 只放技能索引，`skill_use` 调用时注入正文 | **user message 注入完整内容以保 prompt 缓存**；技能 desc 不进 system prompt `skill_commands.py:355-359`、`memory_tool.py:13` | 已对齐核心策略 |
| frontmatter 校验 | 已补齐 name↔目录名一致校验、结构化 diagnostics、坏技能跳过 | desc 必填+≤1024、name 必须等于父目录名、`a-z0-9-`、不得首尾连字符；产出结构化 `SkillDiagnostic` 警告而非抛错 `skills.ts:281-301` | 已补齐 |
| description ≤60 硬约束 | **无**。bullx 上限 1024（`service.ts:623`） | frontmatter 实测普遍 ≤60（如 `skills/research/arxiv/SKILL.md`）；hermes 代码上限也是 1024（`skills.ts:6,297`），≤60 是**资产侧约定**非代码硬约束 | 两边代码都无硬约束；约定差异 |
| platforms 门禁 | **无对应** | frontmatter `platforms: [linux,macos,windows]`（172 文件中 167 有）；`skill_commands.py:30 _resolve_skill_commands_platform` 按平台筛命令 | 缺失 edge case |
| 技能版本 | **无对应**（DB 有 `sourceHash`，无 semver） | frontmatter `version` 161 文件存在；sync 用 origin-hash 判改（`skills_sync.py` 头注释 v1→v2 迁移） | 缺失（仅 metadata，非强语义） |
| curator 自动归档 stale | **无对应**。`archivedAt` 仅 builtin 对账（`service.ts:113-119`） | active→stale(30d)→archived(90d) 状态机，重新使用则 reactivate；只归档不删除、可恢复 `curator.py:268-322`、默认 `curator.py:56-58` | **缺失（agent 自建时为真实缺口）** |
| 使用遥测 | **无对应** | `.usage.json` 旁车：use/view/patch 计数 + 时间戳，跨进程文件锁、原子写 `skill_usage.py:53-56,433-440,490`；调用即 `bump_use`（`skill_commands.py:461-465`） | 缺失 |
| provenance（agent 创建 vs 内置） | **无对应**（无自建路径，故无来源区分） | ContextVar `write_origin`，仅 `background_review` fork 写的技能标 agent-created；curator 只动 agent-created `skill_provenance.py` 全文、`skill_manager_tool.py:890-894` | **缺失（agent 自建时为真实缺口）** |
| 技能同步 | builtin 目录 → DB，content-hash 跳过未变更，孤儿置 `enabled=false` `service.ts:83-201` | 双向更稳：用户改过的 skill **跳过覆盖**、用户删除的**不重新加回**、官方源 hash 比对 `skills_sync.py` 头注释 + `sync_skills` | bullx 已覆盖核心；hermes 多"尊重用户本地修改" |
| 恶意技能 guard | `skill_append` 已做 injection/exfil 子集审计与不可见 Unicode 检测；完整技能包结构/AST/trust-aware 安装仍仅在开放自建/第三方技能时需要 | 90+ 威胁正则（exfil/injection/destructive/reverse-shell/挖矿/凭据泄露）+ 结构检查（文件数/体积/二进制/符号链接）+ **不可见 Unicode 检测** `skills_guard.py:96-517,537-619` | 当前注入面已补齐；自建技能仍是条件性缺口 |
| AST 审计 | **无对应** | `ast.parse` 标记动态 import / `getattr` 计算属性 / `__dict__[expr]`；定位为**人工复审提示非门禁** `skills_ast_audit.py` 全文 | 缺失（opt-in 诊断） |
| trust-aware 安装策略 | **无对应** | builtin/trusted/community/agent-created × safe/caution/dangerous 决策表；dangerous + community/trusted 不可 `--force` 绕过 `skills_guard.py:40-64,686-726` | 缺失 |
| related-skills | **无对应**（metadata 可存 tags/category，无 related） | frontmatter `metadata.hermes.related_skills`，加载时解析 `skills_tool.py:1304-1421` | 缺失（轻量发现性） |
| config 注入 | **无对应** | 技能 frontmatter 声明 `metadata.hermes.config`，注入时把当前值作 `[Skill config: ...]` 块附上，省去读 config.yaml `skill_commands.py:121-157` | 缺失 |
| 模板/inline-shell 展开 | **无对应** | `${HERMES_SKILL_DIR}`/`${HERMES_SESSION_ID}` 替换 + `` !`cmd` `` 内联执行（默认关、可配超时、截断 4000）`skill_preprocessing.py` 全文 | 缺失（按需特性） |
| disable-model-invocation | **已支持** `service.ts:553`、`system-prompt.ts:4` | 同样支持 `skills.ts:275` | 对等 |
| per-agent enable/append | **已支持且更细**（DB 级 `AgentSkillAssignments` + `AGENT_APPEND.md` 合并）`service.ts:320-410` | hermes 无等价的 per-agent 覆盖层（pin/archive 是全局态） | **bullx 更强** |
| 默认 soul | 写实人格模板（INTJ/贝叶斯）2.8k `templates/SOUL.md`；fallback 一行 `default-soul.ts:8` | 一段 654B 字符串常量 `default_soul.py:3-11` | bullx 更丰富 |

### 重点可借鉴项

#### 1.（条件性）若开放 agent 自建技能，先补 provenance + curator + 完整包审计
`skill_append` 的现实注入面已补齐：写入前会扫描 prompt-injection/exfiltration 高危片段与不可见 Unicode。bullx 仍没有 `skill_create`，所以 provenance、curator、AST 审计、trust-aware 安装策略暂不构成当前 bug；一旦开放自建/第三方技能，这些应作为前置门禁补齐。

#### 2. 使用遥测旁车（即便不上 curator 也有价值）
hermes 的 `.usage.json`（use/view/patch 计数 + last_used，跨进程锁 + 原子写 `skill_usage.py:466-490`）是 curator 的数据底座，但独立看也有用：bullx 可在 `LibrarySkills` 或新表记 `last_used_at` / `use_count`，`skill_use`/`skill_search` 命中即 `bump`（对应 hermes `skill_commands.py:461-465`）。有了它，运营能回答"哪些技能从没被用过"，也为将来的归档/清理留接口。bullx 用 PG 比 hermes 的文件锁天然更稳，落点是 `getEffectiveSkillContent` 成功分支里 `UPDATE ... use_count = use_count+1`。

#### 3. config 注入：技能声明 config 键，加载时把当前值附上
hermes 让技能在 frontmatter 写 `metadata.hermes.config`，`skill_use` 时把解析后的当前值作 `[Skill config: key = value]` 块附在正文后（`skill_commands.py:121-157`），省掉 agent 再去读配置的一轮往返。bullx 已有 `getSecret`-style 配置体系（见 CLAUDE.md / plugin 注释），落点是 `service.ts:getEffectiveSkillContent` 拼 `content` 时，若 frontmatter 含 config 声明则追加解析值块——纯增益、低风险。

### 结论

bullx 的存储层（PostgreSQL + content-hash 同步 + per-agent enable/append 覆盖）比 hermes 的文件+旁车 JSON **更干净、更强**，per-agent 覆盖与 SOUL 模板也比 hermes 更成熟，这些是已settled的好设计，不要relitigate。

真实差距现在只剩条件性生命周期能力：AST 审计 / provenance / curator / 完整 trust-aware 安装策略 / 遥测。bullx **当前没有 agent 自建技能的写路径**，所以 curator/provenance 暂不构成 bug，属"开放自建即需补"的条件性缺口。`skill_append` 审计、不可见 Unicode 检测、frontmatter 目录一致校验与结构化诊断已经补齐；description ≤60 在两边代码里都不是硬约束（均 ≤1024），仅 hermes 资产侧约定，不必当作缺口对待。


---

## 12. Computer 沙箱服务 + LLM Provider 服务

**简介**

bullx 的 `computer` 是一个纯**控制面**：worker（`bullx-computerd`）自己注册/心跳，bullx 只负责把每个 agent 解析（resolve）到一个**粘性 worker**，签发会话 token，剩下的执行（命令、文件、终端）全部下沉到 worker。这是清晰的架构选择，把"沙箱的生命周期/资源限制/崩溃恢复"留给了 worker daemon 和外部编排（k8s/进程管理器）。

hermes 没有"控制面 / worker 注册表"这一层——它的 `tools/environments/*` 是**进程内直连后端**（local/docker/ssh/modal/daytona/singularity），agent 进程自己拥有并管理沙箱。所以两边在"沙箱"上**不是同构系统**：bullx-resolver ≈ hermes-docker 的"按 (task,profile) 复用容器"那一小段逻辑，其余（多后端、资源限制、OOM 重建）是 hermes 在**沙箱实现层**积累、bullx 故意外推到 worker 的东西，多数应判为"架构选择"而非缺陷。

bullx 的 `llm-providers/service.ts` 则是一个**配置/注册表服务**：CRUD provider（加密 API key、baseUrl、providerOptions）、把 pi-ai 的模型目录投影出来、解析出一个 `ResolvedLlmProviderModelProfile` 交给 pi-ai 去 stream。**真正的限频/重试/错误分类/凭证轮换全部委托给 pi-ai SDK**（`maxRetries`/`maxRetryDelayMs`/`transport`），app 层唯一的恢复逻辑是 context-overflow→压缩→重试（`runtime.ts:1514`）。这正是 hermes 积累极厚、bullx 近乎空白的地带——下面重点挖掘。

---

### 对照表

| 维度 | hermes（file:line） | bullx（file:line） | 判定 |
|---|---|---|---|
| **沙箱：按 agent/task 粘性复用** | docker 按 `(hermes-task-id, hermes-profile)` label 跨进程复用容器 `docker.py:810-849`、`_find_reusable_container docker.py:1109` | 按 `agentUid` 解析粘性 binding，pin>binding>least-bound，全程 `pg_advisory_xact_lock` `service.ts:101-137` | 两者都做了，**bullx 的并发收敛（advisory lock）更干净**；同构 |
| **沙箱：崩溃/OOM 自动重建** | execute 检测"container gone"→`_recreate_container()`→重试一次 `docker.py:1052-1067`、`972`；SIGKILL/OOM 安全网注释 `docker.py:164` | 无 app 层重建；worker 崩溃后 binding 失活靠 30s 心跳窗口。session acquisition 失败会释放 stale binding 并重解析一次 | **架构选择**（执行在 worker 侧）；已补齐控制面可安全补的重解析重试 |
| **沙箱：资源限制** | `--cpus/--memory/--tmpfs/--network=none/--pids`、storage-opt 探测 `docker.py:556-625,1070` | 无（worker 自管，`capacity`/`load` 仅作元数据透传 `computer.ts:15-16`） | **架构选择**，非缺陷 |
| **沙箱：多后端** | local/docker/ssh/modal/daytona/singularity 6 后端 | 单一 worker 抽象（worker 内部可以是任意后端） | **架构选择** |
| **沙箱：worker 鉴权 token** | 无中心 token（进程内直连） | HS256 JWT，含 `agentUid/workerId/instanceId/exp`，600s TTL `service.ts:139-151`、`tokens.ts` | **bullx 更完整**（它有 worker 这层才需要） |
| **Provider：凭证池/多 key 轮换** | `CredentialPool` 多 key + OAuth，轮换策略 4 种（fill_first/round_robin/random/least_used）`credential_pool.py:95-104`，按 key 健康/cooldown/DEAD 状态机 | **无对应**。每个 provider 单 `encryptedApiKey`，无第二把 key、无轮换 `service.ts:11,422` | **真实缺口**（见重点①） |
| **Provider：按状态码的 cooldown** | 401→5min、429→1h、默认 1h，provider 的 `reset_at` 覆盖默认 `credential_pool.py:106-112,248-254` | **无对应**（SDK 内部重试，app 不追踪 key 冷却） | 真实缺口 |
| **Provider：错误分类（可重试/致命/限频/超载）** | `FailoverReason` 23 类 + `classify_api_error` 按状态码+正文模式，输出 `retryable/should_compress/should_rotate_credential/should_fallback` 动作位 `error_classifier.py:24-64,441` | 已有最小 LLM 错误分类器，覆盖 auth/rate_limit/server/timeout/overflow/unknown，并接入 `withRetry` | 最小恢复动作已补齐；完整 fallback/key rotation 仍未做 |
| **Provider：fallback 模型** | 用户配置 `fallback_chain`（list/dict）→失败时换 provider/模型 `agent_init.py:818-936`；429/402/连接错误触发 `auxiliary_client.py:5427-5475` | **无对应**。`profile` 有 primary/light/heavy 三档但无"主模型挂了切备用"链路 | 真实缺口 |
| **Provider：限频跟踪/退避** | 解析 `x-ratelimit-*`（RPM/RPH/TPM/TPH 8 头）`rate_limit_tracker.py:13-20`；Nous 专属 rate guard 避免 9×重试打爆 RPH `nous_rate_guard.py:7-9`；jittered backoff 防惊群 `retry_utils.py:19` | 已有 `jitteredBackoff`；仍无 rate-limit header 解析 | 剩余缺口是 header/reset 时间跟踪 |
| **Provider：模型元数据/上下文窗口目录** | 多源：models.dev + 端点 `/v1/models` 探测 + 硬编码 fallback，带 TTL 缓存（model 1h / endpoint 5min）`model_metadata.py:105-112,621` | 静态：直接读 pi-ai 内置目录 `getModel/getModels`，无远端探测/缓存 `service.ts:262-272,363` | bullx 简单但**够用**（pi-ai 已带目录）；本地/自定义端点会缺 contextWindow——**轻量缺口** |
| **Provider：用量/成本跟踪** | `CanonicalUsage`（input/output/cache_read/cache_write/reasoning）+ `PricingEntry` 按百万 token 算 USD `usage_pricing.py:30-71`；Nous `x-nous-credits-*` 余额解析 `credits_tracker.py:9-26`；账户窗口 `/usage` `account_usage.py:26-46` | 部分：`AgentState.usage/cost` 结构在 core 内（`agent.ts:44-58`），落库 `AiAgentLlmTurns.usage`（`runtime.ts:2060`）。**但成本/价目表来源未见**，cost 字段疑似依赖 pi-ai 返回 | bullx 有 usage 落库骨架；**价目表/cache 分项计费深度不足**——半缺口 |
| **Provider：service tier** | codex 适配器透传 `service_tier` `codex_responses_adapter.py:835,854` | **无对应**（providerOptions 无此字段 `service.ts:99-110`） | 缺口（小，按需） |
| **Provider：reasoning 配置** | `THINKING_BUDGET` 映射 effort→token 预算 `anthropic_adapter.py:58,2248`；Gemini `thinkingBudget`、Grok `reasoning.effort` 白名单 `model_metadata.py:277` | **有对应且良好**：`reasoning: off/minimal/low/medium/high/xhigh` 透传给 pi-ai `service.ts:60,310` | bullx 已好（粒度交给 pi-ai） |
| **Provider：provider 专属适配** | anthropic/codex/bedrock/gemini×2/azure 各自 adapter（~50–97k 行） | 委托 pi-ai 的 `piProvider`，bullx 只做 headers/compat/baseUrl 覆盖 `service.ts:442-458` | **架构选择**（pi-ai 即适配层），非缺陷 |
| **Provider：key 健康检查** | `checkLlmProvider` 等价物 + 池内 `_is_terminal_auth_failure`/refresh `credential_pool.py:486,859` | `checkLlmProvider` 做了"key 在不在 + 模型存在性"校验 `service.ts:223-260`，但**不发真实探活请求** | bullx 有静态校验；**无主动 ping provider**——轻量缺口 |
| **Provider：密钥加密/泄漏防护** | secret_source/fingerprint round-trip `credential_pool.py:124` | **bullx 更严**：AEAD 加密落库 + per-provider KMS 派生密钥 `service.ts:422-440`；禁止把 secret 塞进 `providerOptions.headers` `service.ts:375-381` | bullx 已好 |

---

### 重点可借鉴项

> 取舍前置：bullx 把"逐请求恢复"委托给 pi-ai 是**合理且已settle 的方向**，不要为了对齐 hermes 而把 hermes 那套巨型适配器搬过来。下面只挑**改变行为、且能薄薄加在 service 层而不入侵 pi-ai 黑盒**的项。

#### ① 错误分类器：把"原始错误"翻译成"恢复动作位"（已补齐）

本期已新增 LLM 错误分类器并接入 stream 创建处的 `withRetry`：429/5xx/timeout 会按 retryable 处理，auth/overflow 等保持独立动作位。它覆盖了 hermes 最小可借鉴的"错误 → 恢复动作"路由表；更完整的 provider fallback 链与凭证轮换仍按产品需要另议。

#### ② 解析后 worker 中途死亡：session acquisition 重解析已补齐

本期已在 computer 工具的 worker session acquisition 路径补一层安全重试：连接类/5xx/timeout 失败时释放 stale binding、重新 resolve 一次并重试获取会话。已经提交到 worker 的命令不自动重放，避免重复执行破坏性操作。

#### ③ 多 key 凭证池 + 按状态码冷却（若存在多 key 诉求才做）

bullx 当前每 provider 一把 key（`service.ts:11`）。hermes 的 `CredentialPool` 支持多 key 轮换 + 每把 key 的健康状态机：`ok/exhausted/dead` + 按状态码定 cooldown（401→5min、429→1h，provider 的 `reset_at` 覆盖；`credential_pool.py:55-63,106-112,248-254`），并把"上游永久失效的 OAuth 原因"（token_revoked/invalid_grant…）标 DEAD 永不回轮换（`credential_pool.py:68-75`）。

判定：**这是真实缺口，但是否借鉴取决于产品形态**。bullx 是单 Installation、强调"一个运营域"，多数 provider 大概率单 key——那么全套池子是过度设计（违反 CLAUDE.md"prefer deletion / 反对过早抽象"）。**最小可落地**只取一点：在 `LlmProviderOptions` 增加可选 `apiKeys: string[]`（保留单 `apiKey` 兼容），`resolveLlmProviderModelProfile`（`service.ts:279`）在被 ①的 `rate_limit`/`auth` 动作位回调时换下一把 key + 记一个内存级 cooldown（`Map<keyHash, resetAt>`）。不建议一上来就引入 4 种轮换策略和 OAuth 刷新状态机——那是 hermes 因为要吃 Codex/Anthropic/xAI OAuth 才背的复杂度，bullx 用 AEAD+静态 key 没这个负担。

#### ④ 退避加 jitter + 解析 `x-ratelimit-*`

`jitteredBackoff` 已替换旧固定退避，不再保留兼容别名。剩余可借鉴项是解析 `retry-after` / `x-ratelimit-reset-*` 等响应头，以真实 reset 时间覆盖盲目指数退避；这需要 provider 错误对象稳定暴露响应头，单独评估。

---

### 结论

**沙箱**：bullx 的控制面/数据面分离是清晰且正确的架构选择，`resolveComputerWorker` 的 per-agent advisory-lock 收敛甚至比 hermes docker 的 label 复用更干净，worker JWT 鉴权也更完整。hermes 在沙箱上"更厚"的部分（多后端、资源限制、OOM 重建）**绝大多数是它把执行放在进程内才需要的，不构成 bullx 的缺陷**。worker 解析后中途死亡的 session acquisition 重解析已补齐；已提交命令不自动重放是有意的副作用边界。

**LLM Provider**：这是两边差距最大、也最值得借鉴的地带，但要节制。bullx 把底层 provider 适配委托给 pi-ai 是已 settle 的方向，不应把 hermes 的巨型 per-provider 适配器搬过来。错误分类器、retryable 接线与 jittered backoff 已补齐；剩余值得评估的是 **ratelimit header 解析** 与 **多 key 池**（仅当真有多 key 诉求，且只取"多 key + 状态码冷却"两点）。usage 落库 bullx 已有骨架（`AiAgentLlmTurns.usage`），缺的是**价目表 + cache 分项计费**，可参照 `usage_pricing.py:30-71` 的 `CanonicalUsage`/`PricingEntry` 结构补齐，属独立小任务。


---

## 13. 插件系统 + 调度器（plugins + scheduler/cron）

对照 bullx-agent（TS/Bun，改进对象）与 hermes-agent（Python，参照系）的插件机制与 cron 调度器。

### 简介

**插件系统**：两边走的是完全不同的哲学。

- **bullx**：插件 = **能力贡献点**（capability contribution），不是行为拦截点。`BullXPlugin`（`packages/sdk/src/plugins.ts:786`）只能贡献四类东西：`appConfigDefinitions` / `appConfigPatterns`（配置项）、`externalGatewayAdapters`（聊天网关适配器）、`identityProviderAdapters`（身份源）、`webProviders`（搜索/抽取）。**没有 pre/post_tool_call、pre/post_llm_call、on_session_start/end、register_tool、register_cli_command 这类生命周期钩子**——插件无法拦截 agent 的工具调用或 LLM 调用。发现是**进程启动时一次性**的（`app/src/plugins/discovery.ts:42`），通过动态 `import()` 加载，无热卸载（`runtime.ts:212` 明确说"plugin activation is process-lifetime"）。隔离靠两点：插件**不能 import app-local core 类型**（SDK 是结构化契约接口，`plugins.ts:416` 注释），以及 id/adapter-id 的**唯一性校验**（`runtime.ts:218` `buildPluginRegistry` 抛 `DuplicatePluginIdError`/`DuplicatePluginExternalGatewayAdapterError`）。

- **hermes**：插件 = **运行时拦截 + 工具/命令注入**。`PluginManager`（`hermes_cli/plugins.py:1029`）支持完整生命周期钩子（`pre_tool_call`/`post_tool_call`/`pre_llm_call`/`post_llm_call`/`on_session_start`/`on_session_end`，`plugins.py:129-143`），`register_tool`（`:320`）、`register_cli_command`（`:390`）、`register_middleware`（`:958`）。发现有**4 个来源 + 优先级**（bundled → user → project → pip entry-point，`plugins.py:1053` `discover_and_load`），entry-point 通过 `importlib.metadata`（`_scan_entry_points`，`:1402`，group=`hermes_agent.plugins`）。有 **manifest（version/kind/api_version）**（`PluginManifest`，`:236`；`kind` 有 standalone/exclusive/model-provider/backend/platform，未知 kind 降级为 standalone，`:1331`）。

**调度器**：两边都是"由心跳 tick 拉取到期任务并执行"，但硬化深度差距很大。

- **bullx**：**DB-backed（Postgres）多实例安全**。`Bun.cron('* * * * *')` 每分钟 tick（`runtime.ts:69`），任务存 `scheduled_tasks` 表，靠 `SELECT ... FOR UPDATE SKIP LOCKED` + lease 列（`claimedBy`/`leaseExpiresAt`）抢占（`store.ts:201` `claimDueTask`）。支持 lease 心跳续租（`withLeaseHeartbeat`，`runtime.ts:263`，每 1min 续 5min）、失败指数退避（`FAILURE_BACKOFF_MS`，`runtime.ts:21`）、连续失败告警阈值+冷却（`maybeRecordFailureAlert`，`:280`）。调度格式只有 2 种：`every`（间隔 ms）和 `cron`（Bun.cron 表达式），见 `schedule.ts:8`。
- **hermes**：**文件-backed（jobs.json）单主机**。`tick()`（`cron/scheduler.py:2016`）由 gateway 每 60s 调一次，靠 `.tick.lock` **文件锁（flock/msvcrt）防重复 tick**（`:2031`）。这一块经过大量生产打磨：grace 窗口、catchup fast-forward、at-most-once 预先 advance、cron 专属工具集隔离、prompt-injection 扫描、`skip_memory`。调度格式有 4 种：duration 一次性、`every Xm` 间隔、5/6 段 cron、ISO 时间戳一次性（`parse_schedule`，`cron/jobs.py:209`）。

### 对照表

| 维度 | bullx | hermes | 判定 |
|---|---|---|---|
| **插件钩子（tool/llm/session 生命周期）** | 无 | `pre/post_tool_call`、`pre/post_llm_call`、`on_session_start/end`（`plugins.py:129`） | hermes 多一整类能力；但**对 bullx 是刻意的窄契约**，非缺陷（见结论） |
| **插件 register_tool / register_cli_command** | 无 | 有（`plugins.py:320`/`:390`） | hermes 独有 |
| **钩子失败隔离** | N/A（无钩子） | 每个 callback try/except 包裹，一个插件抛错不污染主路径（`plugins.py:1597`、`:1628`） | hermes 处理了；bullx 无对应面 |
| **entry-point 发现（pip 包）** | 无（只扫本地目录 + `package.json` 的 `bullx.plugin`/`exports`） | `importlib.metadata` entry_points（`plugins.py:1402`） | 不同分发模型，非缺陷 |
| **插件 manifest version/kind** | 仅 `apiVersion: 1`（`plugins.ts:734`），无 version/kind | `PluginManifest.version`/`.kind`（`plugins.py:236`） | hermes 更细；bullx 故意极简 |
| **"插件不得改 core"** | SDK 结构化接口 + 不可 import app-local（`plugins.ts:416`） | 目录 module + `register(ctx)`，core 通过 `PluginContext` 暴露 | 两边都有边界，机制不同 |
| **lazy 加载** | 全部启动时 eager import | 启动 eager，但重导入有 lazy（`tools_config` 等懒 import）；force 重扫（`:1053`） | 大体相当 |
| **插件 id 唯一/合法校验** | `pluginIdPattern` + Duplicate*Error（`runtime.ts:32`、`:225`） | bare-name dedup + kind 冲突处理 | bullx 更严格（直接抛错） |
| — **调度器** — | | | |
| **tick 防重复（多 tick 并发）** | DB `FOR UPDATE SKIP LOCKED` + 单进程 `tickPromise` 串行（`runtime.ts:103`） | `.tick.lock` 文件锁（`scheduler.py:2031`） | **不同机制，bullx 更强**（跨实例；hermes 仅跨本机进程） |
| **catchup 窗口（半周期 clamp 120s–2h）** | 已补齐：cron catchup 迟到超过 grace 时 fast-forward，跳过 stale run | `_compute_grace_seconds`：period//2，clamp `[120s, 7200s]`（`jobs.py:344`） | 已对齐核心行为 |
| **grace 窗口（120s 给错过的 one-shot）** | **无** | `ONESHOT_GRACE_SECONDS=120`（`jobs.py:46`、`_recoverable_oneshot_run_at` `:317`） | **hermes 独有** |
| **missed/stale fast-forward（防启动雪崩）** | 已补齐：`every`-kind 数学快进；`cron`-kind catchup stale run 直接快进到下个未来点 | cron+interval 都按 grace 判 stale → 快进到下个未来点、跳过本次（`jobs.py:1085`） | 已对齐 |
| **at-most-once（崩溃不重复 fire）** | lease + 完成时改 nextRunAt；崩溃则 lease 过期后**会重跑**（at-least-once 倾向） | **执行前**先 `advance_next_run` 把 nextRunAt 推到未来（`scheduler.py:2064`、`jobs.py:983`），显式转 at-most-once | 设计取舍不同（见重点2） |
| **cron 会话硬中断（防失控循环）** | 已补齐调度器侧运行时长 deadline，超时 abort 并释放 lease | **inactivity 超时**（默认 600s 空闲，非 wall-clock；`scheduler.py:1805`，超时 `agent.interrupt()`） | bullx 用 wall-clock deadline 覆盖最危险的 stuck run |
| **cron 默认 skip_memory** | 假阳性：当前 bullx 没有会被 scheduled task 写坏的用户画像/长期记忆写入面；scheduled task 也用独立 room，不复用真人会话 | `skip_memory=True`（`scheduler.py:1799`，"Cron system prompts would corrupt user representations"） | 不列为当前 bug |
| **cron 投递不镜像进网关会话** | scheduled_task 用独立 `conversationProviderRoomId=scheduled-task:{id}`（`runtime.ts:213`），不复用人类会话 → 已隔离 | 清 `HERMES_SESSION_*` contextvars，不 seed 网关会话（`scheduler.py:1549`） | 两边都隔离，机制不同 |
| **cron 专属工具集隔离** | scheduled_task 仅 `disableInteractiveTools:true`（`runtime.ts:214`） | 强制禁 `cronjob`/`messaging`/`clarify` 三类，且叠加 config 黑名单防 LLM 绕过（`scheduler.py:62`、`:75`） | **hermes 更细**（防 cron-spawn-cron 等） |
| **cron prompt-injection 扫描** | 无 | 装配后整 prompt（含 skill 正文）扫描，命中则交付"blocked"而非崩溃（`scheduler.py:1299`、`CronPromptInjectionBlocked` `:49`） | hermes 独有 |
| **调度格式覆盖** | `every` + `cron`（2 种）（`schedule.ts:8`）；one-shot 仅经 `check_back_later` | duration / `every Xm` / 5-6 段 cron / ISO 时间戳（4 种）（`jobs.py:209`） | hermes 表达力更广 |
| **per-job skills/model/script/context_from/workdir** | **无**（scheduled_task 只有 `message` + 可选 `delivery`，`db-schema/scheduler.ts:21`） | 全有（`cronjob_tools.py:459` 的 `skills`/`model`/`script`/`context_from`/`workdir`/`enabled_toolsets`） | hermes 远更丰富（但 bullx 是 agent OS 定位，取舍合理） |
| **时区/DST** | `computeNextRun` 用 `timezoneOffsetMs(tz, after)` 在每次计算时取当时偏移（`schedule.ts:42`）→ DST 边界正确 | croniter + `_ensure_aware`/`astimezone`（`jobs.py:298`、`:415`） | 两边都处理了 DST，bullx 偏移按"该时刻"取，正确 |
| **失火重叠（同任务并发）** | lease + claim 防同任务被两实例同时执行 | 同任务运行中则下次 tick 跳过（`_running_lock`/`scheduler.py:166`，`:2197`） | 两边都防 |
| **agent 可自建 cron** | **不能**（scheduled_task 只有 console-admin REST，`routes.ts:49` `requireConsoleAdmin`）；agent 只能 `check_back_later` 一次性自唤醒（`check-back-later-tool.ts:38`） | 能（`cronjob` 工具，但 cron 上下文里又禁掉它防递归） | 定位差异，非缺陷 |

### 重点可借鉴项

#### 1. catchup grace 窗口 + cron-kind stale fast-forward（已补齐）

本期已在 scheduler runtime 中加入 cron catchup stale fast-forward：迟到超过 grace 的 catchup run 不再执行，只记录取消/快进并推进到下个未来点。`every` 继续使用原有 steps 数学快进。

#### 2. 执行前预先 advance nextRunAt（at-least-once → at-most-once 的显式选择）

bullx 当前是 claim→执行→完成时才写 `nextRunAt`（`store.ts:316`）。若进程在执行中崩溃，lease 过期后该任务会被重新 claim **重跑**——对"发日报""触发外部副作用"类任务，崩溃循环可能重复投递 N 次。

hermes 把这点显式化（`scheduler.py:2058`、`jobs.py:983`）：**在 run_job 之前**就把 `next_run_at` 推到下一个未来点，注释直说"converts the scheduler from at-least-once to at-most-once for recurring jobs — missing one run is far better than firing dozens of times in a crash loop"；one-shot 任务故意不 advance（保留重试）。

**落点**：bullx 不必照搬（lease+心跳已覆盖大多数"卡住"场景，且 DB 事务比文件锁可靠）。但**值得在 `executeScheduledTask`（`runtime.ts:183`）里给 recurring 任务加一个选项**：claim 成功后、`runProgrammaticTurn` 之前，先 `store` 写一个 `nextRunAt = computeNextRun(after=now)`（与完成时的写法二选一），把语义从"崩溃重跑"切到"崩溃跳过"。这是一个**取舍开关**而非 bug 修复——建议按任务类型（有 `delivery` 的对外投递任务更怕重复）暴露。

#### 3. cron agent 运行时长保护（已补齐 wall-clock deadline）

**诚实更正**：prompt 里说的"cron 会话 3 分钟硬中断（防失控循环霸占调度器）"，在当前 hermes 代码里**找不到 wall-clock 3 分钟硬中断**。实际机制是 **inactivity（空闲）超时**：默认 600s（10min）无活动才杀，可活跃运行数小时（`scheduler.py:1805`）。它用 agent 的 `get_activity_summary().seconds_since_activity` 轮询，超过阈值 `agent.interrupt(...)` 并抛 `TimeoutError`：

```python
# hermes cron/scheduler.py:1855
if _idle_secs >= _cron_inactivity_limit:   # 默认 600s
    _inactivity_timeout = True
    ...
    agent.interrupt("Cron job timed out (inactivity)")
```

本期已在 `app/src/scheduler/runtime.ts` 加入调度器侧 deadline，并把 `AbortSignal` 传入 `runProgrammaticTurn`。当前采用 wall-clock timeout 覆盖 stuck run 的最大风险；更细的 inactivity timeout 需要 agent activity summary，暂不引入额外状态机。

#### 4. cron 工具集硬隔离

`skip_memory` 在当前 bullx 中是误报：没有 Hermes 那种会被 cron system prompt 写坏的用户画像/长期记忆写入面，scheduled task 也使用独立 room。仍可保留的借鉴是工具集硬隔离：若未来给 agent 开放 `create_scheduled_task` 工具，务必在 scheduled/checkback 上下文里把它和交互类工具一并禁掉（参考 hermes 的"always-disabled in cron context"清单）。

### 结论

**插件系统**：bullx 与 hermes 是**两种不同契约，不是同一东西的强弱版**——bullx 把插件定义为"贡献适配器/配置/web-provider 的窄能力点"，**刻意不给 tool/llm/session 拦截钩子**；这与 CLAUDE.md 的"prefer boring contracts over clever machinery""prefer the chosen guarantee over an imagined stronger one"一致，是合理取舍，**不应**照搬 hermes 的钩子机器。唯一可借鉴的小点：若将来确实要支持插件注入工具，把 hermes 的"**每个 callback try/except 隔离**"（`plugins.py:1597`）作为既定不变量先立住。bullx 在 id/adapter 唯一性校验上反而比 hermes 更严（直接抛错），是优点。

**调度器**：bullx 的**分布式底座（Postgres SKIP LOCKED + lease + 心跳 + 退避 + 失败告警）明显强于** hermes 的文件锁单机方案。cron catchup stale fast-forward 与运行时长 deadline 已补齐，`skip_memory` 在当前实现中是误报。剩余值得记录的是两个取舍：① 崩溃重跑 vs 预先 advance 属 at-least-once/at-most-once 选择，对有外部投递的任务可按需提供开关；② 未来若开放 agent 自建 cron，需要 scheduled/checkback 上下文的工具集硬隔离。

其余差异（per-job skills/model/workdir、4 种调度格式、agent 自建 cron、entry-point 发现、manifest version/kind）属**定位差异**（bullx 是 agent OS + console 管控、对外企业网关；hermes 是个人 CLI agent），按 CLAUDE.md "a deliberate tradeoff is not a bug"，不计为缺陷。


---

## 14. Principals 主体 / 鉴权 / 授权 / 身份提供方

## 简介

本层是 bullx 的「主体操作系统」核心：多类型 Principal（`human` / `agent`）+ 子类型表（human_users / agents）、external_identities（platform_subject / channel_actor / login_subject / outbound_actor 多种绑定）、authorization（grants + groups[static/computed CEL] + memberships，决策下沉到 native CEL 引擎）、admin-auth（OIDC 登录 + AEAD 密封 cookie 会话 + state/nonce）、identity-providers（IdP 运行时 + 全量/增量目录同步：用户禁用、组删除、部门继承、冲突收敛）。

hermes 在架构上是**单用户 / 单 agent 的本地 CLI**，其 `SECURITY.md §2.6` 明确写死设计取舍：

> "**Within the authorized set, all callers are equally trusted.** Hermes Agent does not model per-caller capabilities inside a single adapter."（`SECURITY.md:210-213`）
> "**Session identifiers are routing handles, not authorization boundaries.**"（`SECURITY.md:206`）

也就是说 hermes **根本没有** Principal / group / grant / CEL / 多主体授权这一整层——它的「授权」就是一份 operator 配的 allowlist（谁能跟 gateway 说话），外加一个二元的 slash 命令 admin/非 admin 分层。**因此本层 bullx 整体大幅领先，这是真实结论，不应硬造对称。**

但 hermes 在三个**点状的鉴权细节**上确有成熟实现，且恰好命中本任务要求重点排查的 edge case，值得 bullx 借鉴：
1. **dashboard_auth 的 OAuth/OIDC 会话**（`hermes_cli/dashboard_auth/`）——PKCE S256 + state CSRF + id_token JWKS 验签（iss/aud/exp/sub 强制）+ **refresh token 轮换 & reuse-detection** + 透明续期 + 多 provider 链式验签容错 + open-redirect 防御 + WS 票据。
2. **gateway/pairing.py** 配对码——**TTL + 盐+哈希存储 + 常数时间比较 + 失败次数 lockout + max-pending 限流**，是「外部身份绑定防重放/防爆破」的参照。
3. **OAuth token 刷新基础设施**（`tools/mcp_oauth*.py`、`agent/google_oauth.py`、`tools/microsoft_graph_auth.py`）——**skew 提前刷新、绝对 expires_at 持久化、跨进程文件锁、磁盘外部刷新失效检测、401 thundering-herd 去重**。

---

## 细粒度对照表

| 细粒度功能 | bullx 实现 | hermes 对应 | hermes 额外 edge case | 可借鉴 | 优先级 |
|---|---|---|---|---|---|
| 多类型 Principal + 子类型表 | `principals/service.ts`、`agents/service.ts:63`、`human-users/service.ts:28` | 无对应（单用户，无 Principal 概念） | 无 | — | — |
| 授权模型（grants/groups/memberships/CEL） | `authorization/service.ts:54` `authorize()` → native CEL；`grants.ts`、`groups.ts`、`memberships.ts` | 无对应；`SECURITY.md:210` 明言"all callers equally trusted, no per-caller capabilities" | 无 | — | — |
| computed group（CEL 动态成员，如 all_humans） | `groups.ts:16` `ALL_HUMANS_CONDITION`、`service.ts:239` 快照传 native | 无对应 | 无 | — | — |
| 最后一个 admin 防锁死（行锁 + 双重校验） | `memberships.ts:50-63` `removePrincipalFromGroup` 事务内 `lockPrincipal`/`lockGroup`/`ensureNotLastActiveHumanAdmin` | 无对应（无 admin group 概念） | 无 | — | — |
| root 初始化竞态（首个 admin 抢占） | `service.ts:191` `rootInitAdmin` 事务 + `ensureRootInitOpen` 重检 | 无对应 | 无 | — | — |
| 管理员会话 cookie | `session.ts:33` AEAD 密封（非仅签名）、`expiresAt` 内嵌、`sealed-cookie.ts:28` 过期即作废 | `dashboard_auth/cookies.py` AT/RT 双 cookie，`HttpOnly+SameSite=Lax+Secure(条件)` | **cookie 前缀硬化 `__Host-`/`__Secure-`** 按 HTTPS+反代前缀选择（`cookies.py:87-99`）；bullx 仅静态 `Secure` 标志 | cookie 前缀 + Path 隔离（见下） | P3 |
| OIDC state（CSRF） | `api-routes.ts:78` `newOpaqueToken()` state，回调 `oidcState.state !== state` 校验（`api-routes.ts:121`） | `self_hosted/__init__.py:208` `secrets.token_bytes(32)` state，`routes.py:287` `state != expected_state` 校验 | 大体相当；hermes 把 state 存 PKCE cookie，bullx 存独立密封 cookie | 双方对称 | — |
| OIDC nonce（重放/令牌注入） | `api-routes.ts:79` 生成 nonce 并透传 adapter（`oidcState.nonce`），但**最终 id_token nonce 校验在 plugin adapter 内部，本层不可见** | **无 nonce**（用 auth-code + PKCE，靠 JWKS 验签替代） | hermes 反而省了 nonce | bullx 已领先；但需确认 adapter 真的校验 nonce（见附带提醒） | — |
| OIDC PKCE | **本层无 PKCE**（state+nonce；PKCE 由 adapter 决定） | `self_hosted/__init__.py:204-217` `code_verifier`=64B、`code_challenge`=S256，`nous`/`self_hosted` 全 S256 | hermes 强制 S256 PKCE | 若 bullx adapter 未做 PKCE，可借鉴（见附带提醒） | P3 |
| OIDC id_token 验签（iss/aud/exp/alg） | 委托给 adapter `completeOidcLogin`（`api-routes.ts:137`），本层不持有验签逻辑 | `self_hosted/__init__.py:506-514` `jwt.decode(... algorithms=allowlist, audience, issuer, require=[exp,iat,aud,iss,sub])`；`:103` 显式 alg 白名单；`:452` discovery issuer pin | hermes 把 alg 白名单 / aud / iss / required-claims 全显式校验 | 作为 adapter 实现 checklist 参照 | P3 |
| OIDC redirect_uri 稳定化（反代） | `oidc.ts:21` `resolveIdentityProviderPublicBaseUrl`（持久化优先，回退 request origin） | `cookies.py:24` 靠 `X-Forwarded-Proto`/`X-Forwarded-Prefix`；`self_hosted` `_validate_redirect_uri` | 思路一致 | 双方对称 | — |
| 登录后 returnTo / open-redirect 防御 | `session.ts:80` `safeReturnTo`：仅允许 `/` 开头、拒 `//` | `routes.py:356` `_validate_post_login_target`：拒非 `/`、拒 `//`、**额外拒 `/login` `/auth/` `/api/*` 回环** | **更细**：禁止回跳登录/auth/API 路径（避免渲染裸 JSON / 回环） | 加 `/api`、`/console/login` 回环黑名单 | P3 |
| 会话固定攻击（session fixation） | OIDC 成功后 `createAdminSessionCookie` **新签发**会话（`api-routes.ts:149`），未沿用 pre-login cookie，天然防固定 | login 成功后 `set_session_cookies` 写全新 token cookie | 双方都在登录成功点重签，OK | 双方对称 | — |
| refresh token 轮换 + reuse-detection | **无 refresh token 概念**（7d 密封会话，到期重新 OIDC） | `middleware.py:255-290` AT 过期→用 RT 透明轮换→**必须回写轮换后的 RT**（`cookies.py:7-16` 说明 Portal 轮换 RT 且 reuse-detect）；`_attempt_refresh` 遇 `RefreshExpiredError`（reuse/吊销）强制重登 | **有**：RT 轮换 + 复用即吊销整会话 + 透明续期，bullx 完全没有 | bullx 是固定 7d 会话，**刻意取舍**（无 SPA token 流），不必引入；仅记录 | P4 |
| 多 provider 验签链 + 不可达容错 | 单 OIDC 流（按 providerId 取一个 adapter） | `middleware.py:226-252` 遍历所有 provider `verify_session`，区分"token 无效"vs"IDP 不可达(503)"，不可达不强制重登 | **有**：区分瞬时 IDP 故障与令牌失效 | 概念好，bullx 多 IdP 时可参考 | P4 |
| WS 升级鉴权票据 | 无对应（bullx 此层无 WS） | `ws_tickets.py` 单次 30s 票据 + 进程级 internal credential（从不注入 SPA，仅子进程环境，`compare_digest` 常数时间） | **有**：浏览器无法在 WS upgrade 设 Authorization 的鉴权解法 | 若 console 加 WS 可参考 | P4 |
| 密码登录爆破限流 | 无（仅 OIDC，无本地密码） | `routes.py:404-429` 滑动窗口 per-IP 限流 + `:498` 通用错误消息（不做用户名 oracle） | **有**：credential-stuffing 限流 + 不泄露 provider 存在性 | 见下（pairing/限流通用思路） | P3 |
| 外部身份去重/收敛（同一人多绑定） | `external-identities/service.ts:135` `upsertPlatformSubjectHuman`：唯一 `(kind,provider,externalId)` 约束做收敛点；`upsertExternalIdentity:85` upsert | `whatsapp_identity.py` `canonical_whatsapp_identifier`：跨 LID/phone JID 别名折叠为单一稳定身份（`:122`），读 `lid-mapping-*.json` 传递闭包 | hermes 解决的是"**同一平台同一人两种 ID 形态**"的别名折叠；bullx 解决的是"**多事件源收敛到同一 principal**" | 别名折叠思路（见下） | P2 |
| 渠道身份未验证 fail-closed | `external-identities/service.ts:207` `resolveChannelActor` 未 `verifiedAt` 即 `forbidden`；disabled/agent 也拒（`:213`） | gateway allowlist + `pairing.is_approved`（`pairing.py:144`） | 思路一致（bullx 更细粒度，按 verifiedAt） | bullx 领先 | — |
| 外部身份配对/绑定防重放防爆破 | **无显式配对码流**（绑定靠登录/同步写入；channel_actor 靠 `verifiedAt`，但产生路径在 gateway 层） | `pairing.py`：码 TTL=1h（`:44`）、盐+SHA 哈希存储（`:200`/`:246`，明文码不落盘）、`secrets.compare_digest` 常数时间（`:307`）、失败 `MAX_FAILED_ATTEMPTS=5` lockout（`:284` **approve 前先查 lockout**）、`MAX_PENDING_PER_PLATFORM=3`、码用一次即删（`:316`） | **有**：完整的配对码防重放/防爆破/防枚举 | **强烈推荐**作为 bullx 任何"激活码/配对码/邀请码"绑定流的参照（见下） | P2 |
| OAuth token 刷新（skew/绝对过期/锁/去重） | 无对应（本层不做出站 OAuth；getSecret 配置静态） | `microsoft_graph_auth.py:96` `is_expired(skew_seconds)` 提前刷新；`google_oauth.py:129` 60s skew + `:168` 跨进程 fcntl/msvcrt 锁；`mcp_oauth.py:281` 持久化绝对 `expires_at`；`mcp_oauth_manager.py:7` mtime 磁盘外部刷新失效 + 401 thundering-herd 去重 | **有**：出站 OAuth 刷新的完整工程（skew/绝对时间/跨进程锁/去重） | bullx 未来做出站 OAuth（IdP 写回、第三方 API）时参照 | P3 |
| IdP 全量同步：缺失即禁用 | `identity-providers/service.ts:383` `disableMissingIdentityProviderUsers`，仅对**带 sync 证据**的行禁用（`:530` `identityProviderHasManagedUser`，避免误禁 gateway 先建的行） | 无对应（无目录同步） | 无 | — | — |
| IdP 增量 vs 全量 / 组继承 / 父子展开 | `service.ts:43` 全量事务；`:95` 增量 `syncIdentityProviderUser`；`:481` `expandGroupAncestors` 部门祖先展开（带 visited 防环） | 无对应 | 无 | — | — |
| IdP provider-禁用 vs operator-禁用区分 | `service.ts:21` `bullxDisabledByProvider` 元数据键，恢复时仅当此前是 provider 禁用才 `active`（`:179`） | 无对应 | 无 | — | — |
| IdP 启动降级 + 后台重试 | `runtime.ts:76` 本地配置错抛出/阻断启动，provider API/WS 失败仅 degraded + `scheduleRetry`（`:216`） | 无对应；但 dashboard `middleware.py:245` 区分 IDP 不可达=503 不强制重登（思路相通） | hermes 仅在"验签时 IDP 不可达"层面有类似 graceful 处理 | 双方各有侧重 | — |
| disable 最后管理员（后端是否硬拦） | `principals/service.ts:98-101` 注释：**后端故意允许**禁用最后一个 active human admin，由 console UX 层兜底；`memberships.ts:71` `ensureCanDisablePrincipal` 是可选前置校验 | 无对应 | 无 | 这是 bullx 的刻意取舍（见附带提醒，非 bug） | — |

---

## 重点可借鉴项

### 1.（P2）配对码 / 激活码绑定流：抄 `gateway/pairing.py` 的防重放套件

bullx 当前外部身份绑定主要走「登录 OIDC」或「目录同步」自动写入，channel_actor 靠 `verifiedAt` 把关。但只要 bullx 出现任何**人工配对/激活/邀请码**场景（例如把 IM 用户绑定到既有 Principal、setup 激活码 `SetupBootstrapActivationCodeConfig`、agent/外部系统配对），hermes 这套是现成的高质量参照：

落点：bullx 的码校验路径（如 setup 激活码、未来 channel pairing）。关键防御点（`gateway/pairing.py`）：

- **明文码不落盘**：只存 `salt + SHA256(code, salt)`，`list_pending` 也只显示 hash 前 8 位（`pairing.py:200,246,328-351`）。
- **常数时间比较**：`secrets.compare_digest(candidate_hash, entry["hash"])`（`:307`）——bullx 现有 `oidcState.state !== state`（`api-routes.ts:121`）和 setup `setupState?.state === state`（`api-routes.ts:109`）是**短路 `===` 字符串比较，理论上有时序侧信道**。密封 cookie 的 AEAD 已经提供完整性，所以风险低，但若把 token 比较收敛到一个常数时间 helper 是更稳的边界。
- **approve 前先查 lockout**（`:284` 注释明确）：否则 lockout 只挡 generate 不挡 approve，等于对已发出的码爆破不设防。
- **失败计数 lockout + max-pending + per-user 速率限制**（`:49-50, :374`）。
- **码用一次即删**（`:316`）+ **TTL 清理**（`:276` `_cleanup_expired`）。

参照片段（`pairing.py:300-317`）：
```python
candidate_hash = self._hash_code(code, salt)
if secrets.compare_digest(candidate_hash, entry["hash"]):  # 常数时间
    matched_key = entry_id; matched_entry = entry; break
...
if matched_key is None:
    self._record_failed_attempt(platform)   # 失败计数→lockout
    return None
del pending[matched_key]                     # 用一次即删
```

### 2.（P2）外部身份别名折叠：参照 `whatsapp_identity.canonical_whatsapp_identifier`

bullx 的去重发生在 DB 唯一约束 `(kind, provider, externalId)` 层（`external-identities/service.ts:135` 收敛点设计很干净）。但有个 bullx 没覆盖的 edge case：**同一平台、同一个人，平台自身用两种 externalId 形态投递**（WhatsApp 的 LID `@lid` vs phone `@s.whatsapp.net`）。此时 bullx 会创建**两个 platform_subject 行 / 两个 Principal**，因为 `externalId` 字符串不同。

hermes 的解法（`whatsapp_identity.py:122-155`）：在写入/查询前先把 externalId 走一遍 `canonical_*`，读平台映射文件做传递闭包，取最短（数字优先）别名作为稳定身份。落点：bullx 各 IM adapter 在调用 `upsertPlatformSubjectHuman` / `resolveChannelActor` 之前，应先把 `externalId` 归一到平台规范形态（可放在 adapter 内，或在 `external-identities` 暴露一个 per-provider 归一钩子）。这能避免「一个人两条主体行」导致授权/会话分裂。

注意防御细节：hermes 对参与拼文件名的 identifier 用 `_SAFE_IDENTIFIER_RE`（ASCII-only，防全角数字/路径穿越，`:43,:101`）——bullx 若引入类似映射也要做同等输入约束。

### 3.（P3）登录后 returnTo 黑名单更细 + cookie 前缀硬化

- **returnTo 回环黑名单**：bullx `safeReturnTo`（`session.ts:80`）只拒 `//` 和非 `/`。hermes `_validate_post_login_target`（`routes.py:356-387`）额外拒 `/login`、`/auth/`、`/api/*`——避免登录成功后跳回登录页死循环、或跳到 API 端点在浏览器渲染裸 JSON。bullx 建议补 `/console/login`（若有）与 `/api` 前缀黑名单。
- **cookie 前缀**：bullx `cookieHeader`（`session.ts:65-73`）固定 `Secure`（生产）+ `SameSite=Lax`，但**未用 `__Host-`/`__Secure-` 前缀**。hermes `cookies.py:87-99` 按 HTTPS + 反代前缀动态选 `__Host-`（绑死 origin、无 Domain）或 `__Secure-`（带 Path）。对 admin 会话这种高价值 cookie，加 `__Host-` 前缀是低成本的浏览器侧硬化（防子域 cookie 注入/固定）。bullx 已有 `Path=/`，满足 `__Host-` 前置条件。

### 4.（P3 / 仅备查）出站 OAuth 刷新工程

bullx 本层不做出站 OAuth，但 IdP 写回、未来第三方资源 API 调用迟早需要。hermes 已踩平的坑值得存档：
- **skew 提前刷新**：`is_expired(skew_seconds)` 在真正过期前 N 秒就刷（`microsoft_graph_auth.py:96`；google 60s，`:129`），避免临界请求 401。
- **持久化绝对 `expires_at` 而非相对 `expires_in`**：`mcp_oauth.py:246-295` 详细记录了"重启后只剩相对 expires_in→`is_token_valid()` 误判 True→发陈旧 Bearer"的 bug 类，解法是落盘绝对时间。
- **跨进程文件锁**：`google_oauth.py:168` fcntl/msvcrt 包裹凭据文件读改写，防多进程并发刷新互相覆盖（RT 轮换场景尤其致命）。
- **磁盘外部刷新失效 + 401 去重**：`mcp_oauth_manager.py:7-31` mtime watch 让"别的进程刷新了 token"被下一次调用感知；并对同一 access_token 的 thundering-herd 401 只触发一次恢复。

---

## 结论

**本层 bullx 大幅领先，且是结构性领先，不是细节差距。**

bullx 实现了一个真正的多主体授权操作系统：`human`/`agent` 双类型 Principal + 子类型表、external_identities 四种绑定语义、grants + static/computed(CEL) groups + memberships 且决策下沉到 native CEL 引擎、OIDC 登录 + AEAD **密封**（非仅签名）会话、以及一套相当完整的 IdP 目录同步（全量/增量、缺失即禁用且只禁有同步证据的行、组删除、部门父子继承展开带防环、provider-禁用 vs operator-禁用区分、启动降级+后台重试）。其中**最后一个 admin 防锁死的行锁双重校验**（`memberships.ts:50-63`）和 **root 初始化抢占竞态**（`service.ts:191`）是 hermes 完全没有的并发正确性设计。

hermes 在这一层**没有可比的整体系统**——它的 `SECURITY.md §2.6` 直接把"不建模 per-caller 能力、session id 只是路由句柄、授权=allowlist"写成了**刻意的产品取舍**（单用户 CLI 不需要主体系统）。所以「hermes 在授权上更强」这个命题不成立，如实承认。

hermes 真正值得 bullx 借鉴的是**三处点状的鉴权工程细节**，它们不属于"主体系统"而属于"会话/绑定/令牌的攻防硬化"：
1. **配对码防重放套件**（pairing.py：哈希存储 + 常数时间比较 + lockout 前置 + 用一次即删 + max-pending）——P2，bullx 任何码绑定流都该照抄。
2. **外部身份别名折叠**（whatsapp_identity.py：同一人多 ID 形态归一）——P2，补 bullx「一人两主体行」盲点。
3. **登录后 returnTo 回环黑名单 + cookie `__Host-` 前缀硬化**——P3，对 admin 会话的低成本加固。
（出站 OAuth 刷新工程 P3 仅备查，本层暂不需要。）

### 附带提醒：bullx 自身在 OIDC / 会话上需自查的隐患（非 hermes 对照，作为 review 项）

1. **id_token 的 nonce/iss/aud/alg 校验是否真在 adapter 内做了？** 本层把 `completeOidcLogin` 完全委托给 plugin adapter（`api-routes.ts:137`），生成了 nonce 并透传，但**本层代码看不到任何 id_token 验签**。hermes `self_hosted/__init__.py:506-514` 把 alg 白名单 / audience / issuer / `require=[exp,iat,aud,iss,sub]` / discovery issuer pin 全显式做了。**强烈建议**确认 bullx 的 OIDC adapter（native 或 plugin）确实：(a) 校验签名且限定 alg 白名单（防 `alg:none` / RS↔HS 混淆）；(b) 校验 aud==client_id、iss==配置 issuer；(c) **校验回传 nonce == cookie 内 nonce**（否则 nonce 生成了但没用，等于裸 auth-code，易受令牌注入）。这是本层最大的"看不见的风险面"。

2. **token 字符串比较用 `===` 短路**（`api-routes.ts:109,121`）。AEAD 密封已提供完整性兜底，风险低，但收敛到常数时间比较 helper 更稳。

3. **`completeSetupOidcCallback` 与正常登录回调共用同一 `/sessions/oidc/:providerId/callback`**，靠 `setupState?.state === state` 先匹配 setup cookie（`api-routes.ts:108-118`）。需确认 setup 完成后 setup OIDC state cookie 被可靠清掉（`api-routes.ts:202` 有 expire），否则残留 setup cookie 可能影响后续登录分支判断——目前看逻辑正确，仅作回归关注点。

4. **OIDC state cookie 与 session cookie 共用同一 KMS purpose**（`session.ts:13` `ADMIN_AUTH_SESSION` + context 区分 `'admin-auth-cookie'` vs setup `'setup-cookie'`）。context 不同已隔离派生密钥，OK；但 state cookie 与 session cookie 同 context（都是 `'admin-auth-cookie'`），两者 payload 结构不同、都内嵌 `expiresAt`，`read<T>` 仅按结构反序列化——理论上一个被当另一个读的概率极低（字段缺失即 `undefined`），但属可观察的耦合点，记录备查。


---

## 15. 配置 / i18n / 初始化向导

**对照对象**：bullx-agent（TS/Bun，DB 存配置）vs hermes-agent（Python，单 YAML 文件存配置）。

两边的**配置存储模型根本不同**，必须先讲清楚再公允比较：

- **bullx**：动态配置存 PostgreSQL `app_configure` 表（`key TEXT` + `value jsonb`）。每个 key 必须先用 `defineAppConfig({ key, schema(zod), encrypted, defaultValue })` 声明并注册（`app/src/config/app-configure.ts:166`、`:201`）。读写都过 Zod 校验，加密 key 用 per-key 派生密钥 AEAD 加密落库（`:486`）。bootstrap 配置（`DATABASE_URL`/`BULLX_SECRET_BASE`/`REDIS_URL`…）单独走 `AppEnv`，启动期一次性 Zod 解析（`app/src/config/env.ts:4`）。
- **hermes**：单文件 `~/.hermes/config.yaml`。`load_config()` 用 `copy.deepcopy(DEFAULT_CONFIG)` 起步，再 `_deep_merge(用户文件)`（`hermes_cli/config.py:5168`、`:4862`），`_expand_env_vars` 展开 `${VAR}`（`:4882`）。密钥放 `~/.hermes/.env`（`hermes_cli/env_loader.py:212`），与 config 分离。

**结论先行**：bullx 的 DB+registry+Zod 模型把 hermes 一大堆 edge case **从结构上消灭了**（无需 deep-merge、无需 env-ref 展开、无需 `.env` 修复、未知 key 默认拒绝、密钥默认加密落库、每 key 强类型校验）。这是更优设计，不是缺陷。bullx **唯一真实缺口**是没有「配置结构版本迁移」机制——当某个 key 需要**重命名 / 改结构**（不是改 DB 表结构）时，hermes 的 `_config_version` + `migrate_config` 能处理，bullx 目前只能靠 per-key 临时 backfill。profile 隔离是 bullx 的**既定取舍**（CLAUDE.md 明确单 Installation），不是遗漏。

| 维度 | bullx | hermes | 判定 |
|---|---|---|---|
| 配置存储 | PG `jsonb`，per-key 声明+注册 | 单 YAML 文件 | 模型不同；bullx 更适合多进程/服务端 |
| 深合并保留默认 | 不需要（每 key 独立行+`defaultValue`，`app-configure.ts:336`） | `_deep_merge`（`config.py:4862`） | bullx 结构上免疫；非缺陷 |
| 配置版本迁移（重命名/改结构 key） | **无对应**（仅 Drizzle DB schema 迁移 `db-migrate.ts`；个别 key 临时 backfill `system.ts:31`） | `_config_version`=28 + `migrate_config` 一长串 `if current_ver < N`（`config.py:2439`、`:4266`） | **真实缺口**，可借鉴（见 ①） |
| 未知 key 容忍 | **默认拒绝**：未注册 key 抛 `UnknownAppConfigKeyError`（`app-configure.ts:227`） | 宽松：deep-merge 保留未知 key，`validate_config_structure` 仅 warn（`config.py:4055`） | bullx 更严，更优；非缺陷 |
| 配置校验 | per-key Zod，写前读后都校验（`app-configure.ts:369`、`:514`） | 运行期 `validate_config_structure` 启发式查常见错放（`config.py:4055`） | 两边路线不同；bullx 类型保证更强 |
| 密钥与 config 分离 | bootstrap 密钥走 `AppEnv`；动态密钥 `encrypted:true` AEAD 落库（`env.ts`、`app-configure.ts:486`） | 密钥放 `.env`，config 引用 `${VAR}`（`env_loader.py`、`config.py:4882`） | 都做了分离；机制不同，均合理 |
| 密钥不入明文 config | 是，加密列 `CIPHER` + per-key 派生密钥（`app-configure.ts:529`） | 是，`.env` 不进 YAML；存盘时还原 `${VAR}` 模板防泄露（`config.py:4917`） | 都达标 |
| `.env` 损坏修复 | 无对应（不用 `.env` 存运行期密钥） | `sanitize_env_file` 拆并行 KEY=VALUE、剥非 ASCII、补 null 字节（`config.py:5407`、`env_loader.py:102`） | bullx 因模型不同**无需**此能力；非缺陷 |
| 弃用/dead-key 清理 | 无对应（无清理路径） | 迁移块清 dead env（`ANTHROPIC_TOKEN`/`LLM_MODEL`，`config.py:4329`、`:4405`） | 缺口较小，随迁移机制一并借鉴（见 ①） |
| profile 隔离 | **既定取舍**：单 Installation（CLAUDE.md），无 profile | `--profile`/`active_profile` → `HERMES_HOME`，import 前预解析（`main.py:310`、`hermes_constants.py:53`） | 设计差异，不相关；勿相提并论 |
| i18n locale 解析/回退 | `normalizeLocale` 仅精确匹配+默认（`i18n-locales.ts:16`）；客户端 i18next `fallbackLng`（`webui/src/i18n/i18n.ts:19`） | `_normalize_lang` 别名表+剥地区后缀（`i18n.py:141`）；`t()` 缺键回退英文（`i18n.py:274`） | hermes 回退链更鲁棒，部分可借鉴（见 ②） |
| i18n 语言来源优先级 | server: DB 默认 locale；client: `<html lang>`（`web-routes.ts:111`、`i18n.ts:39`） | env > config > default（`i18n.py:241`） | 两边各自合理；bullx 无 `Accept-Language` 协商 |
| 三套 loader 不一致风险 | **低**：单一 `AppConfigService` + 单一 registry（`app-configure.ts:293`） | 存在：`load_config`/`load_config_readonly`/`read_raw_config`/`check_config_version` 各读一遍、缓存模型不同（`config.py:5152`、`:3988`、`:4429`） | bullx 单点更优；非缺陷 |
| setup 向导中断恢复 | 每步即时落 DB，无线性状态机；activation code + `setup.completed` 门控天然幂等可续（`setup/routes.ts`、`bootstrap.ts`） | 线性 CLI `run_setup_wizard`，各 section 可独立重跑（`setup.py:2894`） | bullx 服务端模型更易恢复；非缺陷 |
| 激活码 | bootstrap 随机 8 位 `[A-Z0-9]`，完成后删除（`bootstrap.ts:29`、`routes.ts:151`） | 无对等概念（CLI 本地信任） | bullx 因 Web 暴露面需要；合理 |
| 首触引导 | 无对应（Web setup 一次性向导） | `agent/onboarding.py` 一次性情境提示，flag 记 `config.yaml`（`onboarding.py:6`） | 形态差异；非缺陷 |

---

### 重点可借鉴项

#### ① 配置版本迁移：把 hermes 的 `_config_version` 机制改造成 bullx 的 per-key 迁移注册（**唯一真实缺口**）

bullx 现状：DB **表结构**有 Drizzle 迁移（`app/src/common/db-migrate.ts`），但 `app_configure` 行里**单个 key 的 value 形状/命名变化没有任何迁移路径**。今天只有一个临时手法——`loadSystemTimezoneWithLegacyBackfill(legacyTimezone)`（`app/src/config/system.ts:31`）在新 key 缺失时把旧值搬过来。这种 backfill 是 per-call 散落的，无法处理「`llm.providers` 从数组改成对象」「key 从 `foo.bar` 重命名为 `foo.baz`」这类结构变更。

hermes 用一个**单调递增的 `_config_version`（当前 28，`config.py:2439`）**加一长串幂等迁移块解决（`config.py:4266`）。真正有借鉴价值的是它处理的几类 case：

```python
# config.py:4341  list → dict 结构重命名 + key 派生 + 去重
if current_ver < 12:
    custom_list = config.get("custom_providers")
    if isinstance(custom_list, list) and custom_list:
        providers_dict = config.get("providers", {}) ...
        # 从 name 派生 kebab key，冲突加后缀，迁完 pop 掉旧 list
        config.pop("custom_providers", None)

# config.py:4405  清理"没人再读"的 dead key（防用户困惑）
if current_ver < 13:
    for dead_var in ("LLM_MODEL", "OPENAI_MODEL"): save_env_value(dead_var, "")

# config.py:4807  迁移结束统一打版本戳
config["_config_version"] = latest_ver; save_config(config)
```

并且 hermes 特意区分了「**运行期读**」和「**判定是否已迁移**」：`check_config_version()` 读**裸文件**而非 deep-merge 后的内存配置，否则缺 `_config_version` 的旧文件会「继承」内存默认版本号、永远不触发迁移（`config.py:3988` 的 docstring 把这个坑讲得很清楚）。`_coerce_config_version` 还把 `bool`/非法值当 legacy=0（`config.py:3977`）。

**落点（bullx 化改造，不要照搬文件级版本）**：bullx 是 per-key 模型，正确做法是**给迁移也做成 registry**，而不是一个全局版本号。建议在 `app/src/config/` 新增 `app-configure-migrations.ts`：

```ts
// 形如：每条迁移声明「源 key/形状 → 目标 key/形状」，幂等
interface AppConfigMigration {
  id: string                       // 'm003_llm_providers_list_to_record'
  run(svc: AppConfigService): Promise<boolean>  // 返回是否发生改动
}
// 一个独立的 app_config_migrations 表（或复用 schema_migrations 风格）记已跑 id
// 在 setup/bootstrap.ts 的 initializeSetupBootstrap 之前跑 pending 迁移
```

关键是**幂等 + 记录已执行 id**（对应 hermes 的版本戳，但粒度到迁移条目），并且**改名迁移要先写新 key、确认后再 delete 旧 key**（对应 `config.py:4397` 的 `pop`）。这条最值得做：bullx 配置一旦上线、key 改名/改形状是迟早的事，现在没有任何承接路径。

#### ② i18n `normalizeLocale`：补别名映射 + 剥地区后缀回退链

bullx 服务端 `normalizeLocale` 是「精确命中 `SUPPORTED_LOCALES` 否则回默认」的二值逻辑（`app/src/config/i18n-locales.ts:16`）。这意味着浏览器/用户传 `zh-CN`、`zh`、`zh-Hans`、`chinese` 全部落到 `en-US`——明明该匹配到 `zh-Hans-CN`。

hermes 的 `_normalize_lang` 给了完整三段回退（`agent/i18n.py:141`）：精确码 → 别名表（`'chinese'/'zh-cn'/'zh-hans' → 'zh'`，`i18n.py:55`）→ 剥地区后缀再试（`'zh-CN'.split('-')[0] → 'zh'`）→ 默认。

```python
# agent/i18n.py:148
key = value.strip().lower()
if key in SUPPORTED_LANGUAGES: return key
if key in _LANGUAGE_ALIASES: return _LANGUAGE_ALIASES[key]
base = key.split("-", 1)[0]
if base in SUPPORTED_LANGUAGES: return base
return DEFAULT_LANGUAGE
```

**落点**：bullx 的 locale 是 `language-script-region`（`zh-Hans-CN`），剥后缀要按「逐段截短」而非取首段。改 `app/src/config/i18n-locales.ts:16` 的 `normalizeLocale`：

```ts
const LOCALE_ALIASES: Record<string, SupportedLocale> = {
  'zh': 'zh-Hans-CN', 'zh-cn': 'zh-Hans-CN', 'zh-hans': 'zh-Hans-CN', 'zh-hans-cn': 'zh-Hans-CN',
  'en': 'en-US', 'en-us': 'en-US'
}
export function normalizeLocale(locale: string | null | undefined): SupportedLocale {
  if (!locale) return DEFAULT_LOCALE
  const key = locale.trim().toLowerCase()
  const exact = SUPPORTED_LOCALES.find(l => l.toLowerCase() === key)
  if (exact) return exact
  if (key in LOCALE_ALIASES) return LOCALE_ALIASES[key]
  // 逐段截短：zh-hans-cn → zh-hans → zh
  const parts = key.split('-')
  for (let n = parts.length - 1; n >= 1; n--) {
    const prefix = parts.slice(0, n).join('-')
    if (prefix in LOCALE_ALIASES) return LOCALE_ALIASES[prefix]
  }
  return DEFAULT_LOCALE
}
```

这条收益直接：`web-routes.ts:111` 和 `setup/routes.ts:143` 的 locale 入口都会受益，浏览器 `zh-CN` 用户不再被打回英文。注意保持 `isSupportedLocale` 仍是严格精确判定（它用于 `syncDocumentLocale` 这类「必须是规范码」的场合，`webui/src/i18n/i18n.ts:44`），只放宽 `normalizeLocale`。

#### ③ i18n `t()` 缺键回退英文（仅当 bullx 后续上服务端文案翻译时才需要）

hermes `t()` 的回退三层很稳：目标语言缺该 key → 回退英文目录同 key → 仍缺则**返回 key 本身**（绝不抛错），`str.format` 失败也吞掉只 warn（`agent/i18n.py:274-293`）。

```python
# agent/i18n.py:274
if value is None and target != DEFAULT_LANGUAGE:
    value = _load_catalog(DEFAULT_LANGUAGE).get(key)   # per-key 回退英文
if value is None:
    value = key                                        # 最后兜底：不崩
```

bullx 客户端 i18next 已配 `fallbackLng: DEFAULT_LOCALE`（`webui/src/i18n/i18n.ts:19`），所以**前端这层 bullx 已经有等价能力，不用动**。这条只在一个未来场景下有意义：**bullx 若开始在服务端（TS）渲染面向用户的本地化文案**（目前 server 端只存 `default_locale`、不渲染文案），届时需要一个等价的 per-key fallback-to-default + 不抛错的 `t()`。现在标注为「按需」，不是当前缺口。

#### ④ 配置加载「裸读 vs 合并读」的语义区分（hermes 的教训，bullx 已天然规避，仅记录）

hermes 必须维护 `read_raw_config()`（用户实际写了啥）vs `load_config()`（合并默认后）两条路径，迁移判定（`check_config_version`）和「只在用户没显式设过才迁移」逻辑都依赖裸读（`config.py:4429` 的 v14 迁移就反复在 `raw_stt` 上判断）。这是 deep-merge 模型的固有复杂度。

bullx 的 per-key 模型**天然没有这个问题**：每个 key 要么 DB 里有行（用户设过）要么没有（走 `defaultValue`），`Object.hasOwn(definition, 'defaultValue')` 一处判定即可（`app/src/config/app-configure.ts:336`），不存在「默认值污染了用户意图」。**这是 bullx 设计的隐性优势，做 ① 的迁移机制时务必保持**——迁移逻辑应直接查 DB 行存在性（`loadFromDatabase` 返回 `undefined` 即用户未设），而不是去对比合并后的值。

---

### 结论

- **bullx 的配置系统整体优于 hermes**，且优势是结构性的：DB+per-key-registry+Zod 把 hermes 大量 edge case（deep-merge、env 展开、`.env` 损坏修复、未知 key、三套 loader 不一致、密钥明文风险）**从源头消除**。不要因为 hermes「功能更多」就误判 bullx 有缺失——那些功能多数是单文件模型的**补丁**，bullx 不需要。
- **唯一值得补的真缺口是 ①「配置值的版本迁移」**：bullx 有 DB 表结构迁移，但没有「key 改名/改 value 形状」的承接机制，目前只有散落的 per-key backfill。应做成**幂等 + 记录已执行 id 的迁移 registry**，借鉴 hermes 的「先写新、确认后删旧」「裸读判定是否已迁移」两个要点，但**不要照搬全局 `_config_version`**——per-key 模型对应的是 per-migration id。
- **②③ i18n 回退链**两边都用得上对照：服务端 `normalizeLocale` 补别名+逐段截短（②）是低成本直接收益；`t()` 的 per-key 英文回退（③）bullx 前端已具备，仅服务端文案落地时才需要。
- **profile 隔离、setup 向导形态、首触引导、激活码**均为两边**既定的设计取舍差异**（单 Installation vs 多 profile、Web 一次性向导 vs 线性 CLI），不构成 bullx 的缺陷，不应相提并论或要求 bullx 补齐。


---

## 16. 通用基础设施 + 数据库 Schema

### 简介

本篇对照 bullx-agent 的 `app/src/common/*`（通用基础设施）与 `app/src/common/db-schema/*`（数据模型）与 hermes-agent 的对应实现。

公允地讲：bullx 的**持久层本身比 hermes 更工业级**——PostgreSQL + drizzle + Bun SQL 连接池、KMS 派生密钥、AEAD 对称加密、覆盖全表的 `check` 约束与 `jsonb_typeof` 守卫、部分唯一索引、GIN 索引、级联策略。hermes 是单机 SQLite，许多"防御"恰恰是因为 SQLite 缺少 PG 自带的能力（事务 DDL、服务端类型、并发控制）而被迫手写的。

日志 secret 脱敏、SQL params 收敛、最小错误分类器、jittered backoff、set-null FK 覆盖索引已于本期补齐。剩余仍值得借鉴的是 **DB 损坏防御与"拒绝在损坏文件上重建"运维理念**（`hermes_cli/kanban_db.py`）：fail-closed + 内容寻址隔离备份，理念可迁移到 PG 的备份/巡检侧。

### 能力对照表

| 能力 | bullx (file:line) | hermes (file:line) | 评判 |
|---|---|---|---|
| 结构化日志 | `common/logger.ts:4` pino，ISO 时间戳、K8s severity 映射 | `hermes_logging.py:202` profile-aware 多文件(agent/errors/gateway/gui.log) | bullx 结构化更好(JSON)；hermes 多文件分流+轮换更适合单机运维 |
| 日志轮换 | 无（依赖 K8s/容器 stdout 采集） | `hermes_logging.py:266` RotatingFileHandler，maxBytes+backupCount，配置可调 | 取舍不同：bullx 假设容器环境，合理；非容器部署是 omission |
| **日志 secret 脱敏** | 已补齐：pino `redact` 覆盖常见 secret/header/token 路径，SQL trace 不再输出 raw params | **`agent/redact.py`** 30+ 厂商前缀正则 + ENV/JSON/Header/JWT/DB-connstr/私钥/手机号；`RedactingFormatter` 挂在所有 handler | bullx 已堵住当前泄漏面；hermes 自由文本 token 正则更厚 |
| 对称加密 | `kms.ts` + `sealed-cookie.ts` AEAD(native addon)；KMS 从 ROOT_SECRET 派生 per-purpose key | `tools/credential_files.py` / `credential_persistence.py` 主要是磁盘边界**脱敏+指纹**，非加密 | **bullx 领先**（真加密 vs hermes 写盘前剥离明文） |
| 密钥轮换 | 无 `kid`/版本号（`kms.ts`、`sealed-cookie.ts` 无版本字段） | 无（同样无轮换） | 双方无对应；bullx 因有 KMS 抽象，加版本更廉价（见可借鉴项4） |
| Sealed cookie | `sealed-cookie.ts:25` AEAD seal + `expiresAt` 过期校验 | 无对应（hermes 无 web session cookie 这层） | bullx 独有且做得对（过期内置在 payload） |
| DB 连接池/关闭超时 | `database.ts:12` max=10, idleTimeout=1h, connTimeout=20s；`closeDatabase({timeout})` 幂等关闭 | SQLite 无池；`kanban_db.py:1151` busy_timeout(默认+env 可调) 串行化写者 | bullx 领先（真池化）；hermes busy_timeout 是 SQLite 单写者下的等价物 |
| DB 迁移安全 | `db-migrate.ts:14` drizzle migrator + `schema_migrations` 表（PG 事务性 DDL 兜底） | `hermes_state.py:707` `_reconcile_columns` 声明式 ADD COLUMN 对账(Beets 模式)，免版本链 | 取舍不同：bullx 用成熟迁移器(更强)；hermes 声明式对账思路新颖但仅 ADD COLUMN |
| **DB 损坏防御** | **无**（依赖 PG 服务端；无应用层 integrity 巡检/隔离） | **`kanban_db.py:1284`** `KanbanDbCorruptError` fail-closed + `_backup_corrupt_db`(内容寻址隔离) + header/integrity 双探针 | hermes 专门做；理念可迁移到 PG 运维(见可借鉴项2) |
| WAL/损坏自愈 | N/A(PG) | `hermes_state.py:157` `apply_wal_with_fallback`(NFS/SMB/FUSE 降级 DELETE)；`synchronous=FULL` 窄化崩溃窗口 | hermes 的文件系统适配是 SQLite 特有问题，PG 无此需求 |
| 错误分类法 | 已新增最小 LLM 错误分类器，给 `withRetry` 提供 retryable 判定 | `error_classifier.py:24` 27 个 `FailoverReason` + retryable 标志 + 状态码/正文模式匹配 | bullx 已覆盖当前恢复路径；hermes 分类更细 |
| 重试/退避 | `jitteredBackoff` 指数退避 + 50% 去相关抖动；`withRetry` abort-aware | `retry_utils.py:19` `jittered_backoff`(50%抖动+计数器去相关) | 已对齐核心退避语义 |
| async 帮助器(超时/取消/并发) | `async.ts:18` `all(cap)` 有界并发；`createCombinedAbortSignal:42`(规避 Bun timer 泄漏) | `async_utils.py:34` `safe_schedule_threadsafe`(跨线程调度防协程泄漏) | 关注点不同：bullx 并发+取消，hermes 线程↔事件循环桥接；都很精炼 |
| JSON path 帮助器 | `json.ts` `toJsonValue/stringFromPath/numberFromPath`(深度 coerce 到 jsonb-safe) | `utils.py`(零散) | **bullx 领先**（系统化的 jsonb 安全边界） |
| 时间/时区 | 散落用 `Date.now()`；`@pleisto/active-support` 的 `ms()/seconds()` 做时长 | `hermes_time.py:91` `now()` IANA 时区感知 + 失败安全回退 + 缓存 | hermes 有集中时区层；bullx 时长语义好但缺统一"带时区 now()" |

---

### 重点可借鉴项

#### 1) DB 损坏防御的"fail-closed + 隔离备份"运维理念迁移到 PG 侧

hermes 对 SQLite 做了一套**"宁可拒绝打开，也不在损坏文件上重建"**的防御（`kanban_db.py`）：

- `_validate_sqlite_header`(`kanban_db.py:1249`)：开连接前先读前 64 字节验 magic，把"page-0 被 TLS 响应覆盖"这类损坏与普通 PRAGMA 错误区分开；
- `_guard_existing_db_is_healthy`(`kanban_db.py:1357`)：`PRAGMA integrity_check`，**事务性 lock/busy 错误不当作损坏**（`raise` 透传），只有真正 malformed 才隔离；
- `_backup_corrupt_db`(`kanban_db.py:1303`)：把损坏文件**按内容 sha256** 拷成 `*.corrupt.<hash>.bak`（含 `-wal/-shm` 旁文件），重复隔离同一坏字节只占一份盘；
- `KanbanDbCorruptError`(`kanban_db.py:1284`)：抛出而非静默 `CREATE TABLE`，错误信息里同时给出原文件与备份路径，**杜绝"自动重建把用户任务清空"**。

bullx 用 PG，服务端自带 checksum/WAL/PITR，**不应**把这套逐字搬进应用层（那是把 SQLite 的缺陷补丁误当架构）。但**理念可迁移**到 bullx 的 DB 运维：

- **fail-closed 启动巡检**：`db-migrate.ts` 目前只跑 migrate 就宣布成功。可加一步轻量探针——比如 `SELECT` 关键表行数 / 跑 `pg_catalog` 一致性查询，发现 schema_migrations 与代码版本不符时**拒绝启动并打印备份指引**，而不是带病服务。
- **迁移前自动快照**：把 hermes "改动前先做时间戳备份"的纪律，落成 migrate 前的 `pg_dump`/逻辑快照钩子（尤其破坏性迁移），失败可回滚。
- **内容寻址隔离**思路可用于任何"疑似坏数据导出"的运维脚本，避免 N 次重试放大 N 份盘。

落点：`common/db-migrate.ts`（启动巡检/快照钩子）；备份策略文档化即可，**不要**在应用热路径加 PG 的 integrity 巡检（PG 没有 SQLite 那种页损坏面，属过度工程）。

#### 2) sealed cookie / KMS 加版本号（`kid`），让密钥轮换不破存量

bullx 的 `kms.ts` 已经有干净的"按 purpose 派生 key"抽象，`sealed-cookie.ts:22` 的 seal/unseal 也集中。但**两者都没有版本/`kid` 字段**：一旦 `ROOT_SECRET` 需要轮换，所有在途 sealed cookie 立刻全部 unseal 失败（用户被踢登录），且 `llm_providers.encrypted_api_key` 这类长期密文无法平滑重新加密。hermes 这块也没有对应（同样无轮换），所以这是**bullx 自身的前瞻性补强**，不是对照发现——但因为 bullx 有 KMS 抽象，加版本极廉价：

```ts
// sealed-cookie.ts —— seal 时写入 kid，read 时按 kid 选 key
seal(payload: unknown): string {
  const envelope = { v: CURRENT_KID, p: payload }     // v=密钥代号
  return aeadEncrypt(JSON.stringify(envelope), key(CURRENT_KID))
}
read(value: string) {
  // 先尝试当前 kid，失败再按 envelope.v 回退到旧 key（轮换窗口内双解）
}
```

`getSecretKey(purpose, context)` 已天然支持把 `kid` 拼进 `context`，所以"老 cookie 用老 key、新 cookie 用新 key"几乎零成本。建议在引入任何密钥轮换流程**之前**先落这个 envelope，否则轮换=强制全员重登 + 存量密文报废。落点：`common/sealed-cookie.ts` + `common/kms.ts`。（注：这是 reality-bias 下的"为下一次变更而设计"，不是当下 bug。）

#### 3) db-schema：set-null FK 覆盖索引已补齐

本期已给 `scheduled_task_runs.conversation_id`、`scheduled_task_runs.trigger_message_id`、`ai_agent_checkbacks.conversation_id`、`ai_agent_checkbacks.trigger_message_id`、`computer_agent_worker_pins.worker_id` 补齐 schema 索引定义。迁移文件需走项目既定生成流程，不在文档中手写。

---

### 结论

bullx 的通用基础设施与数据模型**整体比 hermes 更工业级**：PG 事务性 DDL + drizzle 迁移器、连接池与幂等带超时关闭、KMS 派生密钥 + AEAD 真加密、sealed cookie 内置过期、系统化的 jsonb 安全边界、覆盖全表的 check/部分唯一索引/GIN——这些是 hermes(单机 SQLite) 拿不出的。hermes 在 WAL/损坏自愈/文件系统适配上的大量代码，本质是**补 SQLite 的先天缺陷**，不应被误读成"bullx 缺失的架构"。

日志脱敏、SQL params 收敛、错误分类、jittered backoff、set-null FK 索引已补齐。剩余与底层无关、可继续借鉴的是：**DB 损坏的 fail-closed 理念**（用于 `db-migrate.ts` 与备份策略，而非 PG 热路径巡检），以及在引入密钥轮换前给 sealed cookie/KMS 加 `kid` envelope。


---
