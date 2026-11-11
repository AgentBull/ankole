# OpenBot 与 Ankole：功能、交互和系统边界深度对比

## 1. 阅读范围与结论

本文面向产品、设计和工程负责人，比较 OpenBot 与 Ankole 的终端用户功能、关键交互、管理界面、运行架构和已知限制。比较对象不是官网演示，而是以下两个源码快照：

| 项目 | 快照 | 主要证据 |
| --- | --- | --- |
| OpenBot | `795f619bbc0f1da454adbf9194b8e065dc0de684`，2026-11-10 提交 | 路由、React 组件、服务端与桌面/移动端源码、设计文档、73 项针对性测试 |
| Ankole | `4c2a1f71f2d824b95b910fb456be93fc1c9fb81f`，2026-11-11 提交及同时刻工作区 | Pod、Console、控制面与 Worker 源码、设计文档、76 项针对性测试 |

证据分为四类：

- **实现**：存在真实路由、组件和生产路径，不等于已在当前环境完成端到端验证。
- **测试**：本次执行了源码附带的针对性测试并通过。
- **实测**：本次在浏览器中观察了公开页面或本地启动结果。
- **规划**：官网标记为 Early access、Coming soon、商业版或尚未接通的声明，不计入已交付能力。

「没有对应功能」表示在本次检查的路由、组件和设计文档中没有发现独立等价物，不表示无法通过 API、插件或自定义开发实现。

### 核心结论

两者都提供 AI 同事、会话、工具、定时工作和权限管理，但产品中心不同：

- **OpenBot 是「多 Bot 协作与电脑操作工作台」**。它更适合需要接入多种 Agent 框架、观看并接管远程电脑、处理动作审批、通过语音和移动端继续工作的团队。
- **Ankole 是「AI 与同事共同完成数字工作的协作操作系统」**。它更适合把对话转化为协作文档、结构化数据、业务应用和组织知识，并需要多租户、细粒度内容权限和长期后台执行的组织。

不能用一个「功能总数」判断优劣。OpenBot 的优势集中在操作可见性、人工接管、跨终端和动作治理；Ankole 的优势集中在内容生产力、业务数据、可恢复执行和组织语义。

---

## 2. 产品模型与信息架构

| 维度 | OpenBot | Ankole | 实际影响 |
| --- | --- | --- | --- |
| 核心对象 | Bot、Channel、Routine、Goal、Computer、Learning container | Principal、Conversation、Page、Session、Worker、Brain object | OpenBot 从「找 Bot 做事」出发；Ankole 从「人与 Agent 共同工作并留下成果」出发。 |
| 主导航 | 会话列表；Bots、Routines、Capabilities、Connections；Admin 与 Settings 在账户菜单 | 顶栏搜索；侧栏 Home / Chat；Meta Ankole；独立 Console | OpenBot 管理入口靠近个人工作区；Ankole 将成员工作、内容导航和站点管理明确分层。[O2][A2][A14] |
| Agent 类型 | 内置 Bot、托管 LangGraph/Claude SDK、任意 AG-UI 远程 Agent | AI colleague、personal assistant、system Principal | OpenBot 能把既有 Agent 服务接入同一 UI；Ankole 的身份、权限和执行生命周期由自身控制面统一管理。[O7][A1] |
| 个人助理 | Personal Edition 默认一个 Personal Assistant，也可再建 Bot | 每个正式 Human 可拥有独立 personal assistant | OpenBot 的个人版强调单电脑、免登录；Ankole 的助理继承每个成员的权限和私有上下文。[O12][A22] |
| 工作成果 | 会话中的文本、交互组件、电脑文件、技能和记忆 | Page 文档、Base、工作簿、Applet、Brain 知识、文件和对话产物 | Ankole 把「过程」和「可持续编辑的成果」放在同一权限树中。[A4][A6][A7][A9] |
| 多租户 | 一个部署一套用户与团队配置；tenant package 是品牌/Bot/频道声明包，不是独立客户隔离层 | 一个 Site 多个 tenant；独立 Principal、数据、Brain、连接和 Base 分片 | 面向多客户 SaaS 时，Ankole 的领域模型更完整。[O13][A15] |
| 界面形态 | Web 源码、Mac/Windows 桌面、Expo 移动端的源码；桌面是正式下载入口 | 响应式 Web Pod 与 Console | OpenBot 覆盖更多原生终端；Ankole 没有原生桌面、手机 App 或浏览器扩展。[O12][O14][A2] |
| 可定制外观 | OpenBot、OpenDuet、OpenDots、OpenMuse 四套 skin；tenant package 支持品牌与主题 | 自有 UIKit 与品牌体系，支持受控插件 slot | OpenBot 更适合白标和视觉替换；Ankole 更强调跨页面的一致性。[O18][A14] |
| 技术边界 | React + Hono + PostgreSQL + CopilotKit Intelligence + AG-UI + Bot Computer | Phoenix/Elixir + Rust Kernel + Bun Agent Computer + Function Runtime + PostgreSQL | OpenBot 的持久会话与学习能力依赖 Intelligence；Ankole 的会话、权限、内容和执行事实由自身 PostgreSQL 统一提交。[O1][A1] |

---

## 3. 功能全集对照

下表按用户任务而非宣传分类汇总。相同功能名称不代表相同交互深度。

### 3.1 会话、消息与协作

| 功能 | OpenBot | Ankole | 关键差异 |
| --- | --- | --- | --- |
| 新建会话 | `/channel/new` 的 `To:` 支持多 Bot chips；首个 Bot 写入 URL，首次发送才创建 Channel | 首页助理任务、`/dm/:uid` 同事私聊、群聊、Page 内对话 | OpenBot 以收件人为起点；Ankole 可从个人助理、同事或内容上下文开始。[O3][A2] |
| 会话列表 | 侧栏搜索只过滤已加载的标题、摘要、首条和末条；置顶优先，最近活动排序，未读点和忙碌态 | Chat 分组为置顶、助理任务、消息与同事；服务器搜索、未读/待决策/后台状态、静音 | Ankole 的列表状态更细，且全局搜索能进入具体消息；OpenBot 明确提示未加载历史不在过滤范围。[O2][A18] |
| 群聊 | 多 Bot 顺序回答；`@Name` 指定一个 Bot；每个 Bot 有独立 Intelligence thread，UI 合并公共 transcript | 支持多人、多个 Agent 和 Human-only 讨论；按收件人、显式提及或允许旁听的 Agent 决定接收者 | Ankole 可把「听众讨论」和「点名执行」分开；OpenBot 的群聊主要是多 Bot 工作流。[O3][A3] |
| Bot 间委派 | `message_bot` 有方向性授权、深度和单次扇出上限；答案以被问 Bot 身份回到原会话 | 个人助理把同事作为专家委派，支持 peer exchange、独立轨迹、问题回传和结果合并 | 两者都有归属清晰的委派；Ankole 在 UI 中提供更完整的 peer 执行检查器。[O1][A10][A11] |
| 忙碌时追问 | 当前标签页内暂存；当前 Turn 结束后把所有暂存合并为一个后续 Turn；支持 Stop 后立即追问 | 每条输入可选择 steer 或 queue；支持不同模型不一致时强制 queue | OpenBot 合并连续纠正，Ankole 保留每条输入及其投递语义。[O4][A3][A4] |
| 队列持久性 | 页面组件内存；刷新或切换 Channel 会丢失待发送意图，不是 outbox | PostgreSQL 持久队列，刷新后仍在；可编辑、重排、删除、取回、立即释放 | 这是双方最明显的交互差异之一。[O4][A4] |
| 停止与继续 | Stop 只终止可到达的 run；暂存消息在当前 Turn 结束后运行 | Stop 取消当前 run 并暂停队列；Continue 显式恢复，状态跨刷新 | Ankole 防止 Stop 后队列意外继续执行。[O4][A4] |
| 编辑与重生 | 没有看到用户消息编辑或重新生成入口 | 可编辑历史输入、沿分支重跑、重新生成回复，同时保留已完成的 Page 修改；有版本冲突恢复 | Ankole 更适合迭代长任务而非只能追加纠正。[A3][A4] |
| 输入草稿 | 新会话有独立 history identity；选择收件人后聚焦输入框；失败恢复文字和附件 | 未确认首发保留草稿、附件和请求 ID；Page 与独立会话分别记忆；切回恢复滚动位置 | 两者都处理失败恢复，Ankole 对多草稿和滚动上下文的覆盖更完整。[O3][A4] |
| 附件 | 一对一已存在 Channel 可上传、粘贴、拖放，每条最多 8 个；新 Channel 首条发送后才开放附件，群聊 Composer 未传 `channelId` | 支持附件、Page chip、选区引用、Human/Agent mention、单独附件回答 Clarify | OpenBot 的附件生命周期测试很细；Ankole 把文件与内容引用统一进输入模型。[O3][A3][A10] |
| `@` 与 `/` | `@` 选择 Bot；`/` 调用授权 Skill，并以结构化 chip 发送 | `@` 可引用 Principal 或 Page；`/` 包括新建、邀请、重命名、Page、模型、停止 | Ankole 的补全跨人、Agent 和内容；OpenBot 聚焦 Bot 与技能。[O3][A3] |
| 回复建议 | 支持起始任务建议和语音上下文 | 空闲时生成 ghost reply suggestion，Tab 接受；也支持消息引用、复制、多选导出和分享图 | Ankole 的消息级生产力操作更多。[A3][A18] |
| 语音 | 听写转草稿、实时语音通话、字幕、打断、通话摘要与历史卡 | 没有语音输入或实时通话界面 | OpenBot 独有且区分听写与实时通话两套提供方配置。[O11] |
| 消息呈现 | Streamdown Markdown、交互式 React/A2UI 组件、工具行、引用、表格、图表和决策卡 | Markdown、代码、Mermaid、数学、附件、Clarify form、Action Card、后台执行卡、peer exchange | OpenBot 强调 Agent 返回可交互界面；Ankole 强调工作过程和业务产物。[O18][A10] |
| 历史记录 | Intelligence 持久 thread；合并本地与存储消息；不可读历史明确提示；语音卡单独归档 | 公共 Conversation Message 与内部模型 Response tape 分离；有界分页、未读分隔、滚回原位 | Ankole 不让内部模型轨迹污染公共历史；OpenBot 需要协调 Intelligence 快照和本地流。[O1][A10] |

### 3.2 电脑、浏览器与执行可见性

| 功能 | OpenBot | Ankole | 关键差异 |
| --- | --- | --- | --- |
| Agent 电脑 | Supervisor 模式下每人一个容器，每个 Bot 有独立目录和浏览器档案；也可使用单共享电脑；Isolated Bot 可独占容器 | 每个 Agent 一个专属 Worker，持久 `/workspace` 与可丢弃 cache 分离 | Ankole 默认按 Agent 隔离；OpenBot 的隔离粒度取决于部署与 Bot 设置。[O1][A5] |
| 实时屏幕 | 被动截图轮询；接管时切到 CDP 低延迟 screencast | 没有供用户观看或接管 Worker 屏幕的界面；浏览器主要为 headless 工具 | OpenBot 的远程可视化操作是核心产品面，Ankole 没有对应物。[O6][A5] |
| 人工接管 | Bot 请求帮助或用户主动 Take control；人操作时 Bot 动作被拒绝而非排队；可归还 | 没有同类 Take the wheel | OpenBot 可处理登录、2FA、CAPTCHA 和人工判断。[O6] |
| 远程输入 | 坐标缩放、单击/双击、拖拽出界、滚轮合并、Mac→Linux 修饰键、布局无关粘贴、按键释放清理 | Browser Skill 通过 Playwright 快照、元素 ref 和脚本操作 | OpenBot 是「人直接操作画面」；Ankole 是「Agent 通过语义元素和脚本操作」。[O6][A5] |
| 终端 | Screen / Terminal 双 tab，跟随 Bot 最近活动，用户选择保持到面板关闭；共享同一控制权 | 工具轨迹展示命令、目录、stdout/stderr、退出码和文件 diff，无通用远程交互终端 | OpenBot 提供实时电脑，Ankole 提供可审计执行记录。[O5][O6][A11] |
| 活动记录 | 侧栏 Activity 显示命令、文件读写，重载后消失；正式审计在 PostgreSQL | 执行检查器分页展示持久 Turn trajectory、子线程、结果、等待问题和后续消息 | OpenBot 区分临时活动窗口与正式审计；Ankole 直接把持久执行轨迹交给用户。[O1][A11] |
| 网页读取 | Parallel、Exa、Firecrawl 及浏览器 | `web_search`、`web_fetch`，失败时 Worker Chromium rendered fallback；长文写入 workspace 供继续读 | 两者都有提供方和浏览器路径；Ankole 明确长文预算与续读契约。[O1][A5] |
| 本地文件夹 | 桌面版可授权只读文件夹，写入或命令需逐次确认；重启后授权失效 | Worker 持久 Home、会话和 Job workspace、统一 Drive 挂载 | OpenBot 强调访问用户当前电脑；Ankole 强调 Agent 自己的持久工作区和组织文件。[O17][A5] |
| 交互结果组件 | 内置 gallery 与 Admin Playground 发布 sandboxed React 组件，按 Bot 授权 | Agent 可发布完整 Applet，含前端、后端路由、环境变量、Action、定时与 Webhook | OpenBot 是消息内组件；Ankole 是可独立访问、带业务后端的应用。[O18][A9] |

### 3.3 Agent 创建、能力与模型

| 功能 | OpenBot | Ankole | 关键差异 |
| --- | --- | --- | --- |
| 创建流程 | 右侧宽 Sheet：名称、说明、可见性、应用、Isolated；内置直接创建，外部 Agent 选框架并先测地址 | Meta Ankole 新建 colleague：UID、名称、角色、头像；Console 另可配置 Worker 和完整运行项 | OpenBot 创建流程更具引导性；Ankole 把身份契约与运行配置分层。[O7][A22][A14] |
| 外部 Agent | 任意 AG-UI endpoint，write-only auth header，注册和重定向均做地址检查 | 没有同等的「远程 Agent 作为 Principal」注册模型；提供 Agent key、OIDC、Signal 和 Worker 合同 | OpenBot 更适合汇聚既有 Agent 服务。[O7][A1] |
| Agent 性格 | title、role description；内置 Bot 直接作为 system prompt | AGENTS.md / DESIGN.md 合约，支持全局、Agent、inherit/append/override，并可查看 effective contract | Ankole 的角色与行为约束更接近版本化文档系统。[O7][A21] |
| Skill | 个人与部署 Skill，`/` 调用；可从对话访谈生成，确认卡后才保存；支持指令与工具声明 | Meta Skills 支持新建、ZIP 导入、伴随文件、全局和逐 Agent 绑定；Agent Plugin 还可含 hooks 与 workspace template | 两者都把指令与权限分开；Ankole 的包管理和运行时投影更完整。[O18][A13][A22] |
| 工具选择 | 按 Skill 匹配缩小工具集；超过 50 个时用 `search_tools` 延迟展开；授权、政策和审计不随缩小改变 | 按 Agent Plugin 与 Skill 的启用关系生成运行时工具集；MCP-backed Skill 经统一网关；后台 Job 取准入投影与当前启用的交集 | OpenBot 解决超大工具目录的模型选择问题，Ankole 解决能力所有权和后台一致性问题。[O18][A13] |
| 模型提供方 | OpenAI、Anthropic、Google，另有 xAI/订阅与 OpenAI-compatible 路径；模型目录定时刷新 | 内置 OpenAI、Azure OpenAI、OpenAI-compatible、OpenRouter、Claude、Google AI Studio、ChatGPT Subscription、AgentBull Cloud，以及 Jina、Parallel、Bright Data 等专用能力 | 两者都能换模型；Ankole 将 LLM、embedding、rerank、搜索、抓取和图像生成统一建模。[O11][A16] |
| 模型配置层级 | 部署默认与管理员 allowlist；会话/轮次级选择 | Agent → Pod → Site 的稀疏继承；primary/light/heavy/coding/vision_fallback/web_search/web_fetch/image_generate/rerank；支持自定义 alias | Ankole 更适合按任务类型和成本分层治理。[O11][A16] |
| 模型变更时机 | 下一条消息生效 | 每条输入冻结逻辑 profile；当前 Turn 与后续输入可不同，必要时排队；后台 Job 首试冻结运行投影 | Ankole 对并发模型切换的执行语义更明确。[O11][A3][A16] |
| 凭据池 | 模型凭据加密存储，桌面和部署提供多种连接方式 | 同 Provider 多凭据池，fill-first、round-robin、least-used、random、会话亲和、健康冷却和 OAuth 刷新 | Ankole 的池化与故障治理更系统。[A16] |
| 配额与用量 | Admin 有商业治理声明；源码中有模型 allowlist 与 check-in 限制 | Console AI Usage 与 Agent token quota；Brain 调用独立归因，不消耗 Agent quota | 不应把官网商业功能一概算作开源自部署默认能力。[O2][A14][A16] |

### 3.4 定时、长期目标与后台执行

| 功能 | OpenBot | Ankole | 关键差异 |
| --- | --- | --- | --- |
| Routine | 表单或自然语言创建；小时/日/工作日/周/月；可关联新或旧 Channel | check-back 一次性唤醒、interval/cron、Console 编辑器、多个投递目标 | OpenBot 的 Routine 创建更轻；Ankole 的调度类型与执行 Session 更完整。[O8][A11] |
| 限制与失效 | 最短 15 分钟、每人 20 个启用、连续失败 10 次停用、错过窗口跳过 | 原生唯一槽位、失败历史、暂停/恢复/手动运行、Human 权限版本与吊销处理 | OpenBot 有清晰的疲劳规则；Ankole 更强调持久一致性和权限生命周期。[O8][A11] |
| 长期目标 | Responsibility/Goal：主动或事件触发、暂停、完成、进度与重复目标 | BackgroundAgentJob：长时 Codex 会话、消息、停止、续跑、等待提问、终态通知 | OpenBot 的目标是持续责任；Ankole 的 Job 是可恢复的长任务执行体。[O8][A11] |
| 主动检查 | Check-ins 最多每小时一次、每 Bot 每人每日上限、合并 ping、接受率和跳过原因 | 没有同等的统一「主动发现待办」产品面；有调度、Brain Dreaming、Connector triggers 和 Automation Jobs | OpenBot 更主动找事给人；Ankole 更偏向明确事件和知识维护。[O19][A11] |
| 并发编排 | Bot handoff 有深度和每次数量上限 | Workflow 固定 JavaScript，最多 32 并发、1,024 次 Agent 调用（可再受部署限制），schema 校验、sleep/wake、memo replay | Ankole 提供可持久化的程序式 fanout，而不是只靠模型自由委派。[A11] |
| 业务自动化 | Routine/Goal 调 Bot | Applet Action 有独立 Job、幂等/串行/合并策略、状态、计划、Webhook、运行日志 | Ankole 可不经过聊天或 Agent，直接运行业务自动化。[A9] |
| 恢复 | work_items 队列租约、handoff 重试、线程由 Intelligence 持久化 | Session、Job、Workflow、Schedule、Delivery 均以 PostgreSQL 为提交事实，支持崩溃恢复和 epoch/attempt fence | Ankole 的恢复合同覆盖更多执行类型。[O1][A1][A11] |

### 3.5 记忆、学习与组织知识

| 功能 | OpenBot | Ankole | 关键差异 |
| --- | --- | --- | --- |
| 个人记忆 | 手工事实、Bot 形成、应用导入；按来源支持编辑、确认、暂停、遗忘，Intelligence 记忆仅可编辑与遗忘；标明来源 | 以个人/对话为来源的 Brain claim 与 ambient context pack；没有同等的个人记忆清单页 | OpenBot 的个人记忆管理更直接。[O9][A6] |
| 记忆可见范围 | 手工事实到所有 Bot；Bot 形成的记忆仍受形成 Bot 和来源应用约束 | 按请求人 ∩ Agent，严格房间还 ∩ 所有接收者；source 与 subject 权限独立 | Ankole 的披露边界更细，尤其适合组织知识。[O1][A6] |
| 自动学习 | Intelligence 收集完成会话与 Recorder 轨迹，提议 Skill；审批后发布；可按 Bot 分配容器 | Dreaming 从失败/人工干预 Job 证据提炼 Skill lessons；租约、复核、撤销与再次投递 | OpenBot 学完整流程，Ankole 学带证据的局部经验。[O9][A17] |
| 录制教学 | 浏览器扩展录制操作步骤、叙述并进入个人学习空间 | 没有操作录制器；可由人直接编辑 Skill 或 lesson | OpenBot 独有。[O9][O17] |
| 学习审核 | Proposed skill 可读 SKILL.md、原因和证据，支持批准/拒绝、分享请求和自动批准 | Console 可添加人工 lesson、撤销自动 lesson；自动内容不可直接改写，只能退休再建 | 两者都保留人工控制，但审核对象和发布方式不同。[O9][A17] |
| 组织知识 | Knowledge Bot 与连接文档；`knowledge.yaml` 当前只校验、尚未被读取执行 | Brain 独立知识树、实体/关系/事实/Take/时间线、OKF Markdown、来源追溯 | Ankole 的组织知识是正式领域模型，不只是检索索引。[O13][A6] |
| 知识检索 | Intelligence memory 与来源连接 | BM25 + 向量 reciprocal-rank fusion、可选 rerank、图邻近、时效与 salience、L0/L1/L2 渐进读取 | Ankole 提供可解释的检索深度和证据边界。[A6] |
| 知识维护 | Learning 主要产生 Skill | Dreaming 合并、矛盾检测、Take 评估、schema promotion、实体合并；Console 提供审核和健康状态 | Ankole 有持续知识治理流程。[A6][A14] |
| 数据语义 | 没有同等的原生指标模型 | dataset/metric 对象、绑定 Base 或外部数据库、版本化执行、维度授权、schema drift 检查 | Ankole 能把业务定义变成不依赖模型即兴计算的指标。[A6] |

### 3.6 文档、数据与应用（Ankole 的主要增量）

| 功能 | OpenBot | Ankole | 关键差异 |
| --- | --- | --- | --- |
| 文档编辑 | 没有 Notion 式文档工作区 | 标题与正文连续编辑；H1–H6、嵌套块、任务、列表、表格、分栏、代码、公式、Mermaid、Infographic、Callout | Ankole 把 AI 产出放到可继续协作的正文，而不是只放在消息里。[A4] |
| 实时协作 | 会话实时更新 | 文档 OT、Presence、选区、撤销、IME 合成、并发冲突和恢复草稿 | Ankole 面向多人共同编辑。[A4] |
| 链接与嵌入 | 交互组件在消息中 | URL inline/title/card/preview；内部 Base/File/Applet 活体嵌入；媒体上传；链接 unfurl | Ankole 文档能组合业务界面与外部内容。[A4] |
| 评论 | 会话本身承担讨论 | 正文选区、文件行/表格行/媒体时间锚点评论；@同事可触发内部评论 Session | Ankole 支持围绕成果而非只围绕消息协作。[A4] |
| 版本与回收站 | Bot 软删除后旧 Channel 只读；有重置预览 | 文档/工作簿/知识快照、恢复、Trash、撤销、保留期与永久清除 | 两者的「删除」对象不同；Ankole 管理完整内容生命周期。[A4] |
| 页面权限 | Bot 私有/公开、Team Bot 发布；Channel membership | Page view/contribute/edit/manage/comment 位掩码、继承、单页/容器授权、Guest 隔离、Agent 显式准入 | Ankole 的内容授权显著更细。[A4][A15] |
| Base | 可用 MCP 连接外部数据，但无原生多维表格 | grid、kanban、gallery、chart；13 种字段；关联、公式、筛选、排序、聚合、记录详情和复制 | Ankole 自带结构化业务数据层。[A7] |
| Base 规模 | 不适用 | 小表 inline，超阈值或有 link 时物理分片；字段版本、keyset 分页、乐观并发、局部查询与 PostgreSQL 精确语义回退 | Ankole 不只是 UI 表格，而是完整的持久化与查询系统。[A7] |
| 图表 | 消息内 gallery chart | 9 类 Base chart、Top-N/Other、时间桶、累计、参考线、KPI、点击钻取、缺失字段修复 | Ankole 的图表与数据查询和记录详情连接。[A7] |
| 工作簿 | 电脑可生成表格文件 | `.xlsx/.xlsm` 协作编辑、WASM worker、操作重放与重定基、Presence、版本、公式辅助、图片、筛选、验证、填充、撤销 | Ankole 提供实际编辑器，而非只读预览。[A8] |
| 工作簿限制 | 不适用 | 条件格式与已有图表绘制但不编辑；形状/slicer/pivot 不编辑；部分结构操作不可撤销；默认最大 20 MiB | 评估 Excel 兼容性时必须保留这些限制。[A8] |
| 文件预览 | 活动记录显示路径和大小，不显示保存文件内容 | PDF、图片、音视频、工作簿、PPT 预览与原文件下载；文件替换做对象版本检查 | Ankole 把文件作为可持续工作的 Page。[A4] |
| Applet | Playground 主要服务消息组件 | 完整 React ESM 应用、同源隔离 iframe、前端 SDK、后端 routes/actions、环境变量、密钥、发布与拉取 | Ankole 的自定义业务应用边界更大。[A9] |
| Applet 权限 | 组件按 Bot 与数据函数授权 | 普通能力以当前 Human 执行，admin 能力以 Page owner 执行；读写授权逐次检查，失权即关闭世代 | Ankole 将应用调用接入统一身份与内容权限。[A9] |
| 全局搜索 | 会话列表本地过滤；Audit 可搜索 | Cmd/Ctrl+K 同时搜 Page、Brain、Chat、导航，右侧预览；可定位标题、正文、表格、文件行、工作表、幻灯片、PDF 页与消息 | Ankole 是工作区级搜索，不只是会话过滤。[A18] |

### 3.7 连接、外部渠道与终端

| 功能 | OpenBot | Ankole | 关键差异 |
| --- | --- | --- | --- |
| 应用连接 | Composio、Arcade、Google Drive、Notion、Parallel/Exa/Firecrawl、自定义 MCP | 第一方 GitHub、Linear、PostgreSQL/MySQL/ClickHouse、云连接器目录；MCP-backed Skills | OpenBot 借助 broker 快速扩大应用数量；Ankole 更强调自有 Connector 合同和事件源。[O1][A12] |
| 账户身份 | 个人 OAuth、deployment/shared account；Team Bot 可用 owner 或个人账户 | personal/team application account 分离；应用凭据与个人授权分离；订阅保留原 subject | 两者都区分「谁授权」和「谁执行」；Ankole 对订阅、续期和返回任务的说明更具体。[O7][A12] |
| 授权中断恢复 | Connect card 在会话内引导连接或申请权限 | OAuth return 保留原任务、Applet、Job、scope、draft；成功后可 Return to task | Ankole 把 OAuth 作为任务中断而非独立设置流程。[A12] |
| Slack / Teams | 通过 OpenTag pairing；一次性 `link <code>` 绑定身份，支持审批卡 | 原生 Slack 与 Microsoft 365 adapter，统一 Conversation/Signal/Delivery，支持预览、卡片和渠道能力分级 | Ankole 不需另设 OpenTag 作为 AG-UI 前端；OpenBot 则复用 OpenTag。[O15][A1] |
| 其他 IM | 没有同等多平台原生适配器清单 | Lark/Feishu、DingTalk、WeCom、Telegram、Discord、LINE、WhatsApp、Email | Ankole 的外部渠道覆盖明显更广。[A1] |
| SMS | Twilio 双向短信、号码验证、STOP/START opt-out | Email adapter 有专用邮箱与明确身份绑定；WhatsApp 受 24 小时窗口限制 | OpenBot 有 SMS；Ankole 覆盖 Email/WhatsApp 并保留各平台限制。[O15][A20] |
| 移动 App | Expo 源码包含会话、审批、Needs you、Bot、Computer、Routine、Memory、Rules、Plugins、推送 | 响应式 Web，无原生 App | OpenBot 移动端源码是精简 companion，不等同于桌面全功能。[O14] |
| 桌面 | Tauri 打包后端与前端、本地服务管理、更新、文件夹访问、系统语音识别 | 无原生桌面壳 | OpenBot 安装体验更适合非工程用户。[O12][O17] |
| 浏览器扩展 | Recorder、网页交互采集、教学、语音 narration | 无用户浏览器扩展；`ankole-browser` 是 Worker 内部工具 | 名称相似但职责完全不同。[O9][A5] |
| 通知 | 浏览器、移动推送、SMS、每个 Bot 的通知级别与 Needs you 聚合 | 外部 IM 投递与 Pod 未读/待办状态；无统一原生推送中心 | OpenBot 更适合离开工作区后继续处理。[O7][O14] |

### 3.8 权限、审批、审计与系统管理

| 功能 | OpenBot | Ankole | 关键差异 |
| --- | --- | --- | --- |
| 动作审批 | Allow once、Allow for this conversation、Always allow here、Deny；敏感类别默认询问，管理员可收紧 | 七类 typed Action Card 处理高权限内容变更；Clarify 支持选择、自由文本和结构化表单 | OpenBot 是通用动作治理；Ankole 是带领域前置条件的业务授权。[O10][A10] |
| 审批范围 | 同一 Bot、工具、位置、账户，可扩到会话或永久规则 | 审批卡捕获 sharing/revision/schema/data 等版本；确认时重新验证，过期卡不执行 | Ankole 防止批准期间目标已被并发修改。[O10][A10] |
| 规则引擎 | CEL allow/deny，覆盖 browser/file/shell/MCP、initiator；空策略 fail closed，默认配置显式 allow true | AuthZ CEL 管 Principal 权限；Page/Connector/Worker 有各自领域授权，工具按注册和 Skill/Plugin 启用 | OpenBot 给终端管理员更多动作级规则；Ankole 更强调主体、资源和领域权限边界。[O1][A15] |
| What-if | 管理员用自然语言形成 action，再按真实控制顺序模拟哪条规则决定 | 没有同等的通用动作模拟器；有 WorkAccess review 和权限检查 | OpenBot 适合解释「为什么会允许/拒绝」。[O19] |
| 审批工作台 | Bots 与 Needs you 聚合问题、动作、任务、check-in；可在行内回答或回原会话 | 待处理 Clarify 与 Action Card 位于时间线/独立 dialog，Console 另有 Work Access Review | OpenBot 的统一收件箱更成熟。[O19][A10] |
| 审计 | 允许、拒绝、失败、发起者、无人值守筛选、CSV 导出、拒绝原因和 Why/What-if | Console 可检查 Conversations、Signals、Jobs、Worker、Brain、权限与运行日志；外部 Delivery 失败可人工重试 | OpenBot 的动作审计界面更集中；Ankole 的执行和资源审计范围更广。[O1][A14][A20] |
| 身份认证 | Google、Microsoft、Okta、运行时 SAML/OIDC，按邮箱域路由；SCIM | 邮件 OTP、企业 OIDC、内置 OIDC server、邀请、多账户、逐标签页身份固定、登出与撤销 | Ankole 的浏览器会话模型更复杂，支持一个浏览器多个身份和多个 tenant。[O15][A19] |
| 人员与组织 | People promote/demote/remove；角色、组、能力覆盖；SCIM 离岗撤销 | Human/Agent/system Principal、group、grant、guest/member、offboarding、目录同步和访问版本 | Ankole 统一人与 Agent 的身份和权限。[O19][A15] |
| 凭据 | write-only vault、网站登录密码、外部 Agent auth、IdP secret | Provider/Connector/Applet/WorkerEnv 分层加密，按需解密权限，Worker 只获短 scoped token | Ankole 更强调控制面长期持有秘密，执行体只获短期凭据。[O10][A16][A20] |
| Console | Admin 四组：What Bots can reach/do、Who can get in、What happened | Site Console 四组：Work、Capabilities、Connections、Platform，另有首页 readiness | 两者管理面都完整，但对象不同。[O2][A14] |
| Console 主要资源 | Credentials、Boundaries、Approvals、Computers、Plugins、Providers、Skills、Learning、Check-ins、Components、Playground、People、Permissions、IdP、Audit、What-if | Agents、Drive、Conversations、Background Jobs、Automation Jobs、Schedules、Webhooks、Library、Brain、Worker Envs、Model Profiles、Usage、Providers、Worker Providers、Signals、Identity、OIDC、Workers、Tenants、Access、Settings | 附录 A 给出逐项路由覆盖，避免只看导航首页。[O2][A14] |
| 个人设置 | General、Notifications、Approvals、Browsers、Learning、Setup、Passwords、This computer、Components gallery；个人版另有 Keys/Skills/Computer/Activity | 个人资料与登录方式、Connectors、退出；Pod 管理有 Space、成员、Agents、邀请、IdP、Worker 环境 | OpenBot 给普通用户更多行为偏好；Ankole 区分个人账户与 Pod 管理。[O2][A19] |

---

## 4. 十二条关键用户流程的交互细节

### 4.1 从空会话到第一条可靠回答

**OpenBot**

1. `To:` 初始自动展开 Bot 选择；未选 Bot 也能先输入。
2. 选 Bot 后焦点进入消息框；空收件人按 Enter/Send 不发送，而是重新打开选择并保留文字。
3. 多选即群聊，首个 Bot 保留在 URL；页面自己的导航保留草稿 identity，新点 `+` 创建全新草稿。
4. 首次发送才创建 Channel，因此首条消息不能提前上传附件；需要先发消息，再在已存在的 Channel 中添加文件。
5. 自定义 Agent 必须先通过 endpoint 连通性检查才创建；内置 Bot 创建后等待 1.6 秒成功反馈再进入主页，减少「表单丢失」的错觉。[O3][O7]

**Ankole**

1. 可从个人助理、同事私聊、群聊或 Page 选区开始。
2. 新会话发送前即可添加附件、Page chip、引用和 mentions。
3. 首次请求未确认时，客户端保存草稿、附件和请求 ID；重复打开 New Chat 不会误合并两个未确认会话。
4. 服务端确认后才把草稿归入正式 Conversation；失败可原样重试，成功后才清理对应草稿。
5. `@` 不只是呼叫 Agent：引用 Page 会把内容身份加入输入；提及外部 Human 后，UI 提供显式邀请而非隐式加人。[A3][A4]

**判断**：OpenBot 的收件人引导更清晰；Ankole 的输入内容模型和异常恢复更强。

### 4.2 Bot 已经工作，但用户要纠正方向

**OpenBot**：继续输入会暂存为褪色消息并标注 Queued，可 Remove。当前 Turn 无论完成、失败还是 Stop，暂存消息都合并成一个后续 Turn。发送失败会恢复到队列，并等待用户发起下一次，而不是自动循环重试。队列仅存在当前组件内，刷新或切换频道会丢失执行意图；离开时会释放暂存附件，关闭标签页则由 24 小时清理任务兜底。[O4]

**Ankole**：主按钮按当前状态选择 steer 或 queue，下拉菜单和 `Cmd/Ctrl+Shift+Enter` 提供另一种模式。队列按 Agent 分组，可拖动或按钮重排、编辑、取回、立即 steer。Stop 后队列暂停且跨刷新保留，Continue 才恢复。编辑使用 `expectedVersion`，冲突时保留本地输入并允许刷新或加载服务端版本。[A3][A4]

**判断**：连续几句属于同一个纠正意图时，OpenBot 的合并更自然；需要精确控制每一步、刷新后继续或并行管理多个 Agent 时，Ankole 更合适。

### 4.3 多 Agent 协作与追问

- OpenBot 群聊未点名时所有 Bot 依次回答；每个 Bot 在独立 thread 运行，公共 transcript 标明发言人。Bot A 可将任务交给 Bot B，B 的答案以 B 的身份返回，深度与扇出受限。
- Ankole 可选择具体收件人、`__listeners__` 或允许多个 Agent 旁听；每个 Agent 有独立队列。个人助理委派同事后，原始会话显示 peer exchange，专家的问题直接回传人，执行检查器可切换主线程与子线程。

因此，OpenBot 更强调「一组 Bot 依次发言」，Ankole 更强调「一个助理组织多名专家并可检查、追问和恢复各自工作」。[O3][A10][A11]

### 4.4 观察工具与理解结果

OpenBot 把每次工具调用压成一行：运行中 shimmer；失败、拒绝、尚未执行、由人完成是不同文案；有详情时用原生 `<details>` 展开。连续读取、搜索和列目录可折叠，历史屏幕帧与当前屏幕分开，避免旧回答配上新页面。[O6]

Ankole 把工具分为 Skill、搜索/读取、命令、文件 diff、后台 Job/Workflow、peer exchange。命令可展开工作目录、stdout、stderr 和退出码，diff 有增减行统计；Execution Inspector 还能停止、发送后续消息、回答等待问题、切换子线程并查看最终结果。[A11]

**判断**：OpenBot 更适合顺着会话快速浏览；Ankole 更适合调查和继续操作长任务。

### 4.5 登录墙、验证码与秘密输入

OpenBot 的完整路径是：Bot 请求帮助 → 用户接管屏幕 → 远程键盘/鼠标操作 → 秘密通过专用字段发送 → 归还控制 → Bot 继续。人操作时 Bot 动作被拒绝，秘密值不进入 transcript，审计只记长度和事件。CDP 输入处理覆盖双击、拖拽出界、Mac 修饰键、国际键盘布局、焦点丢失后的按键释放和页面隐藏时帧丢弃。[O6]

Ankole 的浏览器在 Worker 内以 headless 方式执行 Playwright 与 rendered fetch，具有持久登录路由和截图能力，但没有供 Human 接管同一屏幕的产品路径。Worker 替换会清除未持久化的浏览器档案，不能把 OpenBot 的接管体验当作等价能力。[A5][A20]

### 4.6 创建并配置一个能工作的 Agent

OpenBot 的优势是向导和即时默认项：私有可见性、内置运行、已连接应用默认勾选、Isolated 不可用时解释原因、成功动画、返回不丢输入。创建后 Bot 主页继续拆成 Goals、Reaching you、Memory、Approval rules、Routines、Skills and access、Sharing、Setup。[O7]

Ankole 的身份创建更简短，但后续能力面更宽：

- Meta Ankole 编辑 AGENTS.md / DESIGN.md，查看全局与 Agent 的有效合约；
- Meta Skills 管理包内容、文件、绑定；
- Console 选择 Worker provider、模型 profile、配额、环境变量和权限；
- AI colleague 与 personal assistant 都进入 Principal/AuthZ，不是另一套孤立主体。[A13][A14][A16][A22]

**判断**：非工程用户更容易完成 OpenBot 创建；组织需要长期治理 Agent 行为、运行资源和权限时，Ankole 更完整。

### 4.7 定时任务、长期目标和主动工作

OpenBot 把三个概念分开：Routine 是按时间的 standing instruction；Goal/Responsibility 是持续目标，可由事件唤醒；Check-in 是主动查看已连接应用并把值得注意的事项带给人。Routine worker 未运行会在页面显示原因，连续失败会停用。[O8][O19]

Ankole 则区分：

- 一次性 check-back 与循环 cron；
- 独立 cron execution Session，避免长任务阻塞交互会话；
- BackgroundAgentJob 的长时 Codex 工作；
- Workflow 的程序化有界 fanout；
- Applet Action 的业务自动化，包含 schedule、webhook、state、run log，无需经过聊天。[A9][A11]

**判断**：OpenBot 更适合个人「让 Bot 一直关注什么」；Ankole 更适合可恢复的企业后台执行和明确业务自动化。

### 4.8 记忆与学习是否可控

OpenBot 用户可编辑和遗忘个人记忆；由 OpenBot 管理的记忆另可确认、暂停，Intelligence 记忆没有这两个操作。自动学习从会话和 Recorder 进入 Learning container，提议 Skill 后由人或管理员审核。分享个人 Skill 也有独立授权。限制是 Recorder 产生的录像不能从 OpenBot 删除，移除人员也不会删除这些录像。[O9]

Ankole 的 Brain 同时保存文档、事实、关系、时间线和 Take；来源与主体分离，因此公开实体不会自动公开私有证据。Skill lesson 是另一条学习路径：只从具有人工干预、非零命令或本地工具失败的 Job 证据中提炼，要求至少两个 Job 或一个含人工输入的 Job，带 7 天租约和复核。[A6][A17]

**判断**：OpenBot 更适合个人偏好和流程学习；Ankole 更适合组织知识、证据权限和可审计经验积累。

### 4.9 从对话到文档、表格和业务应用

Ankole 在这一点不是附加功能，而是另一条主工作流：

1. Agent 与人通过 Conversation 讨论；
2. 结果写入可协同编辑的 Document、Base、Workbook 或 Applet；
3. Page 权限决定谁能继续查看和修改；
4. Brain 从授权内容中提取带来源的事实、关系和时间线；
5. 后续 Agent 通过 recall、entity、metric_query 等继续读取；
6. 原生 Action Card 处理需要更高权限的创建、修改、分享、删除和加人。[A4][A6][A10]

OpenBot 可以把结果展示为交互组件并保存到 Bot 电脑，但没有同一套 Page 树、协同编辑、Base 查询、Applet 后端与知识图谱。若工作成果需要长期维护，二者不能只用「都能生成文件」来等价。[O18]

### 4.10 外部账户授权如何回到任务

OpenBot 在会话内显示 Connect/Turn on/Set up 卡，个人版连接应用会给所有 Bot 所有工具；团队版按 Bot 授权，并可申请共享账户访问。[O12]

Ankole 在 OAuth 起点记录原 Conversation、Page、Applet Job、scope 和表单草稿，授权完成后移除 URL 中的一次性参数，提供 Return to task 或 Return to automation。旧账户在新授权成功前仍可用，订阅和 Job 关系不会因重连被替换。[A12]

**判断**：两者都把连接放进任务流；Ankole 对授权中断、订阅恢复和原始业务上下文的处理更细。

### 4.11 导航、键盘、可访问性与移动端

- OpenBot 默认 340 px 侧栏，内部滚动；新会话/新 Bot 有明确焦点管理，IME Enter 不提交，Reduced Motion 缩短成功等待；远程屏幕只有获得焦点才接收键盘，Escape 归还本机键盘。
- Ankole Pod 侧栏 236–480 px，可拖拽也能用 Left/Right/Home/End 调整；折叠后悬停临时展开；`Cmd/Ctrl+K` 全局命令，`Cmd/Ctrl+B` 侧栏，`Cmd/Ctrl+Shift+O` 新会话，`Cmd/Ctrl+F` 会话内查找，`Cmd/Ctrl+I` 摘要。
- Ankole 的指针打开右侧面板使用 8 px / 200 ms 位移与淡入，键盘、URL 恢复和自动打开立即完成；Reduced Motion 仅保留短淡入，避免功能操作被装饰性动画拖慢。
- OpenBot 移动 App 是精简原生 companion；Ankole 是响应式 Web，移动端侧栏变 Sheet、右侧检查器变 Sheet、文档分栏在窄屏堆叠。[O2][O6][O14][A18]

### 4.12 错误、空状态和破坏性操作

OpenBot 区分无会话、已加载结果不匹配、历史未加载不匹配；删除 Bot 后旧会话可读但不能回复，Reset 先列出将删除的会话、记忆、Routine、Goal 等数量，并明确共享会话保留。[O2][O7]

Ankole 区分无权限、加载失败、无数据、已删除、离线和冲突；删除确认默认聚焦 Cancel；Dialog 提交中保留输入且禁止关闭；文档保存失败保留草稿，可下载后离开。Base 记录删除不进入 Page Trash，工作簿部分操作不能撤销，这些限制需要在产品评估时单独验证。[A4][A7][A8]

---

## 5. 架构与持久性：相同名称下的不同保证

| 主题 | OpenBot | Ankole | 结论 |
| --- | --- | --- | --- |
| 会话事实 | Intelligence 保存 thread 和 memory；PostgreSQL 保存 Channel、权限、策略、审计等 | 公共 Conversation/Message、内部 Response、Signal、Session 和 Delivery 都在自身 PostgreSQL | OpenBot 需要同时考虑两个持久系统的边界；Ankole 的提交权威更集中。 |
| 待发送输入 | 页内队列，明确不是 outbox | 持久 pending queue 和版本 fence | 不能把 OpenBot 的 Queued 理解为刷新后仍会执行。[O4][A4] |
| 长任务 | work_items 租约、AG-UI run、Intelligence thread | Background Job、Workflow、Session、Schedule、Automation Run 各有持久状态机与恢复 | Ankole 对长任务的恢复语义更细。[O1][A11] |
| 执行隔离 | 可共享一台电脑，也可按人分配；Isolated Bot 独占；共享电脑不是人际安全边界 | 每 Agent 专属 Worker、Home、cache、凭据；Session 只隔离工作目录，不隔离同 Agent 文件 | 两者都明确哪些边界不是安全边界，不能只看容器数量。[O1][A20] |
| 浏览器持久性 | Bot 目录与浏览器档案可保留 | Headless 浏览器状态可能随 Worker 替换消失，除非另挂持久存储 | 登录态和屏幕接管需求会直接影响选型。[O1][A20] |
| 模型历史 | Intelligence thread 与本地流合并，处理重复/不可读历史 | 公共历史与内部模型 tape 分离，工具轮次和 epoch fence 可恢复 | Ankole 更适合需要区分公开叙述与模型内部状态的系统。[O3][A1] |
| 内容事实 | Bot workspace 文件和 Intelligence/PostgreSQL 各自负责一部分 | Page、Base、文件引用、Brain、Skill、Job 都以 PostgreSQL 为事实；对象存储保存字节 | Ankole 的内容权限与业务事务更统一。[A1] |
| 秘密 | write-only vault、审计脱敏 | 控制面加密保存，Worker 只拿 Agent/Turn scoped 短期凭据 | 两者都避免把主秘密直接给模型或 Worker。[O1][A20] |
| 部署依赖 | 必需 Intelligence 项目/license 与模型凭据；桌面可自包含启动 | PostgreSQL、Function Runtime、控制面、按需 Worker；模型与外部 IM 凭据另行配置 | OpenBot 前端单独启动不等于工作区可用；Ankole 的完整验证也需真实适配器和 Worker。 |

---

## 6. 不应误判为等价或已交付的功能

### 6.1 OpenBot 的特殊限制

- **Early access 不等于默认交付**：官网的 Web、iOS、Android、Slack、Teams 有 Early access 标记；源码中确有 Web、Expo 与 OpenTag 实现，但商业托管可用性、发布状态与自部署源码不能混为一谈。[O14][O15]
- **Business 与 Intelligence**：MIT 的是应用模板，Intelligence 单独许可。持久线程、记忆、Automatic Learning、Recorder 审核等必须按其服务与许可验证，不能把 MIT 代码理解为所有服务都无条件免费。[O1]
- **`knowledge.yaml` 尚未执行**：文件会被校验，但当前没有读取它来接通知识源，不能把它算成已完成的企业知识图谱。[O13]
- **活动窗口不是审计**：侧栏 Activity 刷新即失，正式调查要走 Audit。[O1]
- **新频道首条附件**：需先创建 Channel 再上传，不是任何输入框都支持同样的附件操作。[O3]
- **不同聊天入口的能力不同**：`/bot` 使用 CopilotKit 自带聊天，不具备 Channel Composer 的暂存队列；群聊 Composer 也没有传入附件所需的 `channelId`，不能把一对一 Channel 的能力机械套用到所有入口。[O3][O4]
- **粘贴的已知缺陷**：源码明确记录 Google Sheets 和 Numbers 同时带文本与图片的粘贴会附图但丢失文本；另有一处被错误声明类型的图片在 Queued 阶段显示正确、发送后退回文件卡的缺陷。比较「支持粘贴」时应保留这些边界。[O16]
- **移动端是精简 companion**：移动源码可查看和回复、处理审批与管理部分对象，但没有桌面全部交互、富组件和录制体验。[O14]
- **Personal Edition 权限不同**：每个 Bot 获得所有已开启应用的全部工具；不能按 Bot 取消某一个，关闭应用会作用于全部 Bot。[O12]

### 6.2 Ankole 的特殊限制

- **没有远程电脑接管**：Browser Skill 与执行检查器不等于 OpenBot 的实时屏幕、终端和 Take the wheel。[A5]
- **没有原生终端**：没有 Mac/Windows 桌面、iOS/Android App、浏览器 Recorder、语音听写/通话、皮肤系统。[A2][A18]
- **外部投递受平台约束**：流式预览是 best-effort；不确定的最终发送会停下等待人工重试，WhatsApp 还受 24 小时回复窗限制。[A20]
- **浏览器状态**：Worker 替换会清除未持久化的浏览器档案、截图和临时下载。[A20]
- **工作簿兼容性**：已有条件格式和图表只绘制不编辑，部分对象不支持，若保存可能丢弃特定对象；默认 20 MiB 上限，部分结构操作不可撤销。[A8]
- **Base 视图边界**：内置视图为 grid、kanban、gallery、chart；calendar、timeline、自定义 form、多表 dashboard 和多窗格终端应通过 Applet 实现，不能按 Notion 的全部视图类型来验收。[A7]
- **删除语义不同**：Base 记录不是 Page，不能从 Page Trash 恢复；Conversation 删除和 Page Trash 也是不同路径。[A7]
- **检索基础设施**：Brain 要求指定 PostgreSQL 扩展与版本，索引故障不能悄悄当空结果处理；多 Base 分片还需一致的备份恢复点。[A6][A15]
- **内部扩展模型**：Control Plane Plugin 是受信任的第一方代码，不能把 Ankole 理解为已经提供不受信任插件市场或热加载隔离。[A13]

---

## 7. 产品取舍建议

### 7.1 更适合选择 OpenBot 的情况

- 已有多个 Agent 框架或远程 AG-UI 服务，需要统一入口。
- 用户必须看到并接管 Agent 的浏览器或终端，尤其是登录、2FA、CAPTCHA 和人工复核。
- 需要敏感动作审批、CEL 边界、统一 Needs you、动作模拟与集中审计。
- 需要桌面安装、移动 companion、语音、短信、浏览器录制教学和可替换皮肤。
- 主要成果是回答、交互组件、电脑文件和可学习的工作流程，而非协同文档和结构化业务系统。

### 7.2 更适合选择 Ankole 的情况

- 工作结果需要成为长期维护的文档、Base、工作簿、文件或业务应用。
- 多人、多个 Agent 要围绕同一内容协作，并要求细粒度权限、继承、评论和版本。
- 需要持久 steer/queue、后台 Job、Workflow、Applet Action、Webhook 与可恢复调度。
- 需要组织级 Brain、来源权限、知识图谱、指标定义和 Skill lesson，而不仅是个人记忆。
- 需要多租户、统一 Principal/AuthZ、丰富 IM 渠道、模型分层和 Worker/凭据池治理。

### 7.3 双方可互相借鉴，但不应照搬的部分

**OpenBot 可借鉴 Ankole**：

- 将临时追问队列升级为持久、可编辑和可恢复的队列；
- 把消息成果升级为可持续编辑的内容对象；
- 引入分角色的模型配置、凭据池和更明确的执行恢复合同；
- 将知识检索扩展为带权限、来源和关系治理的组织知识。

**Ankole 可借鉴 OpenBot**：

- 增加同一 Worker 的低延迟屏幕与人工接管，而不是只展示工具日志；
- 建立跨 Bot 的统一动作审批收件箱和 What-if 解释器；
- 增加个人记忆审核、录制教学和更易用的首次创建向导；
- 评估原生桌面、移动 companion、语音与浏览器扩展的实际用户需求。

这些建议描述能力差距，不代表应改变已确定的架构所有权。例如，Ankole 若要可视化接管，应复用 Agent Workers、RuntimeFabric 和 Principal/AuthZ，而不是另建一套电脑身份；OpenBot 若要内容协作，也需要先确定 Page、权限和持久化所有者，而不是只新增一个编辑器组件。

---

## 8. 验证记录与证据索引

### 8.1 本次实际验证

| 项目 | 执行内容 | 结果与边界 |
| --- | --- | --- |
| OpenBot 源码与界面 | 克隆至 `temp/OpenBot`，启动 Vite 前端，并浏览 `https://open.bot` | 前端可启动；因未运行 API 与必需的 Intelligence 配置，工作区显示 `Could not load the current user (500)`，未据此宣称完成 OpenBot 工作区实测。公开官网实测确认了 Early access 标注。 |
| OpenBot 测试 | `bun test app/tests/composer-queue-attachments.test.tsx app/tests/composing-enter.test.tsx app/tests/live-screen-mouse.test.tsx app/tests/live-screen-keyboard.test.tsx app/tests/new-bot-sheet.test.tsx app/tests/take-the-wheel.test.ts app/tests/routines-title.test.tsx app/tests/theme-preference.test.ts` | **73 pass / 0 fail**。覆盖队列附件、IME、远程鼠标键盘、创建 Bot、坐标映射、Routine 标题和主题。 |
| Ankole 测试 | `bun test --preload ./scripts/test-preload.ts pod/state/chat.test.ts pod/state/chat-commands.test.tsx pod/state/composer-completion.test.tsx pod/state/sidebar-layout.test.ts pod/base-field-input.test.tsx pod/chat/clarify-form.test.tsx pod/chat/action-card-view.test.tsx`，工作目录 `app/webapps` | **76 pass / 0 fail**。覆盖消息生命周期、队列/编辑冲突、补全、侧栏、Base picker、Clarify form 和 Action Card。 |
| 测试环境修复 | 首次运行时缺少 `@tanstack/react-virtual` 链接，执行根目录 `bun install` 后重跑 | 依赖安装状态修复后全部通过；首次失败不是产品断言失败。 |
| Ankole 本地界面 | 先尝试 `bun dev`，另一长期进程持有 FOSS 构建锁；随后使用文档提供的 `ANKOLE_EDITION=saas bun dev` 独立构建目录，并实际打开 `http://ankole.localhost:4000/` | 服务开始监听端口，但当前工作区其他未提交改动在 `--warnings-as-errors` 下触发 `Compilation failed due to warnings`，首页未能作为产品界面验收。未修改这些无关文件，也不把该结果描述为启动成功。 |

未执行真实模型、真实第三方账户、OAuth、IM、Kubernetes、移动设备和多用户并发测试。本文对这类能力只标为「实现」，不宣称完成端到端验收。

### 8.2 OpenBot 主要证据

以下链接均固定到本次克隆提交 `795f619b`。

| 编号 | 源码位置 |
| --- | --- |
| O1 | [README：主界面与功能](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/README.md#L338-L393)；[架构](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/architecture.md#L30-L99) |
| O2 | [主导航](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/lib/navigation.ts#L82-L145)；[Admin 分组](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/admin/admin-sidebar.tsx#L45-L152)；[Settings 分组](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/settings/settings-sidebar.tsx#L54-L156) |
| O3 | [新建会话](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/routes/_authed/_app/channel/new.tsx#L46-L245)；[群聊语义](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/channels/group-chat.tsx#L38-L49) |
| O4 | [页内队列及持久性声明](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/channels/composer/queue.ts#L5-L53)；[合并与失败恢复](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/channels/conversation-view.tsx#L326-L448) |
| O5 | [电脑面板](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/computer/computer-panel.tsx#L16-L107) |
| O6 | [低延迟屏幕](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/computer/live-screen.tsx#L21-L38)；[鼠标与输入合并](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/computer/live-screen.tsx#L467-L677)；[人工接管与 Activity](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/architecture.md#L143-L161) |
| O7 | [新建 Bot 向导](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/agents/new-bot-sheet.tsx#L82-L360)；[Bot 管理](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/bot-profile/manage.tsx#L172-L377) |
| O8 | [Routines](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/routines.md#L8-L154)；[Goals 列表](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/responsibilities/responsibilities.tsx#L31-L140) |
| O9 | [个人记忆](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/memory/memories.tsx#L42-L364)；[Automatic Learning](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/automatic-learning.md#L1-L109) |
| O10 | [审批规则](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/approvals.md#L1-L117) |
| O11 | [模型目录](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/configuration.md#L295-L313)；[听写与实时通话](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/configuration.md#L315-L402) |
| O12 | [Personal Edition 与桌面](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/personal-edition.md#L37-L98)；[个人版界面和权限](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/personal-edition.md#L165-L218) |
| O13 | [Tenant package 与 Knowledge 状态](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/architecture.md#L382-L398) |
| O14 | [移动端导航](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/mobile/app/_layout.tsx#L15-L51)；[移动会话](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/mobile/app/conversation.tsx#L15-L161) |
| O15 | [SCIM 与 OpenTag](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/configuration.md#L628-L693)；[SMS 与推送](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/configuration.md#L749-L790) |
| O16 | [粘贴限制](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/channels/composer/composer.tsx#L760-L817)；[Queued/已发送图片类型差异](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/components/channels/chat-transcript.tsx#L324-L356) |
| O17 | [本地文件夹](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/personal-edition.md#L130-L149) |
| O18 | [组件、MCP、工具选择与学习](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/architecture.md#L200-L216)；[工具缩小与延迟展开](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/docs/architecture.md#L337-L355) |
| O19 | [What-if](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/routes/_authed/admin/what-if.tsx#L60-L240)；[Check-ins 与指标](https://github.com/CopilotKit/OpenBot/blob/795f619bbc0f1da454adbf9194b8e065dc0de684/app/src/routes/_authed/admin/proactive.tsx#L103-L328) |

### 8.3 Ankole 主要证据

路径均为仓库相对路径；行号对应第 1 节列出的 Ankole 源码快照及当时工作区。

| 编号 | 源码位置 |
| --- | --- |
| A1 | `docs/README.md:5-74`（产品边界与系统图）；`docs/README.md:94-97`（适配器清单）；`docs/README.md:133-150`（消息生命周期） |
| A2 | `app/webapps/pod/app.tsx:94-274`（Pod 路由）；`app/webapps/pod/app.tsx:337-516`（Shell 与快捷键） |
| A3 | `app/webapps/pod/chat/composer.tsx:142-343`（收件人、回答和草稿）；`app/webapps/pod/chat/composer.tsx:568-659`（键盘与 IME）；`app/webapps/pod/chat-commands.ts:202-411`（投递策略） |
| A4 | `app/webapps/pod/chat/queued-strip.tsx:52-292`（持久队列 UI）；`docs/design-docs/PodContentModel.md:27-150`（文档编辑）；`docs/design-docs/PodContentModel.md:457-733`（搜索、导航、Chat 与冲突） |
| A5 | `docs/design-docs/WebTools.md:1-37`（Web 工具边界）；`docs/design-docs/WebTools.md:185-214`（Browser Skill）；`docs/design-docs/AgentWorkers.md:12-38`（专属 Worker） |
| A6 | `docs/design-docs/BrainV3.md:1-82`（知识、权限、检索与学习）；`docs/design-docs/BrainV3.md:84-188`（dataset、metric 与 drift） |
| A7 | `docs/design-docs/PodContentModel.md:1921-2306`（Base 全量合同）；`app/webapps/pod/base-field-types.ts:17-60`（字段类型） |
| A8 | `docs/design-docs/PodContentModel.md:2403-2737`（工作簿、协作、公式、限制） |
| A9 | `docs/design-docs/PodContentModel.md:2739-3142`（Applet 全量合同）；`docs/design-docs/AutomationJobs.md:70-176`（调度、Webhook、Actions） |
| A10 | `docs/design-docs/Conversations.md:984-1143`（Clarify、Action Card、版本前置条件）；`app/webapps/pod/chat-page.tsx:586-814`（时间线、检查器、删除） |
| A11 | `docs/design-docs/BackgroundAgentJob.md:41-247`（Job 工具与通知）；`docs/design-docs/Workflow.md:1-139`（编排与休眠）；`docs/design-docs/Schedule.md:190-244`（独立 cron Session） |
| A12 | `docs/design-docs/Connectors.md:129-223`（个人授权、返回任务、重连）；`app/webapps/pod/connectors.tsx:293-700`（连接页交互） |
| A13 | `docs/design-docs/Plugins.md:11-67`（Agent Plugin 与内置包）；`docs/design-docs/Plugins.md:113-203`（能力启用与运行时投影） |
| A14 | `app/webapps/console/app.tsx:130-421`（Console 路由）；`app/webapps/console/console-shell-chrome.tsx:84-126`（管理导航） |
| A15 | `docs/design-docs/Tenants.md:1-149`（租户、分片与生命周期）；`docs/design-docs/Tenants.md:289-350`（Site Console 与数据上下文） |
| A16 | `docs/design-docs/AIGateway.md:52-151`（模型继承与冻结）；`docs/design-docs/AIGateway.md:321-488`（凭据池与健康）；`app/webapps/pod/model-controls.tsx:63-133`（会话模型选择） |
| A17 | `docs/design-docs/SkillLessons.md:1-143`（Skill lesson 完整生命周期） |
| A18 | `docs/design-docs/PodContentModel.md:457-674`（搜索、导航、动效与可访问性）；`app/webapps/pod/sidebar.tsx:45-351`（双 tab、快捷键与侧栏调整） |
| A19 | `app/webapps/auth/app.tsx:38-163`（登录与身份选择）；`app/webapps/setup/app.tsx:71-210`（初始化步骤）；`docs/design-docs/BrowserSessions.md:1-81`（浏览器身份与有效期） |
| A20 | `docs/TradeoffsAndKnownLimits.md:51-94`（投递、模型与恢复限制）；`docs/TradeoffsAndKnownLimits.md:117-143`（浏览器与长任务边界） |
| A21 | `app/webapps/pod/meta-agents.tsx:36-316`（Agent 身份与合约）；`app/webapps/pod/meta-skills.tsx:26-280`（Skill 包管理） |
| A22 | `app/webapps/pod/meta-skill-bindings.tsx:30-152`（全局与逐 Agent 绑定）；`app/webapps/pod/meta-agents.tsx:166-214`（个人助理与设置） |

---

## 附录 A：路由覆盖清单

这份清单用于防止把「首页可见功能」误认为全部功能。动态路由合并到其父项。

### OpenBot

- **会话与主页**：`/`、`/channel/new`、`/channel/:id`、`/bot`、`/group/new`、`/group/:id`、`/start/:startId`、`/s/:screen`。
- **Bot 与个人工作**：`/bots`、`/bots/:id` 及 `activity/setup/responsibilities/reach/memory/approvals/routines/access/sharing`；`/agents`、`/team-bots`、`/responsibilities`、`/reachability`、`/memory`、`/skills`、`/routines` 与新建页、`/approvals`、`/capabilities*`、`/connections*`、`/browser`。
- **Settings**：General、This computer、Setup、Passwords、Notifications、Memory、Learning、Connected accounts、Components gallery、Browsers、Approvals；个人版 Skills、Plugins、Credentials、Computer、Activity。
- **Admin**：Overview、What-if、Skills、Providers、Proactive、Plugins、Playground、Permissions、People、Learning、Identity providers、Enterprise、Credentials、Computers、Components、Boundaries、Audit、Approvals。
- **其他**：Onboarding、桌面返回、登录与 SSO 请求页。

### Ankole Pod

- **会话**：`/`、`/dm/:colleagueUid`、`/conversations/:conversationID`。
- **内容**：`/pages/:pageID`、`/content/:scope`，其中 scope 覆盖 all、space、private、shared、recent、favorites、trash、search。
- **Meta Ankole**：`/meta/brain`、`/meta/brain/:pageID`、`/meta/skills`、`/meta/skills/:slug`、`/meta/agents`、`/meta/agents/colleagues/:uid`、`/meta/agents/assistant`、`/meta/agents/global`。
- **账户与组织**：`/me`、`/connectors`、`/settings`。
- **初始化与认证**：Setup 的 bootstrap、plugins、industry、identity；Auth 的登录、邀请、身份选择、OIDC 与退出。

### Ankole Console

- **Work**：Agents、Drive、Conversations、Background Agent Jobs、Automation Jobs、Schedules、Webhooks。
- **Capabilities**：Agent Library 与 Agent Plugin detail、Brain objects/claims/contradictions/merge suggestions/sources/suggestions/search preview/principal audit/health、Worker Envs。
- **Connections**：Model Profiles、AI Usage、Providers、Worker Providers、Signals、Identity 与 mappings、OIDC Clients。
- **Platform**：Workers、Tenants、Access groups/principals/grants、Settings。
- **扩展**：受控 Console Plugin slots 可注册额外导航、路由与设置页；是否出现取决于实际启用的插件。
