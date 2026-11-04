# 上游语义复核与重复实现裁决

本轮以用户批准的产品意图为准，复核 FOSS `b33126b5e..dfb6ed9c0`（PR #151）与 SaaS `4325a43..8dd71fd`（PR #17）。两仓均已获取上游并快进合并；`Signals.md` 的文本冲突同时保留了上游 Connector 域链接和本地明确的来源引用格式。

判断标准是全项目的净收益：包括用户体验、操作成本、维护成本、运行开销与回归风险。收益小但为正的项目仍实施；没有把“只影响当前用户主流程”当作筛选条件。代码相似只是候选证据，不能替代等价性或领域所有权分析。

## 基线与上游结论

| 用户指定基线 | 本轮保持的合同 |
| --- | --- |
| `connectors_and_toolkits_design.md` 第一部分定稿基线 | Connectors 持有外部连接与凭证；精确账号和工具路由、渐进授权、自动化接入走真实运行路径。 |
| `MetaAnkoleArchitecture.zh.md` | Meta 从当前 Pod 可直达和刷新；Brain、Skills、Contracts、Agent 定义按各自域归属；普通 Drive 内容披露遵守文档中的会话权限交集。 |
| `signal_action_foundation_design.md` | 事件源与消费者正交；Applet Actions 由 Function Runtime 执行，Job/Signal/Run 持久事实归 PostgreSQL。 |
| `WorkerDriveFuse.zh.md` | Worker 通过真实 Drive/VFS 合同读取内容；后台 web_fetch 落盘到该 Job 的真实工作区；停止命令终止其进程组。 |
| `SystemServicePrincipals.zh.md`、`PrincipalUid.zh.md` | 系统服务主体与协作 Agent 的职责不同；身份仍为当前租户内有含义的 uid，不增加并行身份或授权模型。 |
| `personal-assistant-and-ai-colleague-rfc.md` | 保持个人助理与 AI 同事的身份/工作权限投影，异步 Agent 加载不抢占用户已经选择的导航。 |
| `ankole_9_features_implementation_plan.md` | 输入法、后台任务、文档和真实工具读取的端到端行为优先；不能以局部测试通过替代用户看到的结果。 |

逐组源代码与实证复核没有发现需要撤销的上游生产修复。上游为合法深层文档补齐 JSON/NIF 传输、修复 IME 与远程编辑、维护 Worker 停止/读取路径以及 SaaS Meta 路由，均与上述基线一致。下面记录保留理由和本轮发现的真问题，避免把合理 QA 修复当作设计误解。

本地历史文档把整个 `automation_jobs` 表写成已移除，已纠正为当前持久 Job 表与 Applet Action 执行合同。删除原型后的文档引用指向现有 UIKit/Pod。普通 Space 列表必须隐藏独立 Brain 根；过时的测试期待已改为验证普通列表、Brain 独立根和访问权限三个真实合同。

## 上游逐组复核

### 上游 control-plane / SaaS 语义复核

范围：FOSS b33126b5e..dfb6ed9c0（a8bab3925 / PR151）；SaaS 4325a43..8dd71fd（69d1555）。逐个检查此范围全部 9 个 control-plane 生产文件和 SaaS router。结论：这些更改没有发现应撤销的需求误解；以下合理修复保留。Worker、Kernel JSON 实现和 UI 的端到端结论由相应审查覆盖。

| 上游改动 | 基线和具体路径 | 判定 |
| --- | --- | --- |
| provider_configs.ex 为 enabled OIDC client 的 model_aliases 增加 provider 引用 | 模型供应商属于 site；机器客户端仍在 tenant 内引用它。停用/删除已被启用客户端使用的 provider 会破坏该客户端已配置生成能力。查询使用 site 范围逐租户列出引用，未将连接器租户应用密钥改成共享密钥。 | 真缺口修复，保留；不是把 Connectors 的精确账号路由套成模型供应商 fallback。 |
| brain/synthesis.ex 将 recall claims/chunks 经 JSON.plain 再编码 | 查询已在 Brain 的披露上下文中过滤，结构化资源需投影为 JSON 值才能合成。plain 不替代授权、不改变查询可见范围。 | 合理序列化修复。 |
| json.ex 转向 Kernel.JSON | 此文件只切换统一 codec；结构投影仍通过 plain，二进制 iodata 也是合法 iodata。 | control-plane 调用无语义回退；实际 codec 数字与对象行为由 Kernel 审查负责。 |
| pod/pages/browser.ex snapshot_id optional access、knowledge_panel APIError.result | 未传 snapshot_id 时允许导出当前知识；缺失/无权限返回 API 错误，不能抛 KeyError 或形成错误响应体。 | 合理修复。 |
| pod/rpc_broker.ex bindings.list 的来源和 Job Page 披露检查 | MetaAnkoleArchitecture.zh.md §5.2 明确普通 Drive 与 Brain 都按会话提问者∩Agent/群聊披露，只有 Skills/Contracts 仅用 Agent。领域授权仍由 Signals/EventBindings + AutomationJobs 持有。新测试分别证明私有 Applet/Base、job_id 及每个来源可见性；个人助理继续按 Human 工作权限投影。 | 保留。把 Agent 的领域访问权当作可直接向任意提问者披露，是假阳性修复建议。 |
| sessions/read_tool_broker.ex 和 tools/web.ex 的 workspace page 模式 | 后台 Job 逐 URL 请求与 Worker 文件落盘；只有显式 workspace 模式返回最多 2M 字符全文，普通主 Agent 路径保留原窗口。_workspace_page 在验证模型参数前取出，依然校验/授权原 URL 列表，最终仅抓选中 URL。 | 与 9-features 后台文件读取意图一致；跨 Worker 的完整落盘/截断由 Worker 审查。 |
| workflow_task.ex Brain readonly allowlist get_page -> entity | Meta Brain 的 entity 是实际公开只读查询操作，旧 get_page 不再是当前工具操作。 | 修正过时 allowlist，保留。 |
| signals/event_bindings_browser.ex typed map 返回声明和 binding_json | 返回当前 UI 使用的 Binding 可编辑字段；省略 Ash 元数据/内部 tenant 字段。值来源保持同一 Binding，未引入额外授权实体。 | 合理 API 投影；不能因为字段声明同形就合并资源所有权。 |
| SaaS router.ex pod_spa_path? 加 /meta 和 /meta/* | MetaAnkoleArchitecture §1 用户入口必须可从当前租户访问、刷新和直达。SaaS Pod host 判定若不含 Meta 路由会落入错误 host/path 分支。 | 合理补齐，保留；与 FOSS 同一 Meta 入口。 |

没有为猜测风险增加安全门禁、确认步骤或新持久状态。此结论来自当前代码/真实测试路径和用户给定基线，不代表未执行的 live-provider E2E 已通过。

补充：广测发现 `pod/pages_test.exs` 的历史断言仍把 Brain 根放在普通 Space 列表中，属于早期用户故事残留的测试期待，生产查询已经符合 Meta 基线。本次纠正测试并同时校验独立 Brain 根读取仍保留可见性，而非修改正确的生产隔离。该断言不是本次上游新增。

### Worker 与浏览器上游复核

比较范围：`b33126b5e..dfb6ed9c0`，上游实现提交 `a8bab3925`。逐文件检查 AgentComputer 9 个文件、ankole-browser 4 个文件，以及 ReadToolBroker / Tools.Web 的跨运行时接口。

结论：这一组上游改动没有证据表明旧 QA 误解或撤销了近期 Connectors、身份、Drive、Skills 与个人助理需求，保留全部改动。下面区分实际实现和不应追加的要求。

| 改动组 | 已批准契约及实证 | 判定 |
| --- | --- | --- |
| Job 大网页落入 workspace；补充 read_file | 个人助理 RFC §1、§4.1、§5.2 要求完整独立 Worker、后台 Job、持久 workspace；DriveFuse 要求 Job 使用固定 requester/conversation 的 scoped 执行环境。`job/setup.ts` 创建同一个 ContainerComputer，web_fetch 写文件与 read_file 都使用该 scope；写文件通过 `computer.runCommand` 按 Agent UID 执行，未从 root 绕过 Drive。 | 保留。文件失败返回明确的 excerpt/file_unavailable；调用者可以重试，无新增恢复协议。 |
| Job 返回 40,000 code points、保存至多 2M、给出中间部分读取参数 | `web-fetch-result.ts` 对 batch 分配总预算，按完整 Unicode code point 切割，保留头尾，返回实际 workspace 路径与 read_file offset；读不完的超长行给 shell 读取指引。projection 的工具专属上限防止二次裁剪吞掉 continuation。主 Agent 的原有字节窗口仍由 Tools.Web 持有。 | 保留。两种运行形态的可用资源不同，不要求统一返回形态。无权把未承诺的无限网页抓取加为 blocker。 |
| `_workspace_page` 单页传输与缓存 | ReadToolBroker 先从 args 取出内部索引，仍对完整原始 URL batch 做 schema 校验和 Tools.authorize_call，之后才缩成单页执行；Worker 仅回传当前页缓存，rendered continuation 不重复旧 cache。 | 保留。没有把授权移到 Bun 或把完整批量授权降成任意单项。单页大文本不占持久事实，仍是 rebuildable cache。 |
| rendered fetch 扩展 workspace result_mode | BrowserMaterial 的 SSRF/navigation/backend 仍由原 owner 判定。workspace 模式明确限制单 URL、UTF-8 字节上限，并校验 total/stored/tail；normal 模式保留其原来用途。browser-client 和 daemon 共同使用 16 MiB 上限，服务端以明确失败响应代替断管。 | 保留。无新权限模型，无暴露真实连接器凭据。 |
| Workspace rendered continuation 仅回 details、显式报告超大 frame | 控制面从 details 读 continuation，删除同页 text 的第二份 JSON 可避免一个有效页面因冗余副本超 frame。`frame_too_large` 对该内部工具返回明确错误，其他执行事实仍保留 workspace 用于 Driver 重取。 | 保留。契合 RuntimeFabric 的 Driver/Worker 分工，不应将其改回旧单驱动假设。 |
| command abort 杀 process group | DriveFuse 的 scoped launcher 先建 mount namespace，再等待真正命令；spawn 已 detached，杀 launcher pid 不能保证内部前台命令收到 TERM。`killProcessGroup` 对同一前台进程组发送 TERM，仍保持既有生命周期所有权。 | 保留。与 Drive launcher 最新实现吻合，而不是旧 QA 误删隔离层。 |
| Browser newPage 进入 try/finally | 页面创建失败也作为该 URL 的失败记录，成功创建的 page 才 close；不因一个 URL 创建失败破坏整个 batch。 | 保留。属于局部正确性修复，无新业务限制。 |

具体修复发生在重复清单复核，详见 `/tmp/ankole-dup-worker-ledger.md`。其中 browser generation 的 object-key-order 错判来自已有两端不一致：materializer 用 canonicalJSON 哈希，daemon 用 JSON.stringify 比较；并非本次上游新引入的问题。

验证：Docker Worker unit 最终 477 pass / 0 fail；真实 Chrome integration 19 pass / 0 fail；browser unit 43 pass / 0 fail。上游新增的长页、Unicode、最坏 JSON 转义、超大 frame 拒绝及动态 read_file 续读案例均保留并通过。详情与命令见 duplication ledger。

### 上游 Kernel / 编辑器 / Pod 导航语义复核

范围：FOSS `b33126b5e..dfb6ed9c0`，实质提交 `a8bab3925`。以用户列出的定稿基线、Meta Ankole 四域边界、PrincipalUid、WorkerDriveFuse、`ankole_9_features_implementation_plan.md` 的工作空间计划和当前 `PodContentModel` 为合同，逐组检查生产调用与新增测试。

本范围没有发现“上游因旧用户故事误解新设计”而应回退的改动。以下修复均保留；不把已修复故障再次列为待修问题。

| 上游改动 | 实际合同、失败路径与后果 | 判断 / 处理 |
| --- | --- | --- |
| `Kernel.JSON` / `Ankole.JSON` 有界深 JSON | 文档128层树的 change JSON同时含对象与数组，超过Torque默认容器深度，但仍是合法文档。普通HTTP响应与NIF传输必须能载送。新codec普通输入仍走Torque，深输入OTP JSON，统一512容器边界；tests覆盖512/513、非法叶子、重复键、trailing data、tuple object。 | 合理修复；未增加第二个持久数据主人。控制面继续是提交权威。保留。 |
| `Kernel.page_apply/page_diff` 与 Rust `decode_changes` | 用户/Worker合法嵌套页面变更跨Elixir/Rust边界必须一致。page_apply用新codec、page_diff返回亦用新codec；Rust在大小与512深度检查后禁用serde默认128递归上限，文档树自身128层限制仍独立校验。 | 合理修复；不是放开无限递归或修改Page schema。保留。 |
| VFS/page/knowledge NIF `stacker::grow` | WorkerDriveFuse支持真实文档与knowledge转换，合法128层树在dirty scheduler较小native stack上会溢出。扩大仅执行递归原语的native stack；Elixir term decoding在外层。 | 合理修复；不修改Drive只读Meta投影/控制面写入边界。保留。 |
| core input/editor composition completion | IME的原生compositionend和DOM flush不是同一时刻；过早清除composing或reconnect不刷新会丢中文候选/选区。新增completion阶段等待DOM接受模型，disconnect保留待完成状态，focus/flush正确排序。 | 合理修复；维护用户中文输入这一既有合同。保留。 |
| block-selection / compositionHost / columns/list cleanup | 选中标题、列表、多列块后输入中文，结构修正会拆掉IME仍占用的DOM Text节点；远端输入/点击又会移动当前selection。将原始composition host经changes映射，结束后仅清理其祖先，避免按新selection删别处内容。 | 合理修复；新Field是现有编辑器事务状态，非持久实体。保留。 |
| history preserveEmpty composition group | IME产生空中间步骤时历史group被剔除，后续结构cleanup可能并到上一次无关编辑，undo误删用户内容。保留正在组合的空group使一次输入和修正构成一个undo。 | 合理修复；符合一轮输入一个撤销步骤。保留。 |
| collaboration暂缓composition期间结构纠正 | 远端patch仍立即rebase、局部映射仍更新；只延后会拆DOM的结构修正到composition complete，再走既有提交。这不改变服务端canonical XML权威。 | 合理修复；没有把未确认本地状态当持久事实。保留。 |
| host embed callbacks延后、重映射、独立undo | Mermaid/资源嵌入配置异步回调可能正好发生IME期间，立即替换widget会断输入；disconnect/read-only旧回调又可能写入新界面。按widget DOM关联当前position，结束后以独立history事件应用；卸载/只读丢弃旧回调。 | 合理修复；不影响Agent权限、共享边界或文件上传owner。保留。 |
| Pod sidebar effect移除agents异步结果依赖 | 用户键盘从Chat切Home后，延迟到达的personalAssistantAvailable会重置所选tab。Meta设计规定独立入口与路由联动，不意味着后台agents响应应抢回用户导航。 | 合理修复；desktop/mobile实际浏览器单测2项通过。 |
| OpenAPI/生成客户端 | 本次前端范围内仅跟随控制面端点声明，无独立客户端数据模型；未手改生成物。 | 保留；控制面语义由对应审查分支核查。 |

实证：编辑器单测1203项通过；Chromium/WebKit composition、host-composition、embedding共90项通过，48项是测试原先显式skip；Sidebar真实组件+HTTP边界浏览器单测桌面/移动2项通过。Kernel page_document专项52项通过、1项既有ignored（包含本轮新修复的knowledge属性空白保真，见dup ledger）。未把浏览器HTTP夹具单测当作真实控制面集成；完整Pod后端流程由主agent另跑。

#### 实测复核：撤销 / 重做与刷新

上游的两个real-Pod IME用例初次失败在“刷新后revision应保持不变”。Trace显示9612ms协作状态为saving，9829ms HTTP快照仍是revision 4，9923ms已触发reload；重载首次GET返回revision 6，XML与revision 4相同。redo结果天然与undo前XML相同，因此原XML轮询并不证明undo/redo已经提交。既有PageCollaboration只在sent和pending均清空时发布saved，生产行为正确。

修正测试在redo和reload后等待真实UI的saved状态，随后继续断言同一XML与同一revision；没有删除或放宽revision断言。真实Pod commit/cancel两项复跑均通过（8.8秒，`/tmp/ankole-ui-audit-final.log`）。这属于测试同步误判，不能据此回退协作/IME修复或另加写入恢复协议。

## 重复清单逐项裁决

以下 `L` 编号对应末尾原始候选清单的原行号。按职责拆分的表格共同覆盖原清单 §1–§9；汇总建议不重复计为新问题。

### 重复实现逐项判定：Elixir 核心

对照 tmp-duplication-findings.md 原始行号。依据：同一个算法和合同才收口；局部省行而增加跨领域依赖、策略参数或隐藏主体的不算正收益。低但正的维护收益仍落实。未改项不是因为用户不可见，而是下述具体成本或语义差异。

#### §1 已有主人

| 原行/发现 | 判定、落地或不改理由 |
| --- | --- |
| L23 ISO8601 | 正 ROI，十处调用统一 Attrs.parse_datetime；nil/空字符串缺省、Unix 秒、相对 expiry、必须未来时间、调用方错误分别保留。ActionCard 比较进一步合并同文件 updated_at_matches?。credential_pool 的 reset timestamp ISO 分支也复用同一解析器。 |
| L24 时区时钟 | 正 ROI，TimeZone.format_instant/3 负责解析/shift/format，两处 Prompt 调用；UTC 归一化仍由 TimeZone.normalize，invalid 返回 nil，不改业务时区。 |
| L25 URL-safe token | 正 ROI，Session/AgentWorkers/Relay/Webhooks 复用 SecretDigest.token；Webhook 的 wh_ 前缀留在调用方。 |
| L26 邮箱形状（Elixir 3 处） | 正 ROI，统一 HumanUser.email_format；不增加更严格的邮箱语法。前端由 UI 任务处理。 |
| L27 UTF8 filename prefix | 正 ROI，Files.Path 复用 Text.utf8_prefix；文件名净化仍由 Files.Path 负责。 |
| L28 UTF16 | units 正 ROI delegate Text.utf16_length；slice 不合并，越界返回 nil 与坏 surrogate 替换不是同一合同。 |
| L29 Retry-After | 报告的直接替换是假阳性：Connectors 要完整整数且负数 clamp 0，IMTransport 接受整数前缀并保留负值；credential_pool 的 HTTP-date 已调用 Req.Utils.parse_http_date。更换会改变失败/冷却行为，保留。 |
| L30 本地回跳 | 真缺口且正 ROI：OAuth /\\ 可作为浏览器非本地目标；Session.safe_return_to 增加可选 fallback，OAuth 使用 nil，其他登录沿用 /。真实 OAuth.begin→cancel callback 测试覆盖有效回跳、//、/\\ 和 nil。 |
| L31 Origin 拼接 | 正 ROI，BrowserCSRF 调 RequestHost.origin，代理归一化出处唯一。 |
| L32 Provider id | 相同 trim/downcase 的 Providers 函数已委托 ProviderConfigs.Provider 收口；其它身份提供方/external binding 的名称空间与是否 downcase 不同，保留正则。不存在一个跨域 Provider 身份。 |
| L33 工具公开路径 | 正 ROI，由 ToolContract.public_path/2 所有，ProgrammaticToolCalling 不再复制。 |
| L34 UTC SQL | 正 ROI，Formula 复用 Query.utc_timestamp("(sql)")，保留公式表达式括号。 |
| L35 principal XML mention | 正 ROI，Mentions.principal_uids 统一同一 regex+scan，Comments 与 Mentions 使用；Markdown 和 page mention 仍各自解析。 |
| L36 WebDAV 路径段 | 不能将遍历已有路径的协议解码替换为创建/改名规则：Path.valid_segment? 另要求 255 字节及全部控制/双向符过滤。强行统一会缩窄可寻址路径；当前解码先拒绝斜杠/NUL/点段，创建仍走 owner 校验。保留。 |
| L37 Content-Disposition | 插件/IMTransport owner 由 root 处理。 |
| L48 chatgpt optional_text | 正 ROI，复用 MapHelpers.optional_text。Webhook compact_map 是一个标准库 Map.reject，不为换名字增加插件依赖（与 §8 同一结论）；Schedule 对显式 nil 拒绝，不能替换 optional_boolean。 |
| L53 HTML/XML escape | 正 ROI，两处用 Phoenix.HTML.html_escape |> safe_to_string。对 XML 字符的编码等价，也正确编码 apostrophe；不引入库。 |

§1 的 TypeScript/Rust 项由 Worker/UI/Kernel owner 分别判定，非本表遗漏。

#### §2 成段算法与相邻副本

| 原行/发现 | 判定、落地或不改理由 |
| --- | --- |
| L68–70 Brain pack rendering/budget | 局部同形但不可等价整体替换。实查另发现 WakeBriefing non_empty 会 trim，HostedBrain non_empty 保留非空原文；后者逐行 recalled-memory 边界，前者整块标签且支持取尾；剩余 token、换行、悬空 header 收尾不同。为抽取相同拼接引入 formatter/预算策略参数抵消收益，保留（double check 后撤回尝试的统一）。 |
| L74 response items outputs | 正 ROI，已有 Delivery.ToolOutput 新增 outputs/last，统一 tool call id 关联、顺序、解码、错误短路。ActionCard/Clarify 的字段校验继续各自实现；Attachment 收集全部，前两者取最后有效结果。 |
| L78–80 Job/Workflow UTF8 window | SQL 不是相同存储表达式：Job 是 JSON result->output_text，Workflow 是 result_text 列；输出形状、16K/8K窗口、状态与错误名不同。共享查询/窗口框架会隐藏持久模型差异；底层 UTF8 prefix 已共用，保留领域入口。 |
| L86 advisory lock key | 幂等标识命名空间是各领域创建合同。拼接和 AdvisoryLock.lock 已是标准 primitive，再包模块/回调不减少复杂度；保留。 |
| L87 unknown create keys | 标准集合差集+排序，允许字段和错误类型各域独立。新增通用创建验证器需要错误/列表等策略，收益不为正；保留。 |
| L88 error code/summary | SQL left 在数据库避免加载大型 JSON；Workflow 先将非字符串 JSON.encode 再截取。不能为了共享改成本地加载或改变输出类型；保留。 |
| L89 id cursor | 稳定单调整数 id 的分页本身正确；换 opaque keyset 不带来该流程所需保证却改变接口和调用者。共同的 sort/limit 为声明性查询，保留。 |
| L90 UTF8/nonblank/NUL | 不能换 Attrs.required_text，因为需原样保留。三个入口只有标准 guard/谓词组合，错误与空附件路径不同；新增“合法业务文本”泛化会给文本命名过强共享语义，收益不为正，保留。 |
| L91 NFKC | Links 的别名匹配与 SkillLessons 的撤销免疫索引都四步规范化，但它们各自的持久匹配语义可以独立演进；Claims 没有 NFKC。将其包装为通用命名会掩盖不同标识匹配协议，现有明确4行不构成维护负担；保留。 |
| L92 page excerpts | 正 ROI，批量 PageContent 查询和 300 字符投影统一到 Pages.Queries.excerpts_by_id；Mentions 先按自己的可见性过滤，再传已授权 pages，权限主体不变。 |
| L93 SQL every word | 两条 raw SQL 使用同一条件但分别属于 state/trashed 查询，第三处是 Ash expr。抽成 SQL 字符串拼接只能省两行而使完整 SQL 不可直读，无法与 Ash 编译表达式安全统一；保留。 |
| L94 user text message | 这是 Responses 协议 literal，不是四份状态机；列表/输入校验不同，包 helper 不减少协议构造步骤且增加跳转。保留。 |
| L95 provider_options nonempty | 三处仅 map 可选字段控制；字符串/atom键入口不同，统一需维持现有 options 对象及缺省。没有重复算法要删除，保留原字段构造。 |
| L96 Library TTL | 正 ROI，SourceCache.fetch 持有命中/有效期/仅缓存成功值；两个 source readers 和既有 default-template cache 复用。roots/context 改变失效、读取错误不缓存、build 时 ETS 不存在容错均保留。 |
| L97 stat→lstat | 协议相同部分仅二次 stat；真实缺失和悬空链接会映射到 []/nil/不同错误。抽出 IO 框架会把具体目录检查和失败策略拆开，保留。 |
| L98 nonempty text put | 不能调用 maybe_put（保留空串）；三个本地两子句明确字段条件，另加公共 helper 无足够算法收益，保留。 |
| L99 list_of_maps | 每处是标准 Enum.filter + fallback，两行惯用代码；收口为泛化 payload helper 得不到算法简化，保留。 |
| L100 transaction raise | 正 ROI，在既有 Repo 边界加 require_transaction!(operation)，Files.Objects/Pod.Files.Content/Pod.Files 使用。严格保留 raise 的 TransactionRequired 和原 owning operation；不替换成原先返回 tuple 的 require_transaction。 |
| L101 author uid queries | 查询形状相同，但学习全部作者与请求披露仅 Human 是不同合同。新增跨域参与者查询入口无法降低这些过滤/顺序成本，保留。 |
| L102 OIDC origin | browser/token header 均处理可缺 Origin，但 WebSocket 分支必须 Origin，非客户端必须匹配本机 Origin；API plug 已独立解析 header 状态。拆公共 helper 不减这些协议分支，跨 OIDC/Web 层 helper 会增加边界，保留。 |
| L103 JSON errors/login mapping | literal error 体不是重复算法；Console 多 details，JSON:API 使用 Splode，AuthController 为 OAuth browser callback 返回不同简体 body/默认状态。不能统一 renderer 改变公开响应；保留。 |
| L104 Signal adapter/webhook fetch | 插件声明表不同、错误名不同，一次 Enum.find 已是最终 primitive；不造 registry 抽象，保留。 |
| L105 JSON seal | 两步 encode→seal 已为组合，purpose/AAD 的领域绑定应在调用点可读。共享一层只增加转发，不减少密码算法，保留。 |
| L106 OAuth tenant state | 正 ROI，同一模块 with_state_tenant 统一 tenant 前缀解析/cast/context，成功/取消各自生命周期保持。 |
| L107 recursive map overwrite | 正 ROI，在既有 Attrs 模块新增 deep_merge 统一两个同合同递归实现；Contracts 的 nil 删除明确不合并。 |
| L108 usage accumulation | 正 ROI，在既有 AIGateway.Usage 模块新增 merge 统一嵌套数值相加，保留非标准额外字段和右侧元数据；subtract_usage 是累计快照差分并有下限处理，保持独立。 |
| L109 recursive secret replace | 非等价：SecretFilter 跳过 struct，最小12字节/长度倒序密钥集合由投递负责；Connector 提取 Authorization 派生secret、覆盖所有map。不能强行一个入口改变数据/替换集合；保留。 |
| L110 grapheme byte prefix | 正 ROI，Text.grapheme_prefix 给 ToolSearch/Pages.Tree 复用，以 String.next_grapheme 早停，保留组合字素且不遍历全文。MarkdownChunks 是分片且有围栏，不替换。 |
| L111 exponential retry | 只是标准数学公式，单位/参数/重试计数/jitter不同；调用 Sessions classifier 会倒置领域依赖，通用backoff框架需新参数契约，保留。 |
| L112 internal UUID scrub | 相同正则已是标准 Regex.replace，去重只能引入新“公开文本”概念或让 Sessions 依赖 Job 内部投影模块。三处只有一条替换，nil处理不同；不扩张通用redaction职责，保留。 |
| L113 format_reason | 二进制原样/inspect 是两行惯用分支，其他有 inspect 大小限制；无有意义的通用算法，保留。 |
| L114 positive integer or nil | 两行guard/fallback，不等于会解析字符串的 Attrs.integer_value，也不等于限safe范围的 ModelIntegerID。创建泛化整数策略没有正收益，保留。 |
| L115 expected_updated_at | 正 ROI，与 L23 一并在 ActionCards 收口，缺省不比较，非法ISO为false。 |
| L116 public item/call id | 正 ROI，同文件 unique_public_id 收口SHA256/24hex/冲突重试，item source与pair seed、item/call输出前缀严格保留。 |
| L121 已有唯一 owner | 未发现该行声称不存在的第二套实现；不加新替代。 |
| L123 ensure folders vs Brain destination | 节点种类/授权/创建API不同，保留。 |
| L125 tool argument decoding | 非法JSON有 nil、{}、query回退三种故意行为，保留。 |
| L127 page mention regex | 属性位置/是否要求自闭合不同；不与 principal XML mention 收口混为一谈，保留。 |

#### §8 / §9

- WorkerEnv.EnvVar / SiteEnvVar、AppConfigure console/site operations、WorkerEnv console/site operations、Definition/PatternDefinition：site/tenant 是业务所有权，不以宏隐藏。声明性重复无需新抽象。
- BrowserAuth / BrowserSetup：各自公开动作不同，Ash DSL 声明保留。
- Brain MergeSuggestion / SchemaSuggestion：proposal 类型与动作不同，资源声明不是共享流程；保留。
- Map.reject nil：标准库就是算法 owner，再换 compact_map 仅换名字，与 L48 一致。
- §9 Phoenix.HTML、Attrs datetime、SecretDigest、HumanUser、Text、Session safe_return_to：上述对应项已落实；不加第三方库。
- §9 IMTransport 与 provider/Rust 由 root 负责；本核心没有依据引入 lodash/date-fns 或新Elixir依赖。

验证结果另附本任务执行记录；此表不会把未执行的live-provider/浏览器端到端宣称通过。

#### 验证中发现的测试边界问题

24 个核心/上游回归文件首轮在新建 ankole_testdup_core 中编译并运行，Sessions.ToolsTest 的 3 个 Workflow 子任务用例出现 stale_driver。该工具单元测试自行 Admission，但 task_run 在发布 Workflow dispatch 前没有保留被手动驱动的 Driver 槽；实际 Driver 取得租约后令手工 run 过期。复用仓库已有 SessionsCase.stub_workflow_drivers，在 fixture dispatch 前安装边界 fake；生产 Admission/lease/Workflow 逻辑和原断言不变。此 helper 已用于 Workflow 领域单元测试；没有把集成适配器换成 fake。

Text.grapheme_prefix 与原 Pages.Tree 实现经过 5,074 个 Unicode/字节预算等价案例：ASCII、中文、combining accent、emoji skin tone + ZWJ、旗帜，以及 5KB 文本各个截断位置，全部一致。该验证是一次性实证，不为低风险helper堆叠永久镜像测试。

PagesTest:375 的旧断言期待普通 scope:space 列出 Brain 根，与 MetaAnkoleArchitecture 的普通 Space / 独立 Meta Brain 契约相反。生产查询已正确隔离，本次只修正旧测试为普通 Space 空列表，并额外断言独立 Brain 根读取保持 view 权限；保留全部 AuthZ 断言，不把已有正确行为退回旧故事。

首轮 24 个领域及上游回归文件：273 tests，269 passed；4 个失败全部属于上述已修旧测试（3个手工Driver竞态、1个旧Brain Space断言），运行339.1秒。其余包括新OAuth回跳真实流程、共享凭证、usage、库读取、ActionCard/clarify/attachment、页面mentions/formula，以及5个上游回归文件均完成。定向重跑结果见本节末尾。

SourceCache 单独执行命中、context变更失效、到期重读、失败后重试成功四条行为链，全部通过。

最终定向验证：8 文件/所选case运行 165 个测试，其中164通过；唯一失败是新加正向断言把独立Brain根误放到scope:space，已改用 Namespace.root + Pages.get 验证真正入口。该单用例最终重跑通过（1 passed, 29 excluded，/tmp/ankole-core-pages-regression.log）。3个原Workflow竞态用例和新增6个边界测试文件全部通过，详见 /tmp/ankole-core-followup-tests.log。没有未解决的测试失败；未把分批复测报告成一次完整套件全绿。

最终代码diff已全量阅读；核心修改文件 mix format --check-formatted 和 git diff --check 通过。全项目FOSS/SaaS编译、静态和OpenAPI由主任务汇总。

### Worker / Browser / Function Runtime 重复清单逐项复核

范围为原始 `tmp-duplication-findings.md` §1 的 Worker、Browser、Function Runtime 项，§2 的环境变量名、browser restart、Worker regex 项，§6 全部，以及 §9 的对应替换建议。评判标准是总维护成本和产品契约的净收益；低但为正的收益照常实施，不把代码形似当作同一业务语义。

#### §1 已有 owner

| 项目 | 判定及落地 |
| --- | --- |
| ~/ 展开：ls / Drive search / fff | 真重复，已复用 commands.workspacePath；调用方保留原来的 trim/default，后续 Drive namespace 和 realpath 边界仍归各自 owner。 |
| HTTPS URL | 真重复；已核对 active-support 1.6.0 源码 isUrl(value, 'https') 与原 URL.protocol 检查等价，删除 isHTTPSURL。 |
| 非负安全整数 | 真重复；isLength 正是 Number.isSafeInteger 且 >=0。handoff 改用现成谓词并保留 undefined 返回含义。 |
| finite number | 真重复；optionalNumber 改用 isNumber(value, true)，保留协议所需 optional 输出。 |
| Browser material 深比较 | 真问题。Worker materializer 的 canonicalJSON 对对象键排序，同样内容的远端 headers 重排仍沿用 generation；daemon 的 JSON.stringify 却报 invalid_material，阻断下一次 browser 调用。改用 isEqual，仍拒绝字段值、数组顺序变更；equal 是 React 特化比较器，会跳过含 $$typeof 的对象的 _owner 字段，不适合任意 JSON。新增合法 headers 中 $$typeof/_owner 的值变化拒绝回归；删除冗余 materialJSON 状态。分别为 materializer 与真实 SessionActor dispatch 增加回归，并更新 AnkoleBrowserV2 协议小节。 |
| JSON.parse 后对象验证：pod-cli、lambda-hooks、cli-guidance、envelope_proto | 真重复；统一 isRecord。四处输入都来自 JSON.parse，没有 Date/class 等非 JSON 原型对象，错误文本和缺省处理留在原调用点。 |
| [...new Set] → uniq（mcporter-config/config/runtime-config） | 非正 ROI，保留。这里已经使用 JS 标准库，只有直接表达去重的单行，没有自有算法或分叉契约。引入同义导入不会消除维护 owner，依赖实现仍使用集合去重；排序和连接身份规则保持可见。 |
| MCP realpath 前缀 | 真重复并有边界差异；改用 pathIsWithin。原 root + '/' 拼接在 root 为 '/' 时得到 '//'；公共 helper 已处理根目录和真实父子路径，避免再维护第二份规则。 |
| help flags | 真重复；收至现有 cli/primitives，Pod/Drive/Webhook 都调用。Webhook 旧导出仍有测试调用，因此从原模块 re-export。CLI 空参数的 help 行为保留在入口。 |
| Function Runtime codeDigest 十六进制 | 非正 ROI，保留。现实现使用运行时原生 WebCrypto 的异步 SHA-256；node_crypto.ts 是 Edge Runtime 为 MCPorter 缺少 crypto.hash 提供的 Node 兼容 shim，不是整个 service 的 hash owner。仅为缩短输出格式把 service 改到同步 Node 兼容路径没有明确净收益；摘要字段排序和缓存身份维持不变。 |
| CLI context 原子写 | 真重复；调用 writeFileAtomicSync，保留 0600、Agent owner、rename 的原子可见性；删除本地 temp/catch/cleanup 流程。 |
| ENOENT 的 9 处 | 真重复；mcp/config、pod-cli-bridge 两处、project-config、browser/materializer、agent-home-config、real-path-boundary、drive/paths、ls-tool、function-compute-bootstrap 都复用 nodeErrorCode。保留各自返回/throw 语义；隔离 bun -e 脚本未改，它不处在主模块 import 环境。 |
| ls 错误消息 | 真重复；两处复用 errorMessage。隔离脚本仍内联。 |
| UTF-8 suffix 移到 common | 非正 ROI，保留。现有 suffix 只有 turn-content 一个调用者，与 prefix 方向不同；搬文件只增加导出及耦合，不会删除算法副本。head/tail 的持久日志策略仍归 turn-content。 |
| 带 ...[truncated] UTF-8 前缀 | 真重复；common/text-sanitize 增加 truncateUTF8WithMarker，projection/protocol/turn-content map key 三处复用；消毒、redaction、状态标志、工具专属预算仍归调用方。 |

#### §2 本范围项目

| 项目 | 判定及落地 |
| --- | --- |
| 环境变量名正则 | 真重复；command-env 的 ENV_NAME_FORMAT 导出给 MCP metadata schema 使用。WorkerEnv 和任意 MCP header/domain 语义不合并。 |
| browser restart delay / timer | 真重复；同一 supervisor 内收至 scheduleRestart；维持现有 delay、attempt、unref、desired 状态及事件投放差异。 |
| Worker regex 元字符转义 | 报告部分误判。grep detectMode 使用 replace 的差异判断“是否含正则语法”，并不创建 literal regexp；不能换 RegExp.escape（它也转义普通首字符）。agent-home-paths 进入分支时 replacement 必为 '-'，直接用 /^-+|-+$/g 删除动态转义与 new RegExp。skill-usage 仍是唯一需要任意 token 转义后插入 regexp 的实现，保留本地一行，不增加公共导出。 |

#### §6 全部项目

| 项目 | 判定及落地 |
| --- | --- |
| Browser atomicJSON 三份与 run-command atomicText | 真重复。新增 browser 包内 files.ts，一个 atomicText 持有 mkdir/write/rename/temporary cleanup；atomicJSON 只是 JSON 编码调用。local Chromium、remote CDP、runner bootstrap、run-command 共用。没有跨包引用 Worker Agent UID 的 chown 策略。 |
| Worker materializer atomicJSON | 假阳性，现有三行 wrapper 已调用 writeFileAtomic，并要求 mkdirAgent/chown；无需与 standalone browser 的普通用户文件策略强行合并。 |
| waitForExit | 真重复。同一浏览器进程生命周期函数由 browser/process.ts 持有，Worker supervisor 通过已有 @ankole/browser 依赖复用。超时后移除自己注册的 exit listener；不改进程信号、group ownership 或超时时间。 |
| assertOnlyOptions | 真重复；复用 cli/primitives，Webhook error prefix 留在调用方，Drive 的原消息保持不变。 |
| turnOperation | 真重复；移到现有 worker/logging，两个调用者共用 producer，仍接受 first/last 标志。避免 active_turns / turn_execution 间新增循环依赖。 |
| Pod 两处十进制正整数 | 真重复；同文件 decimalPositiveInteger 复用，仍要求十进制 digits，不扩大为指数/hex/空白语法；不修改其他 CLI 现有 positiveInteger 契约。 |
| sanitizePathSegment 两个版本 | 语义不同，保留 128/'_' 与 96/'-'/折叠差异。只移除 agent-home 内确定无须动态的正则构建。 |
| 三套 redact | 语义不同，保留。各自对配置凭据、HTTP endpoint 或模型持久文本作不同处理，没有相同输入/输出契约。 |
| immutable mergeConfig vs mutable deepMerge | 语义不同，保留。引库不能替代 immutable 更新。 |
| app-server delay vs active-support sleep | 语义不同，保留 unref、取消与 promise 接口。 |
| formatDuration vs seconds | 语义不同，保留毫秒展示，不把单位转换函数当 formatter。 |
| UUID shape vs isUUID | 非等价，保留已有调用协议；未从重复清单推导额外 identifier 限制。 |
| 各 runtime backoff 公式 | 语义不同，保留不同上限、底数与 checkpoint 次序；仅合并同一 browser supervisor 自身的重复。 |
| 四个路径边界 owner | 整体合并是假阳性；Drive 的虚拟 namespace、file relay、file-access path 与 effective-skill 的输入/权限不同。knowledge-skills 是真问题：relative.startsWith('..') 拒绝合法 '..notes' 文件，已用 relativePathWithin 保留禁止越界和目录本身的契约；回归验证实际 package materialization。 |
| 进程 group kill vs Lambda hooks single pid TERM | 语义不同；保留生命周期 owner。 |
| required strings | 是否 trim 与是否接受空串不同；保留。 |
| stream buffer | 传输协议不同；报告已确认无第二份 readJSONLines，保留。 |
| image bytes | canonical helper 与严格协议 binary adapter 的拒绝语义不同；保留。 |
| observability | 报告未发现重复，当前没有需修改项。 |

#### §9 对应结论与验证

使用现有 active-support 的 isUrl/isLength/isNumber/isRecord/isEqual。uniq 的替换没有净收益；ANSI 处理有顺序契约，不加库。没有增加第三方依赖。

额外修正验证接线：devkit 的 source-mounted Worker 测试需要挂载当前 ankole-browser/src，否则使用已安装镜像时会验证旧 workspace 依赖。已扩展现有 mount 列表并更新参数回归。

已通过：
- `bun run --filter @ankole/agent-computer lint`：format + 1,161 文件 type-check。
- `bun run --filter @ankole/browser lint`：format + 39 文件 type-check。
- `bun run --filter @agentbull/devkit type-check`：39 文件。
- `bun run --filter @agentbull/devkit test src/commands/agent-computer-test.test.ts`：5 pass。
- `bun run --filter @ankole/browser test`：最终 isEqual 修正后 43 pass，21 integration 默认 skip，0 fail，205 assertions；日志 `/tmp/ankole-browser-isEqual-test.log`。
- `bun run --filter @ankole/browser build`：当前 cli、daemon、runner bundle 构建成功。

- `bun run kit agent-computer-test --suite unit --image ankole-agent-computer:audit-officecli-fixed`：最终 477 pass / 0 fail，5,041 assertions，61 files；日志 `/tmp/ankole-worker-unit-verified.log`。
- `bun run --filter @ankole/browser test:integration`：真实本机 Chrome + 构建后的 CLI/daemon/runner，19 pass / 0 fail，109 assertions；包括大网页完整内容、16 MiB socket 上限、远端 CDP、runner artifacts、code lease、daemon crash recovery、browser capacity，日志 `/tmp/ankole-browser-integration.log`。

验证中发现并修复一处既有测试时间假设：`runtime.test.ts` 用 18ms 睡眠要求 5ms timer 至少发三次；并行负载时偶发只两次，而初轮已通过。现在最多等待 1s 观察真实三次 progress，保持“无 Codex notification 仍续约、stop 后不续约”原断言，并用 finally 释放 reporter。没有修改生产心跳周期或放松业务断言。

追加验证：React 特化 equal 的 headers 案例先实证失败（`/tmp/ankole-browser-json-equality-red.log`），换 isEqual 后整包通过；browser lint/type-check 同步通过。此修正只改 browser 比较器和案例，未再次运行 Docker 全 unit。

### 适配器、供应商与 Kernel 复核

L 编号对应原始清单行号。已修复包含收益较小但明确为正的收口；保留项列出等价性反例或新增复杂度成本。

| 原项 | 裁决与落实 |
| --- | --- |
| L32 Provider id 小写 | 已修复；仅同一供应商 ID 复用 ProviderConfigs.Provider.normalize_id，其他身份命名空间继续独立。 |
| L37 下载文件名 | 已修复；飞书改用 IMTransport.HTTP.filename_from_response；共享解析保留 UTF-8 编码和引号组合。 |
| L51 JSON 请求体编码 | 假阳性；错误 code 相同，stage 分别是 api_resolver / request_builder。各自只是 sonic_rs 调用加所属阶段错误，合并需要额外参数和跨层访问，不减少算法。 |
| L52 form-urlencoded / proxy decode_userinfo | 部分修复；查询编码改用现有 url Serializer，空格、Unicode、+ 和百分号按表单查询编码；proxy 用户信息不是表单，其 + 与非法百分号契约不同，保留。 |
| L137 凭证缓存命名空间与客户端校验 | 部分修复；三家凭证 fingerprint 归 IMTransport.TokenCache。各 provider 仍明确选择参与命名空间的字段；base URL/secret 校验保留本地字段名和报错，避免引入配置验证框架。 |
| L138 Google / Entra OAuth token 缓存与 exchange_code | 部分修复；复用 TokenCache.lookup，过期行精确删除；保留 60 秒刷新余量、300 秒缺省 TTL。直接套用 TokenCache.store/expiry helpers 的 180 秒余量会改变 TTL；其 GenServer 虽可通过 fetch callback 保留 60 秒余量，但完整单飞还需每凭证注册进程、任务监督和主动刷新生命周期，当前允许 last-write-wins 且未见并发填充造成实际请求放大故障。code exchange 已是 Req/form 和少量字段投影，不加带 provider 回调的新 OAuth 层。 |
| L139 错误类型 / Inspect | 保留；provider struct、错误字段、日志身份、retry 分类是各协议公开合同。抽宏会隐藏字段和模块名；已有 Inspect.Algebra / Enum 标准库完成算法，收益不抵额外间接层。 |
| L140 分页重试与 get_in_path | 部分修复；三家 map-only JSON 路径读取归 IMTransport.HTTP。重试本身三行，分页续页分别是 nextLink（必须去掉首轮 query）、cursor、pageToken，统一状态机须更多策略参数，保留本地重试上限。 |
| L141 企微/钉钉 HTTP 编码与旧 API 解码 | 部分修复；JSON body 复用 IMTransport.HTTP.put_body，钉钉显式保留 multipart 优先。errcode 信封、两个 base URL、下载结果、查询凭证仍由协议所有者解释。 |
| L142 Webhook HMAC | 保留；已经使用 crypto.mac、Base 编码和 Plug.Crypto.secure_compare。Base64 与 sha256=hex 是不同 wire；为两行标准库包装引入 provider 间依赖或新策略参数无正净收益。 |
| L143 Telegram/Discord/LINE/WhatsApp HTTP client | 保留；Telegram token 在 URL 且需脱敏，Discord 有 Bot headers/204/浮点 retry_after，LINE/WhatsApp 的下载限制与错误信封不同。Req 已承担公共 HTTP 层；再加回调请求器不能删除这些协议差异。 |
| L144 投递错误阶梯 | 保留；LINE monthly limit 429 要人工处理，Discord/LINE 404 与 Telegram 的默认策略不同，WhatsApp 默认永久失败。集中成状态码表会隐藏恢复动作和 provider 错误正文解释。 |
| L145 目录同步倒排索引 | 保留；实际 upsert 已由 IdentityDirectory.sync_users / ensure_group 统一，剩余流程属于 caller：Google USER、Entra @odata.type、Slack 用户组及各过滤规则不同。再抽建群/取成员/读字段三个回调使用户同步路径更难追踪。 |
| L146 企微/钉钉用户归一化 | 保留；metadata 键、根部门 1、用户标识和 observed_profile 映射是协议定义，Map.merge/Keyword.take 已是标准库操作。合成声明式映射不会减少领域规则。 |
| L147 群成员 uid / 离开状态 / 群同步 | 保留；AuthZ.IMGroupMembers 与 IMGroupProjection 已拥有写入与成员合同，插件只编排真实外部读取和身份观测。uniq/sort 是标准库；自定义同步框架会把不同的事件状态和失败归属藏入回调。 |
| L148 三家 grapheme 文本切块 | 已修复；Lark/Slack/Teams 共用 Ankole.Text.chunk_graphemes，保留各字符上限和空串 [""]，不混用 MarkdownChunks 的字节预算。 |
| L149 Webhook 查 binding | 假阳性；LINE find_value 只选一个 channel，WhatsApp/Teams fan-out 多 binding，Teams 还把空集报 unknown_app。租户上下文和凭证读取已有 Bindings owner；统一选择器会模糊投递基数与错误合同。 |
| L150 TokenManager 懒启动 / 监督树 | 部分修复；Registry 查找与 already_started 合流归 TokenCache.ensure_started。监督树声明保留：各插件独立注册名、故障域和 rest_for_one 顺序，Lark 还拥有 UserTokenManager；不抽监督宏。 |
| L151 WS 重连 | 保留；企微/钉钉指数上限与飞书/Slack 服务端间隔不同。共享算式只有移位/随机调用；timer、重试计数、协议反馈仍应在各状态机，统一重连策略增加分支而无运行收益。 |
| L152 WS child_spec / 客户端骨架 | 保留；child_spec 是 OTP 声明而非手写算法。相似 start/receive/timer 外壳已有 IMTransport.WebSocket；再用宏拼 GenServer 会遮住心跳与 ack 语义。 |
| L153 钉钉 AI card / 企微 AI stream | 保留；前者持久化分卡 out_track_id/封口账本并推送卡片，后者以 req_id/stream id、10 分钟封口窗口和主动消息降级支配账本。Markdown 分块已有共同 owner；强并状态机需模式分支和新恢复协议。 |
| L154 LINE/WhatsApp inbound | 保留；共有入口已经调用 AdapterContext.dispatch_chat，provider envelope、LINE standby/unsend/transcoding、WhatsApp delivery status/媒体处理不同；53 行相似不构成第二份域算法。 |
| L155 Telegram/Discord config/reply_preview/delivery | 保留；共享预览账本和连接协调已归 ChunkedMessagePreview / ConnectionLifecycle；new/deliver 剩下的是 Config→provider请求→ErrorPolicy 的清楚编排，抽回调会暴露 private functions。config 的独占约束与 provider 路径也应原地可见。 |
| L156 E.164 | 已修复；Google/Microsoft 复用 IdentityProviders.Phone.normalize_e164，仍拒绝无国家码号码，不引入中国手机号补 +86 的策略。 |
| L157 中国模型 provider 预设 base URL | 保留；两个条件分别是计费套餐与区域设置，已知地址和缺省选择独立。公共工具需传默认值、已知集合、选择条件，参数阅读成本大于省下的小型 cond。 |
| L169 Anthropic 请求头 | 保留；Claude 与 MiMo 的 credential 优先级、effort/option 投影不同。共同 3 子句 beta header 已依赖 UniversalAIRequest.put_header；为 provider 特有的一个 header 扩大通用请求 API 无正净收益。 |
| L170 OpenAI 三路组装 | 假阳性；OpenAICompatible Responses 会依据 supports_openai_tools 标记 custom tool emulation，官方 OpenAI 有 organization/project headers。叶子实现已有共同 owner，不能直接互相 delegate，也不增加流程配置对象。 |
| L171 ChatGPT options / Bearer | 已修复；两项重命名改调用 UniversalAIRequest.rename_provider_option；models metadata Bearer 同用 bearer_auth，删除本地副本。没有强加 promptCacheRetention 等新选项语义。 |
| L172 Chat / Anthropic 流式响应状态 | 保留；message 开始外壳相同，但状态同时依赖独立 sequence、reasoning blocks、usage 合并和结束时机。共用需拆共同可变状态并改全套状态机；不为 80 行相似引入第二个状态所有者。Bedrock 复用 Chat 是其已存在的 wire 翻译路径。 |
| L173 九类 HTTP 成功 / 错误 / 对象校验 | 已修复；直接把成功门闩并入现有 standard.provider_object_body，删除九处重复和 web 私有 wrapper，保留错误 stage、status、excerpt；不在 Value/Map 间无谓克隆，也不合并传输层解析前门闩。 |
| L174 usage 原样对象 | 保留；两处 filter(is_object)/cloned 是标准库组合，不能用 token usage 归一化丢掉额外字段；单独包装不会删除实质算法。 |
| L175 Chat function/custom call identity | 已修复；同一 wire 内共享 chat_tool_identity，调用参数分别保留 JSON arguments 和 custom input 编码。 |
| L176 输出图片 MIME | 保留；两处三臂 match 分属 resolver 输出和 hosted image transport；共用要扩大跨域可见性，省不下实质算法，类型化 image spec 与原始 request map 不混用。 |
| L177 一次性 function_call | 保留；外壳相似但 function_call_item 接收带 output_index 的流式 ToolCall；套用需要构造无实际含义的 stream state，或改变全部流式调用签名。namespace/custom 恢复已有共用函数，参数解析保留 wire 差异。 |
| L178 搜索结果别名 | 保留并确认报告原判断；各 provider 键名列表为协议投影，结果已走 search_result，不添加字段读取策略框架。 |
| L179 Docker/Kubernetes 创建冲突认领 | 保留；Docker 认领后必须 start，Kubernetes 联合 Secret/Pod/agent-uid 与所有权对象。ReconcileJob 已统一生命周期；不能把两者当相同事务。 |
| L180 单 Agent 日志尾部 | 保留；Docker 先解复用 8-byte frame，Kubernetes 按 Pod/容器状态提供诊断。单 Agent 查日志而全量不拉日志是容量合同；拼 reason 的标准库调用不另抽 IO 回调。 |
| L181 首次观测 404 | 保留；Vercel/FC 可报告已结束，Lambda 明确处理 RunMicrovm 后最终一致读取的 404，不可统一；已见过/未见过合同由平台所有者判定。 |
| L182 Worker provider 分页 | 保留；Lambda imageIdentifier、Vercel pagination.next、FC nextToken/页大小与响应体合同不同，递归只有数行，公共递归器要增加取页/续页/结果三组回调。 |
| L183 Lambda/Vercel collect | 已修复；Stream.map → Attrs.collect_results 保留首次错误即停，最后 Enum.concat 一次合并，消除 acc ++ values 的累计前缀复制，无新抽象。 |
| L184 Vercel/FC HTTP 分类 | 假阳性；Vercel 返回 body，FC 返回完整 response 供头信息及签名相关流程使用，nested error/code 与 Code/Message 也不同。Req 已拥有通用 HTTP 层，不能按窗口相似度直接替换。 |
| L335 残缺 JSON 修复 | 保留；sonic-rs/serde_json 只解析完整 JSON，不负责 fenced/object extraction、补齐和尾逗号修复。当前调用经过对象解析确认才接受；无现有等价依赖，引库的兼容风险超过此处收益。 |
| L337 Kernel 基础算法不存在副本 | 确认；路径编码、base64、OpenDAL retry、quick_xml 转义已经各有 owner，不做无依据的再封装。 |
| L339 飞书 protobuf frame | 保留；feishu_protocol 是零依赖独立包，Protox 只在控制面已有，并非此包已有。现测试明确逐字节覆盖 proto2 必填零字段和 header 顺序；改造还需 schema、字段转换和新传递依赖，未见实际 wire 缺陷，净收益不为正。 |
| L355 url Serializer 汇总 | 同 L52；已落地。 |
| L358 IMTransport 汇总 | 同 L37、L138、L141、L150；按相同合同复用，不改变 TTL 和重试策略。 |
| L359 checked_provider_object 汇总 | 同 L173；实现复用已有 provider_object_body，无需另添一层函数。 |

### 重复清单逐项裁决：前端 / 编辑器 / 页面 Kernel

对照 `/tmp/ankole-upstream-duplication-findings-original.md`。`修复`表示存在可验证缺陷或净维护收益为正，已实施；`保留`表示误判或所提方案净收益不为正。没有按“收益小”过滤正收益项。

#### §1 已有主人与 §9 对应建议

| 原条目 | 裁决与证据 | 已完成处理 |
| --- | --- | --- |
| SMTP email → isEmail | **替换建议是假阳性。** 已安装active-support.isEmail拒绝 `alice+tag@example.com`，当前SMTP形状与后端允许该常见地址。替换会破坏真实邮件测试流程。 | 保留当前形状校验。 |
| knowledge-draft JSON stringify深比较 | **真问题。** 同一metadata仅改变嵌套对象键顺序会一直显示未保存，服务端JSONB对象无键序语义。 | 复用active-support.isEqual做dirty/save确认，保留已有recovery存储形状。新增键重排、确认关闭编辑回归。 |
| draft-navigation-guard JSON stringify深比较 | **真问题。** URL查询参数顺序不表示导航目标变了，键序差异不应多弹丢弃确认。 | 同库isEqual比较search对象。 |
| 建议使用equal | **再次复核发现不等价。** `equal`是React版fast-deep-equal，存在`$$typeof`时跳过`_owner`。Bun实测普通业务JSON `_owner.uid`变化仍返回true；`isEqual`返回false，且对象换序返回true。 | 以上两处选择现成isEqual。新增React-like业务键修改回归，避免把业务键误认React元素。 |
| page-files文件大小ceil KB | **真问题。** 0、小文件、大文件展示不一致且大文件几万KB难读。 | 使用既有formatFileBytes的1024制与单位。 |
| directory-access humanizeToken | **正收益。** 重复技术词规则会把OAuth等显示错误。 | 复用humanizeTechnicalLabel；调用前保留原点分隔符处理。 |
| humanizeAgentPluginID | **不同产品语义。** 插件名字是标题式`Deep Research`，通用技术label为句式`Deep research`。 | 保留，避免改变显示名合同。 |
| safeJsonParse四处 | **正收益。** tool-run-view失败保留原字符串；两个settings编辑器需要对象；prettyJSON失败保留原文。 | 复用safeJsonParse，局部保留unwrapOr/recordValue/isOk和原fallback，避免把错误/非对象一律吞成同一值。 |
| 1024大小 vs byteSize；相对时间 vs seconds/ms | **替换建议不等价。** 进位及输出单位不同。 | 保留formatFileBytes与Intl，不引入依赖。 |

前端正则转义附加核对：`RegExp.escape`不满足Chrome126底线；在webapps/common/text复用现有literal escaping，评论、聊天composer、chat state同一规则。编辑器包内MentionMenu保留独立小函数，不为1行实现让文档/编辑器依赖webapps；Vite构建配置在独立宿主内保持本地规则。

#### §5 前端与编辑器

| 原条目 | 裁决与成本/收益 | 已完成处理 |
| --- | --- | --- |
| 已有owner清单：formatFileBytes/useDebouncedValue/cn/Console列表过滤/route loaders/useIsMobile/cron数字提交/email-otp | **扫描未发现重复。** 这些本来已有明确owner。 | 保留，不新增平行实体。 |
| 两条Markdown渲染管线 | **不是同一合同。** 共享普通Markdown与聊天内容的流式/工具/表格/代码功能不同。 | 保留各入口，共用既有可共用原语。 |
| relative time两套 | **正收益。** 同一Pod页面在mention与列表中亚分钟措辞不同，且聊天从content-list导入纯formatter拖入组件边界。 | 移至common/date-time，统一列表已有“此刻/0分钟”语义，原始时间不足/无效仍显示空；各调用保留locale。 |
| absolute time各套 | **真问题。** Pod设置邀请、Automation与Base日期用系统语言，和界面语言不同。 | common/date-time统一界面locale；Console/history/insights保留原medium/short，原toLocaleString调用的Automation开始/完成/下次运行/历史/交付/过期、Base日期、邀请过期显式medium时间保留秒。Console继续原导出名。实测暴露过一次精度回退，已逐一恢复，不能用去重损失业务信息。 |
| 三种duration | **非重复合同。** Console秒数总时长、chat elapsed、媒体mm:ss分别服务不同阅读场景。 | 保留，不以秒/ms工具替换。 |
| datetime-local三处 | **正收益。** 时区转换算法相同。 | 移用既有quota本地时间转换到common/date-time；quota保留秒精度，Pod输入调用slice保留原分钟精度，不修改时区合同。 |
| Blob下载七处 | **真问题/正收益。** Console立即revoke在浏览器消费URL前释放；其余实现大体等价。 | common/browser-files.downloadBlob负责DOM anchor与延时revoke；文档恢复、导出、聊天md/png、Meta技能、Mermaid、Console统一复用，文件命名与MIME留调用方。浏览器Console实际下载字节流程通过。 |
| filename清洗两处 | **合成完整命名函数收益不正。** 两处相同的字符替换仅1行；trim/default/extensions分别是聊天Markdown和图片导出的产品约定。 | 保留两行；不误并documentFilename或Bidi sanitization。 |
| blobToDataUrl两处 | **正收益。** FileReader逻辑完全相同，差异只有异常fallback文案。 | common/browser-files单一owner，原Reader错误仍向上抛；不改Safari ClipboardItem同步promise保活。 |
| OIDC copyCallbackURL两处；聊天7处copy状态 | **真维护重复。** 计时器清理、重复复制重新计时相同；page-files原重复复制旧timer会提前清状态且不清unmount。 | UIKit useCopyFeedback统一反馈生命周期，调用方保留实际copy、toast、1500/2000ms、provider切换reset、image/markdown/code/png标记。 |
| Website两套CopyButton | **正收益。** fallback复制逻辑与timer重复，但两按钮样式和无障碍label不同。 | Website本地copy-text负责Clipboard/textarea fallback，复用UIKit反馈hook；保留两种视觉按钮，删除重复算法。execCommand只作Clipboard失败fallback，现有deprecated hint可接受。 |
| 六处captureSave | **抽象建议收益不正。** generation/提交快照的形状相似，但字段级回写、validation快照、凭证delta、valueRevision/reveal因果关系均属各model。统一后需泛型字段映射+回写钩子+各类例外，测试证明成本高于当前直接字段逻辑。 | 保留各typed model，既有draft tests覆盖，未为一致性移动领域职责。 |
| cron文案 | **正收益。** 相同翻译key/weekday数组，没有语义差异。 | common/cron-editor-labels供Pod与Console；Pod不依赖console-form，Console导出保留实际调用。 |
| 后台Job状态徽章 | **正收益。** 完全相同的领域状态→tone→翻译表。 | console/background-job-status复用；Schedule/Webhook/Automation的不同状态域保留。 |
| Fact与DetailField | **正收益。** 两个表格事实单元结构与mono合同相同，仅纵向padding不同。 | 复用现有console-form.DetailFact，Conversation传py-4保留布局。 |
| Automation Fact / QuotaFact / Metric / CredentialFact | **合并建议收益不正。** 无背景内联、横向quota布局、数字locale格式、缺值隐藏和响应式凭证列分别不同；一个通用Fact需多处class/formatter/隐藏开关。 | 保留相应小视图，uikit已有底层文本/布局。 |
| RunLog / CredentialDiagnostics | **合并建议收益不正。** 只有details/pre标准标记相似，summary字号、max-height、break-all和缺值隐藏不同。 | 保留小视图，不创建参数等长的wrapper。 |
| principal/group grant接线 | **误判。** UI已由PermissionGrantsSection唯一持有，剩余为两个领域API/path/文案接线。 | 保留领域调用，避免callback/query参数层。 |
| MemberAvatar / PrincipalAvatar | **合并收益不正。** 已复用Avatar/Image/Fallback；member显示名/uid与principalLabel、size合同不同，额外wrapper不删除算法。 | 保留。 |
| claim type徽章两处及search-preview | **正收益。** 同一Brain claim type和kind；search preview还漏翻译。 | 既有claims徽章owner导出ClaimTypeBadge供三处，统一翻译。 |
| webhook/schedule工具栏 | **误判。** 已用ResourceSearch、AgentFilter，剩余是不同状态过滤参数。 | 保留组合，无新框架。 |
| Brain merge/schema suggestions UI | **合并收益不正。** 既有ResourceListPage/表单/dialog负责共同骨架；merge选择canonical page，schema选择primitive/slugPrefix/targetType。统一会增加异构payload条件。 | 保留。对应Ash schema声明由控制面ledger裁决。 |
| add-membership-picker / principal-picker | **不同合同。** 前者选完清输入、固定value=null；后者显示存量选择、允许clear、有required有效性逻辑。 | 保留已有Combobox原语；相同imports不算算法重复。 |
| custom/model-profile字段投影 | **确有现成owner。** 两model均已有snapshot()调用同一个readProfile。 | 删除两份字段逐项投影，直接用model.snapshot()/snapshot(profile)，零新增抽象。 |
| enterprise credential / ChatGPT login骨架 | **不同生命周期。** enterprise凭证直接录入token/account，ChatGPT先发起浏览器/设备登录再接callback/轮询，refs/清validation时机不同。 | 保留两表单，继续共用LabeledField/Input等；不将授权控制流合成。 |
| 菜单关闭焦点四份 | **正收益。** 同一“开启行内rename则不抢focus，否则回trigger”的一次性flag协议。 | UIKit useMenuFinalFocus单一owner，page-nav/subpage row/card/chat-sidebar复用；不改变菜单行为。 |
| NewGroup / Share成员列表 | **正收益。** people/agent option展示相同，add/toggle及候选来源由调用方持有。 | 抽Pod chat MemberOptions，只复用候选组和avatar/label；查询、loading/empty、选中集合、权限、提交仍归各用户流程。 |
| PageSharing SubjectPicker两处 | **误判。** 已共用SubjectPicker；main用browse折叠，invite用stageSubject，两者输入集合不同。 | 保留调用方组合。 |
| Apple平台判断 | **真一致性问题。** link快捷键包括iPad/iPhone，但提示文字只认Mac。 | common/platform统一判断，键盘路由与提示一致。 |
| 省略号截断三处 | **正收益。** 同一字符上限+省略号规则。 | common/text.truncate复用；Console导出兼容实际调用。URL slug词边界截断保留。 |
| URL搜索草稿两处 | **正收益。** 两处都需要处理back/外部URL回写与commit echo、避免覆盖较新输入。 | common/use-search-draft单一owner，保留Pod180ms/Console300ms与Pod scope，清空立即生效；previousQuery区分真实外部导航与尚未回写的提交，避免覆盖继续输入。删除不再有生产调用的旧timer helper及其timer-only测试；真实Console组件验证搜索/缓存清空，React hook浏览器单测验证延迟echo、继续输入、back与scope恢复，先红后绿。 |
| 文件preview readPrefix/Text limit | **正收益。** 同一有界字节读取及cancel协议，避免大附件全量下载。 | common/browser-files.readPrefix和file-preview TEXT_PREVIEW_BYTES；image仍16MiB且截断拒绝，text仍64KiB可截断展示。 |
| 两处isTextFile | **真问题。** 缺MIME的`.markdown`在Drive可预览，在聊天附件不可预览。 | 共用file-preview.isTextFile，保持不同surface的媒体优先级和CSV/表格行为。 |
| decoder那6行 | **合并收益不正。** 两处已共用bounded bytes；剩余TextDecoder(stream:truncated)与返回UI数据shape不同。 | 保留局部解码/返回对象。 |
| effectiveFieldType vs Formula.type | **跨运行时非重复owner。** UI需要person/select，SQL需要text；跨Elixir/TS无法共用执行函数。 | 保留显示/SQL语义，不引入协议生成器。 |
| local-query第三份field分类 | **真问题。** formula result_type=array遗漏兼容性门禁，可能在未证明JSONB比较等价的库上本地排序/范围过滤。 | 使用浏览器已有effectiveFieldType；新增开/关门禁、contains仍本地回归。 |
| base-summary内联分类 | **真问题。** datetime公式无日期分桶，虽服务端支持，UI不提供。 | 复用effectiveFieldType作候选/分桶/结果展示；规范同步。 |
| 日期bucket JS/SQL | **删除本地聚合收益为负。** 已有schema.timezone传入，JS取同一时区年月日后按UTC运算该日的周一，数学上对应date_trunc week；day/month/quarter/year格式一致。强制RPC增加日常聚合延迟和后端负载，未发现当前边界失败证据。 | 保留小表本地聚合，PostgreSQL仍持久真值及不兼容运算owner；不以去重名义删除有效优化。 |
| fieldValue空值规则 | **跨层契约。** 浏览器snapshot必须与SQL cast保持null空值语义，各自执行环境不同。 | 保留，shared table-query fixtures验证。 |
| principalUID | **跨层契约。** 页面记录author的ActorRef→当前租户uid与UI比较归一化，不是新Principal身份域。 | 保留；不能把全ActorRef或UI person变成新auth主体。 |
| normalize.ts/tree.rs | **替换建议收益为负。** 实时浏览器编辑需本地同步正规化，Elixir提交必须native校验，不能让编辑每次RPC。 | 保留两运行时同一格式的实现，以共享corpus/属性测试约束；无新normalization库。 |
| XML escape四份 | **真问题+正收益。** Rust knowledge Markdown先拼XML再parse，属性Tab/换行变空格，回归先红（实际title first second third）后绿；TS MDX和XML属性规则重复。 | Rust tree.escape_into为page域owner，knowledge按文本/属性上下文调用；TS xmlEscape供Markdown tagOf复用。quick-xml通用escape改变canonical字节，故不用；view HTML是另一合同。 |
| UUIDv7 comment ID | **用uuid宽松parse不等价。** 当前需36字符小写、版本7、variant；crate还接受uppercase/其他表示，需再拼格式校验且TS仍要regex。 | 保留两运行时窄形状校验，避免扩大接收协议；共享corpus负责一致性。 |
| Point/Range mapInner/copyMappedUpto | **抽象收益为负。** 点偏置与区间两端粘附/删除映射是不同不变量；合并需分支/回调重新编码。 | 保留现有专门数据结构。 |
| Code/Mermaid toolbarButton | **正收益。** native button可访问性与文本/title完全一致。 | 既有editor/widget.ts增加小helper；两个toolbar保留dataset/class/action owner，删除重复构造。 |
| toolbar mousedown/action接线 | **合并收益不正。** 两处各1行，选择器和所属节点类型不同，回调后不同配置/复制行为。 | 保留各toolbar逻辑，避免抽成action分发框架。 |
| 列表高亮/IME判断 | **真问题。** comment-thread无IME guard，中文确认Enter可误选Agent。其余菜单已有isComposing/keyCode229。 | UIKit composingKey集中现有判定供五菜单+SelectionToolbar；评论补guard，实际Pod既有typing-after-mention用例加入两种IME状态。下标运算1行和Enter/Escape语义继续留各菜单。 |
| 两个类内debounce | **库替换收益不正。** page协作30ms、Mermaid80ms生命周期和flush不同，原本各6行且无多余并行owner。 | 保留，不引入调度框架/依赖。 |
| uikit Item/Badge、Sheet/Dialog overlay、Popover/HoverCard、Separator/ButtonGroupSeparator | **同形非重复。** 不同BaseUI primitive/交互与视觉职责，已共享tokens与原语。 | 保留各公共组件；统一会形成更多variants与跨组件耦合。 |

#### §7 / §8

| 原条目 | 裁决 |
| --- | --- |
| Myers双向diff | **保留。** 98行返回匹配坐标供当前结构diff，不是通用edit script。新crate需要适配/证明匹配选择与重基稳定性，未减少总复杂度。 |
| editor bidi UAX#9 | **保留。** 完整编辑器visual ordering依赖现有结果，字素库不等价；替库需重验选区/光标/RTL。没有现成依赖可直接删除算法，净收益不正。 |
| common/vfs/object_store/authz owner现状 | **未发现新增重复。** page域XML escape确有问题已上述修复；与WebDAV的quick-xml escape不同用途。其余Kernel/provider项由root ledger覆盖。 |
| site/tenant声明、browser auth/setup资源、Map.reject | 不在前端修改范围。未将UIKit组件或页面声明的同形推导成统一授权/身份模型；保持root/控制面agent对对应条目的独立裁决。 |

#### 验证与边界

- 编辑器全单测1203通过；Chromium/WebKit composition/host-composition/embedding 90通过、48测试原先声明skip。
- Kernel page_document专项52通过、1既有ignored；knowledge属性空白回归已记录先红后绿证据 `/tmp/ankole-ui-kernel-red.log` / `...-green.log`。
- Webapps全单测749通过（含React-like业务键修改回归）。一次运行遇到并发OpenAPI生成短暂删除文件，25 module-not-found，生成完成后同命令通过；不是弱化断言或生产路径。
- Webapps、editor、uikit、website types通过；定向oxlint无error，仅既有filename-case。Website保留Clipboard fallback所需execCommand弃用hint。
- Sidebar desktop/mobile两项浏览器单测通过；Console上传→改名→下载→删除、identity、regressions共19项通过；新增搜索两项浏览器单测通过（真实Console缓存清空，以及React hook delayed URL echo/back/scope），日志 /tmp/ankole-ui-search-green.log。
- 本轮浏览器HTTP夹具测试标记为unit/组件边界验证；真实Pod后端cross-column IME commit/cancel两项通过（/tmp/ankole-ui-audit-final.log）。原测试redo后只比XML，读到undo前的同一XML时就提前快照，造成revision 4/6假阳性；现等待用户可见saved状态（既有pending/sent真实ACK），并保留reload前后XML和revision严格相等。其余完整Pod流程由root环境承担，包含新评论IME断言及保留秒的运行完成时间断言。

最终手写源稳定后复查：Webapps 882文件type-check通过，最后变更oxlint无诊断，git diff --check通过。新增搜索测试所需两个小fixture文件复用现有React/Vite/Playwright，无新框架。技能使用：modern-web-guidance 的 ime-safe-enter-submit；浏览器输入保护使用 isComposing 或 keyCode 229。

## 综合验证

所有失败项均追到实际原因并复验；下列分批结果不合计成一次全仓测试通过。没有把 HTTP 夹具、组件测试或编译通过称为线上供应商验证。

| 边界 | 已执行结果 |
| --- | --- |
| Elixir 领域与上游回归 | 首轮 24 文件 269/273 通过；3 个旧 Workflow 单元夹具竞态、1 个过时 Brain 列表断言已修。8 文件定向复测 164/165 通过，最后一个新 Brain 断言改走真实 Namespace 入口后单项通过。5,074 个 Unicode/字节窗口等价案例及 SourceCache 生命周期验证通过。 |
| IM / 模型供应商 | 数据库外插件单元测试 276 通过，IMTransport 10 通过；控制面 8 个供应商/适配器合同文件 212/213 通过。唯一失败是 Lark 卡片事件旧夹具缺少真实 raw envelope，改为 Event.from_envelope 后该文件全部 92 项通过，生产路径和原断言不变。 |
| Kernel 全部特性 | `bun run --filter @ankole/kernel test` 和 `lint` 均通过，覆盖 Rust no-default、NIF、test-ca、NAPI 与 Elixir/Node 边界；各变体包含重复案例，未累加成独立用例数。既有 ignored/excluded 未解除。 |
| Worker 与浏览器 | Docker devkit Worker 477 通过；Browser 单元 43 通过，真实 Chrome 集成 19 通过。最后 JSON 比较的 React-like 字段回归先红后绿，并复跑 Browser 单元及 lint/types。 |
| Webapps / 编辑器 | Webapps 749、编辑器 1,203 项单元通过；Chromium/WebKit 编辑器浏览器测试 90 通过、48 项既有显式 skip；UI HTTP/组件边界 23 项通过，涵盖上传、改名、下载字节、删除、身份页、桌面/移动导航与搜索延迟回写。 |
| 真实 Pod 用户流程 | 实际 Phoenix、PostgreSQL、Function Runtime 与浏览器共同验证连接器配置/选择/授权、自动化事件与 Action、文档/IME/评论。首轮 14 项中 11 通过；2 项保存快照早于真实 ACK，改为等 saved 后原 XML/revision 严格断言通过；1 项日期格式丢秒，修复所有原有秒精度调用方后通过。另补评论两种 IME Enter 状态并通过。移动连接器配置与保存界面已看图检查。 |
| SaaS 路由 | 实际 Phoenix Meta 直达/刷新及 BrowserFlow 共 23 项通过。 |
| 发行版与生成物 | FOSS/SaaS 编译通过；两种 edition 的 test/prod compile-connected cycles 与 Plugin 依赖边界均通过；OpenAPI 4/7 份、Toolkit 125 项声明与生成 SDK 无漂移。 |
| 静态与构建 | Control Plane Credo、Kernel lint、全工作区非 CP TypeScript、仓库 lint/format/unused/structure/cycles 均通过；最终 FOSS/SaaS Webapps 与 Website 生产构建通过。网站 301 页构建及 32,449 条站内链接校验完成。 |
| 文档引用 | 检查本地改动的 180 份 Markdown/MDX 中 1,189 个本地链接，没有新增断链；3 个既存问题未归因于本次修改。已删除原型没有当前构建入口引用。 |

关键日志保存在本机 `/tmp/ankole-root-*.log`、`/tmp/ankole-ui-*.log` 及各分项列出的日志中。真实 Pod 使用独立测试数据库分区和专用 Function Runtime 容器，不占用日常开发服务；验证结束后已停止专用服务并清理会话凭据。这里未宣称全量 `bun run test`、公网 IM/LLM/OAuth 供应商端到端、远端 CI 或部署验证通过。

## 原始候选清单

下列内容保留审查前原文。前面裁决表的 `L` 行号以这份原文自身第一行为 L1，结论以本轮逐项裁决为准。

# Ankole 重复实现审计

临时笔记，2026-11-04。只读审计的合并结果，不是产品设计文档，也不进入 `docs/`。用完可删。

生产代码里没有成片散落的 `formatDate`、`deepClone`、`debounce`。TypeScript 侧已经依赖 `@agentbull/active-support` 1.6.0，其中包含 `cloneDeep`、`deepMerge`、`debounce`、`equal` / `isEqual`、`byteSize`、`seconds`、`isEmail`、`isUrl`、`isRecord`、`uniq`、`safeJsonParse`。重复集中在三处：供应商适配器整段复制控制流；控制面里已经有主人的小函数被再写一遍；同一条业务规则在 Elixir 和浏览器、或在两个相邻模块里各写一份。

`byteSize` 按十进制进位，不能替换现有的 1024 文件大小格式。`seconds` / `ms` 只出单一单位，不能替换相对时间。

## 覆盖

两轮合计，函数体哈希覆盖 2202 个生产源文件、8749 个函数。标识符归一化之后，1926 个文件里能对上 28 行以上的文件对有 14 对。Webapps、编辑器和 uikit 另做了逐行克隆扫描：59 处精确对齐、1180 个函数里 45 对相似度不低于 0.72。

读过的生产树：`sessions`、`conversations`、`signals`、`background_agent_jobs`、`workflow`、`schedule`、`automation_jobs`、`pod`、`brain`、`files`、`ai_agent`、`ai_gateway`（含 providers）、`authn`、`authz`、`oidc`、`principals`、`connectors`、`identity_providers`、`app_configure`、`browser_sessions`、`security`、`ankole_web` 的 controller 和 plug、全部插件 `lib/`、`libs/im_transport`、`libs/feishu_protocol`、全部 `universal_ai_client` resolver、kernel 的 `common`、`vfs`、`object_store`、`authz`、`page_document`、Pod 与 Console 页面和 state、auth、setup、编辑器 helper、Agent Computer 里 `generated/` 以外的手写代码、`function_runtime/main`、`ankole-browser`。

未当手写工具审的：生成的 Codex runner（约 920 个文件）、GitHub `tools.ex`、OpenAPI 客户端、编辑器 `output/`、测试、迁移。`function_runtime/native/patches/` 的 7 个文件是上游 worker 运行时补丁。`normalize.ts` 与 `tree.rs` 对过步骤和断行例程，没有逐行 diff 全文。各 resolver 的协议字段对过驱动循环，没有把每一家的键表合成一份。

## 1. 已有主人，仍被再写一遍

调用现有函数即可，不必再引入库。

| 行为 | 主人 | 仍在本地写的地方 |
| --- | --- | --- |
| ISO8601 → `DateTime`，失败即空 | `Ankole.Attrs.parse_datetime/1`（`app/control_plane/lib/ankole/attrs.ex:149`） | `brain/tools.ex` 的 `datetime/1`、`sessions/tools/session.ex` 的 `time/1`、`signals/intake.ex` 的 `instant/1`、`ai_agent/token_quota.ex` 的 `parse_instant/1`、`connectors/accounts.ex` 的 `expiry/3`、`signals/webhooks.ex` 的 `expiry/1`、`conversations/action_cards.ex` 两处 precondition、`conversations/context.ex` 的 `sort_key/1`、`ai_gateway/credential_pool.ex` 的 `entry_health/1`、`ai_gateway/provider_configs/credentials.ex` 的 `normalize_disabled_at/3` |
| 解析之后的时区时钟 | `DateTime` 与 `Calendar.strftime`。`parse_datetime/1` 只解析 | `sessions/prompt.ex:254` 与 `sessions/prompt/input.ex:943`。都把字面量 `"UTC"` 换成 `"Etc/UTC"`，再格式化成 `%Y-%m-%d %H:%M`。一处用 `DateTime.shift_zone/2`，一处用 `Ankole.TimeZone.shift/2`。各约 12 行 |
| 32 字节 URL-safe token | `Ankole.Authn.SecretDigest.token/0` | `ankole_web/session.ex` 的 `opaque_token/0`、`agent_workers.ex:393`、`worker_files/relay.ex:64`、`signals/webhooks.ex:79`（前面加 `wh_`） |
| 邮箱形状 | `Ankole.Principals.HumanUser.email_format/0`；前端是 `isEmail` | `principals/invitations.ex:42`、`authn/config.ex:66`、`app_configure/groups.ex:87`、`app/webapps/console/pages/settings-task-editor.tsx:98` |
| UTF-8 字节前缀，不切断码点 | `Ankole.Text.utf8_prefix/2` | `files/path.ex:195` 的 `truncate_bytes/2` |
| UTF-16 长度 | `Ankole.Text.utf16_length/1` | `plugins/utf16_text.ex` 的 `UTF16Text.units/1`。切片一份把坏 surrogate 换成 `�`，另一份越界返回 `nil`，不能无条件替换 |
| 整数秒 `Retry-After` | `IMTransport.HTTP.retry_after/1`（`libs/im_transport/lib/im_transport/http.ex:30`） | `connectors/http.ex:177`。`credential_pool.ex:546` 的 `parse_retry_after/2` 多了 HTTP-date，这一步 `Req.Utils.parse_http_date/1` 已经会做 |
| 本地回跳路径 | `AnkoleWeb.Session.safe_return_to/1`（`ankole_web/session.ex:727`） | `connectors/oauth.ex:259`。只拒绝 `//`，不拒绝 `/\`，失败返回 `nil`。Session 版失败落到 `"/"` |
| 请求 Origin 字符串 | `ankole_web/plugs/request_host.ex:16` | `ankole_web/plugs/browser_csrf.ex:47` 又拼了一次 `URI.to_string(%URI{scheme, host, port})` |
| Provider id 小写 | `ProviderConfigs.Provider.normalize_id/1`（`provider_configs/provider.ex:307`） | `ai_gateway/providers.ex:721`。同一正则 `\A[a-z][a-z0-9_-]*\z` 还在 `identity_providers/config.ex:16`、`principals/external_identity.ex:67`、`principals/mapping_request.ex:73`、`principals/platform_subjects.ex:12`、`authz/resources/external_binding.ex`、`authz/input.ex:129`。是否先 `downcase` 不完全一致 |
| 工具公开路径 | `ToolContract` 里的私有 `public_path/2`（`tool_contract.ex:708`） | `programmatic_tool_calling.ex:1006`。`nil` 返回 name，否则 `"namespace.name"` |
| UTC 时间戳 SQL | `Ankole.Pod.Query.utc_timestamp/1`（`pod/query.ex:590`） | `pod/formula.ex:658`。掩码同为 `YYYY-MM-DD"T"HH24:MI:SS.US"Z"`，公式版多一层括号 |
| 页面 principal mention | `Pod.Pages.Mentions`（`pod/pages/mentions.ex:18`） | `pod/comments.ex:17`，正则都是 `~r/<mention\s+principal="([^"]+)"\s*\/>/` |
| WebDAV 路径段 | `Ankole.Files.Path`（`files/path.ex:38`） | `ankole_web/plugs/vfs_webdav.ex:361`。同样拒绝 `.`、`..`、斜杠并要求 `String.valid?/1`。少了 255 字节和双向控制符，多了拒绝 NUL |
| `Content-Disposition` 文件名 | `IMTransport.HTTP.filename_from_response/1` | `plugins/lark_adapter/lib/feishu_openapi.ex:574` 仍自己解析 |
| `~/` 展开 | `workspacePath`（`app/agent_computer/src/tools/computer/commands.ts:147`） | `tools/computer/ls-tool.ts:53`、`drive-search.ts:23`、`fff-search.ts:232` |
| HTTPS URL | `isUrl(value, 'https')` | `app/agent_computer/src/tools/web/web-tools.ts:209` 的 `isHTTPSURL` |
| 非负安全整数 | `isLength` | `app/agent_computer/src/core/background-agent-job-handoff.ts:64` 的 `nonnegativeSafeInteger`。它返回数字，调用处写成 `isLength(value) ? value : undefined` |
| 有限数字 | `isNumber(value, true)` | `app/agent_computer/src/fabric/channel_transport.ts:954` 的 `optionalNumber` |
| 深比较 | `equal` | `app/webapps/pod/state/knowledge-draft.ts:72`、`pod/draft-navigation-guard.tsx:10`、`app/ankole-browser/src/daemon/session-actor.ts:302`。键序敏感的 `JSON.stringify` 指纹不能换 |
| `JSON.parse` 之后是不是对象 | `isRecord` / `recordValue` | `app/agent_computer/src/cli/pod/pod-cli.ts:669`、`worker/lambda-hooks.ts:20`、`cli/cli-guidance.ts:123`、`fabric/envelope_proto.ts:99`。失败方式留在调用方 |
| 去重 | `uniq` | `tools/mcp/mcporter-config.ts:149`、`tools/mcp/config.ts:175` 和 `:291`、`core/codex-runner/runtime-config.ts:115` 里的 `[...new Set(arr)]` |
| 文件大小，1024 进制 | `formatFileBytes`（`app/webapps/common/file-format.ts`） | `app/webapps/pod/page-files.tsx:140` 把任意大小写成 `Math.ceil(size / 1024) KB` |
| 技术名词可读化 | `humanizeTechnicalLabel`（`app/webapps/common/humanize-technical-label.ts`） | `app/webapps/console/pages/directory-access.tsx:23` 的 `humanizeToken`。换上之后 `oauth_provider` 会显示成 `OAuth provider`。`agent-library-capabilities.ts:71` 的 `humanizeAgentPluginID` 把每个连字符分段都做成标题大写，结果是 `Deep Research`，现有函数会得到 `Deep research` |
| MCP realpath 前缀 | `pathIsWithin`（`app/agent_computer/src/core/path-boundary.ts:11`） | `tools/mcp/config.ts:203`。根是 `/` 时 `startsWith('//')` 会判错 |
| 字符串键 payload | `Ankole.Plugins.MapHelpers` | `chatgpt_auth.ex:812` 的 `optional_text/2` 可换 `MapHelpers.optional_text/2`。`signals/webhooks.ex:559` 的 `reject_nil_values/1` 就是 `compact_map/1`。`schedule/normalizer.ex:378` 的 `optional_boolean/3` 对显式 `nil` 报错，`MapHelpers` 会当成缺省，不能无差别替换 |
| 帮助旗标 | `cli/webhooks/webhook-cli.ts:85` 的 `helpRequested` | `cli/drive/drive-cli.ts:45`、`cli/pod/pod-cli.ts:681` |
| 十六进制摘要 | `app/function_runtime/main/node_crypto.ts` 的 `hash(..., 'hex')` | `app/function_runtime/main/index.ts:91` 的 `codeDigest` 十六进制循环 |
| JSON 请求体编码 | `standard.rs` 的 `encode_protocol_json` 与 `request_builder.rs` 的 `encode_json` 二留一 | `app/kernel/src/universal_ai_client/api_resolver/standard.rs:838` 与 `request_builder.rs:66`。都是 `sonic_rs::to_string`，错误码 `request_encode_failed`，文案相同 |
| form-urlencoded | `url::form_urlencoded::Serializer`（`url` crate 已在 kernel 依赖里） | `app/kernel/src/universal_ai_client/api_resolver/web.rs:621` 的 `encode_query`，约 21 行。未保留字符集 `A-Z a-z 0-9 - _ . ~`，空格变 `+`。同文件的 `decode_userinfo`（`transport/proxy.rs:262`）对非法 `%` 报错，并且不把 `+` 当空格，保留手写 |
| HTML 转义 | `Phoenix.HTML.html_escape/1`。`spa_controller.ex` 已经在用 | `sessions/wake_briefing.ex:1037` 的 `xml_escape/1`、`sessions/tools/skill.ex:112` 的 `escape/1`。都是 `& < > "` |
| 原子写 | `app/agent_computer/src/common/atomic-write.ts` 的 `writeFileAtomicSync` | `cli/cli-guidance.ts:75` 的 `writeContextGenerationFile`，约 25 行。差别是没有 `flag: 'wx'`，失败时在 `catch` 里删临时文件 |
| `ENOENT` | `nodeErrorCode(error) === 'ENOENT'` | `tools/mcp/config.ts:294` 的 `isMissingFileError`，以及 `cli/pod/pod-cli-bridge.ts:126` 和 `:237`、`core/codex-runner/job/project-config.ts:101`、`browser-runtime/materializer.ts:217`、`core/codex-runner/runtime/agent-home-config.ts:75`、`core/real-path-boundary.ts:18`、`drive/paths.ts:49`、`tools/computer/ls-tool.ts:78`、`worker/function-compute-bootstrap.ts:17`。`tools/computer/computer.ts` 的 `bun -e` 字符串不能改成 import |
| 错误消息 | `common/errors.ts` 的 `errorMessage` | `tools/computer/ls-tool.ts:80` 和 `:97`。`computer.ts` 里的同一句在隔离脚本中，保持内联 |
| UTF-8 尾部截断 | 应补在 `common/text-sanitize.ts` 的 `truncateUTF8Safe` 旁边 | `core/codex-runner/job/turn-content.ts:79` 的 `truncateUTF8SuffixSafe`，约 23 行，算法相同，从尾部切 |
| 带 `...[truncated]` 的 UTF-8 前缀 | `truncateUTF8Safe` + `utf8ByteLength`，目前没有带后缀的包装 | `core/codex-runner/job/projection.ts:95`（上限 16384）、`protocol.ts:107`（上限 2048，先消毒）、`turn-content.ts:52`（上限 256）。消毒和状态标志留在调用方 |

`safeJsonParse` 已经在用。这几处仍是 `try/catch JSON.parse`：`pod/chat/tool-run-view.tsx:33`（失败时保留原字符串）、`console/pages/setting-value-editors.tsx:185`、`settings-task-editor.tsx:90`、`background-agent-jobs.tsx:1183` 的 `prettyJSON`。

## 2. 控制面成段算法

这些没有现成主人。

### 唤醒简报与 Brain 记忆包

`sessions/wake_briefing.ex:147` 对 `ai_gateway/hosted_tools/brain.ex:526`。实体行、事实行、`open threads:` 块、空 slug 丢掉、超预算用 `estimate_o200k_base_tokens` 再截断。渲染约 70 行，预算折行约 40 行。

Brain 给每行套 `Delimiters.recalled_memory/1`，并按剩余预算裁单行。唤醒简报按整行加 1 token 计换行，只有第一行超预算时按整段预算裁，并多一条从尾部取行的路径。

### 从 response items 提取工具输出

`conversations/delivery/action_card_prompt.ex:14` 与 `clarify_prompt.ex:12` 几乎逐行相同，各约 35 行。先把指定工具名的 `call_id` 放进 `MapSet`，再 `reduce_while` 扫 `function_call_output`，命中才 `ToolOutput.decode/1`。`delivery/attachment.ex:32` 是同一扫描，收成列表，约 45 行。三者的输出字段校验不同。`ToolOutput.decode/1` 只负责 JSON 解码。

### Job 与 Workflow 的 UTF-8 结果窗口

`background_agent_jobs/schemas/job.ex:311`、`background_agent_jobs/queries.ex:287`、`sessions/background_agent_job_broker.ex:213`，对照 `workflow/schemas/run.ex:137`、`workflow/queries.ex:52` 与 `:328`。

SQL 都是 `substring(convert_to(..., 'UTF8') from ? for ?)` 加 `octet_length`。未完成时返回空文本和 0 字节。窗口首字节若落在 UTF-8 continuation 上则拒绝。Job 窗口 16384 字节，并对非法尾部再走 `Text.utf8_prefix`。Workflow 窗口 8000 字节。`Ankole.Text.utf8_prefix/2` 不管这个 1-based SQL 窗口。

### 相邻的较小副本

| 行为 | 位置 | 差异 |
| --- | --- | --- |
| 创建幂等的 advisory lock key | `workflow/lifecycle.ex:290`、`background_agent_jobs/dispatch.ex:418` | 前缀是 `workflow:create` 与 `background_agent_job:start`。都用 `:` 拼接 `agent_uid`、`owner_session_id`、`source_tool_call_id`，再 `AdvisoryLock.lock/2`。各约 12 行 |
| 拒绝未声明的创建字段 | 上面两个文件，以及 `workflow/result_schema.ex:91` | 键集差集再排序。允许字段表和错误原子不同 |
| 错误 `code` / `summary` | `background_agent_jobs/schemas/job.ex:303`、`workflow/console_queries.ex:107` | `code` 截到 200，`summary` 缺了用 `message`，再截到 1000。Job 用 SQL `left`。Workflow 在内存里截，非字符串先 `JSON.encode!` |
| 降序整数 id 游标 | `workflow/queries.ex:96` 与 `:296`、`workflow/console_queries.ex:52` | `id < cursor`，`sort id: :desc`，下一游标是最后一行 id。后台 Job 列表已经用 opaque keyset（`background_agent_jobs/queries.ex:346`），这两处没有 |
| 非空、合法 UTF-8、不含 NUL | `sessions/key.ex:10`、`conversations/native.ex:1335`、`signals/intake.ex:288` | 成功时保留原文，不返回 trim 后的文本。失败分别是 `:error`、`{:error, :invalid_text}`、`{:error, :invalid_signal}`。`Attrs.required_text/2` 会 trim，不查 NUL |
| NFKC 折叠 | `brain/links.ex:232`、`ai_agent/library/skill_lessons.ex:302` | `String.normalize(:nfkc)`、`downcase`、空白折成一个空格、再 `trim`。`brain/claims.ex:784` 少了 NFKC，是另一份 |
| 页面正文摘录 | `pod/pages/mentions.ex:701` 与 `:970`、`pod/pages/queries.ex:285` 与 `:315` | 都按 `[:doc, :knowledge]` 读 `plain_text`，trim 后 `String.slice(0, 300)` |
| 标题或正文每个词都要命中 | `pod/pages/queries.ex:653` 与 `:732` | 同一文件里两段 `bool_and(... ILIKE ...)`。同文件 `:620` 是 Ash 版的同一规则 |
| 用户文本消息 | `ai_gateway/chatgpt_protocol.ex:76`、`stateful_lifecycle.ex:1235`、`hosted_tools/stream_loop.ex:582`、`hosted_tools/brain.ex:679` | map 都是 `type: message`、`role: user`、`content: [%{type: input_text, text}]`。列表路径的校验不同 |
| `provider_options` 非空才写入 | `brain/embeddings.ex:111`、`brain/model_calls.ex:70`、`brain/source_learning.ex:509` | 前两处用 `Map.get`，第三处用字符串键，对字符串键等价 |
| 库源 TTL 缓存 | `ai_agent/library/source_reader.ex:217`、`ai_agent/library/agent_plugins/source_reader.ex:35` | 命中条件、过期时间和 `put` 的字段相同，约 24 行。Owner 是 `Library.SourceCache`，包装各写了一份 |
| `stat` 得到 `:enoent` 再 `lstat` | 上面两个 source reader，各两处（约 `:293`、`:340` 与 `:94`、`:132`） | 用来区分真缺失和悬空符号链接。成功值和错误值不同 |
| 非空文本才写入 | `ai_gateway/tool_search.ex:1209`、`programmatic_tool_calling.ex:1044`、`provider_configs/credentials.ex:452` | `Attrs.maybe_put/3` 会保留 `""`，不能直接替换 |
| `list_of_maps` | `hosted_tools/stream_loop.ex:761`、`tool_search.ex:1219` | 各 2 行 |
| 事务内 raise | `files/objects.ex:230`、`pod/files/content.ex:125`、`pod/files.ex:661` | `Repo.require_transaction/0` 返回 `{:error, :transaction_required}`，不是 raise |
| 会话作者 uid 查询 | `brain/conversations_learning.ex:579`、`brain/request_context.ex:292` | 查询相同。后者再留下 `type: :human` |
| OIDC Origin | `oidc/user_info.ex:44`、`ankole_web/controllers/oidc_controller.ex:221`、`plugs/require_ai_gateway_access_token.ex:196` | 缺失 Origin 放行，恰好一个交给 `OIDC.origin_allowed?/2`，多个拒绝。各约 11 行 |
| JSON 错误体 `%{error: %{code, message}}` | `require_ai_gateway_access_token.ex:244`、`plugs/oidc_cors.ex:52`、`plugs/put_data_context.ex:31`、`controllers/ai_gateway_web_socket_controller.ex:45` | 彼此相同，状态码和文案不同。`ConsoleErrors.render/5` 多一个 `details`。登录拒绝的状态映射在 `auth_controller.ex:204`，主人是 `browser_api/error.ex:21` |
| Signal adapter 与 webhook handler 的 `fetch` | `signals/adapters.ex:89`、`signals/webhook_handlers.ex:69` | 列出声明、按 id 查找、找不到就返回带 id 的 not-found。错误原子不同。delivery 和 preview 是 adapter 自己的 |
| JSON 再 `SecretKeyBase.seal` | `app_configure/crypto.ex:8`、`ai_gateway/provider_configs/crypto.ex:10` | purpose 和 context 不同，密文不能互换。能共享的只有「encode 然后 seal」这一层，AAD 留在各自模块 |
| OAuth state 的租户前缀 | `connectors/oauth.ex:80` 与 `:88` | 同一文件写了两次：`split(".", parts: 2)`、`Ecto.UUID.cast`、`Repo.with_tenant`，否则 `:invalid_oauth_state` |
| 递归 map 覆盖 | `connectors/legacy_config.ex:210` 的 `deep_merge/2`、`signals/bindings.ex:776` 的 `merge_binding_config/2` | 两个值都是 map 就递归，否则取右边。`ai_agent/library/contracts.ex:114` 的 `merge_metadata/2` 多了「`nil` 删键」 |
| 用量树相加 | `ai_gateway/credential_pool.ex:638`、`hosted_tools/stream_loop.ex:751` | 两边都是数就相加，两边都是 map 就递归，否则取右边。`credential_attempts.ex:679` 的 `subtract_usage/2` 是同一棵树的减法 |
| 按密钥字符串递归打成 `[REDACTED]` | `connectors/http.ex:161`、`conversations/delivery/secret_filter.ex:70` | 按键名打码的 `Signals.Sanitizer` 和 `Observability.Trace.sanitize/1` 是另一套规则 |
| 按 grapheme 走字节预算 | `ai_gateway/tool_search.ex:948`、`pod/pages/tree.ex:825`、`plugins/markdown_chunks.ex:146` | `String.slice/3` 按码点，`Text.utf8_prefix/2` 会拆开 grapheme。`markdown_chunks` 切成多段，不是只留前缀 |
| `min(base * 2^attempt, cap)` | 会话侧主人是 `TurnErrorClassifier.delay_seconds/3`（`sessions/turn_error_classifier.ex:69`） | 同一公式、不同常数：`conversations/delivery/recovery.ex:451`、`oidc/logout.ex:204`、`agent_workers/reconcile_job.ex:101`、`ai_gateway/credential_attempts.ex:702`（多了 ±10% jitter）。`connection_lifecycle` 用固定毫秒表 |
| 内部 UUID 换成 `[internal-id]` | `background_agent_jobs/wakeups.ex:13`、`background_agent_jobs/turns.ex:67`、`sessions/tools/jobs.ex:569` | 同一正则 `~r/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i` |
| `format_reason`：二进制原样，否则 `inspect` | `programmatic_tool_calling.ex:1035`、`program_execution.ex:186`、`hosted_tools/brain.ex:523` | 另外 `workflow/run_server.ex:537` 带 `limit: 20`，`sessions/tools.ex:175` 带 `printable_limit: 2_000` |
| 正整数否则 `nil` | 没有主人。`Attrs.integer_value/1` 会解析十进制字符串，但不要求 `> 0` | `observability.ex:752`、`ai_gateway/observability.ex:579`、`model_profiles.ex:474`、`usage_ledger.ex:92`、`sessions/turn_envelope.ex:143` |
| `expected_updated_at` 相等 | `conversations/action_cards.ex:1154` 与 `:1181` | 同一文件两处：二进制则 `DateTime.from_iso8601` 后 `DateTime.compare == :eq` |
| 公开 item / call id | `ai_gateway/response_stream/state.ex:1376` 与 `:1402` | 都是 SHA-256、小写 hex、取 24 字符、冲突则 `attempt + 1`。种子标签一个是 `"item"`，一个是 `"call"` |
| 环境变量名 | 没有库函数 | `app/agent_computer/src/core/execution/command-env.ts:11` 与 `tools/mcp/config.ts:30`，正则 `/^[A-Za-z_][A-Za-z0-9_]*$/` |
| 浏览器守护进程重启延迟 | `browser-runtime/daemon-supervisor.ts` 内部 | `:91` 与 `:103` 都是 `Math.min(5_000, 250 * 2 ** attempts)` 然后自增 |
| 正则元字符转义 | 没有 active-support 导出 | 前端：`libs/ankole-editor/src/react/MentionMenu.tsx:43`、`app/webapps/pod/comment-thread.tsx:302`、`pod/state/chat.ts:69`、`pod/chat/composer.tsx:641`。Agent Computer：`tools/computer/grep-tool.ts:78`、`core/agent-home-paths.ts:61`、`core/codex-runner/job/skill-usage.ts:91`。都是 `replace(/[.*+?^${}()|[\]\\]/g, '\\$&')` |

Schedule 和 Automation Jobs 没有新的成段复制。Session 与 Conversation 的状态机转移表没有互抄。路径规范化、ACL、Base 字段强制转换、公式主体、文件流拷贝、embedding 批处理各自只有一个主人。PKCE、cookie、OTP 比较、限流窗口、SSRF、邀请 token 哈希、Principal UID 没有第二份。`stable_json/1` 只在 `sessions/tools/schedule.ex:488`。

`files/paths.ex:195` 的 `ensure_folders/3` 与 `brain/objects.ex:147` 的 `destination/2` 都是沿路径分段查找、没有就创建。授权、节点类型和创建 API 不同，不能对调。

工具参数解码的 map 和 JSON object 分支相同，失败值不同：`tool_search.ex:985` 返回 `nil`；`hosted_tools/brain.ex:511` 非法 JSON 返回 `nil`、`nil` 参数返回 `%{}`；`programmatic_tool_calling.ex:1022` 非法 JSON 变成 `%{"query" => arguments}`。

页面 mention 的另一条正则不是同一份：`pod/pages/mentions.ex:17` 是自闭合 `<mention page="..."/>`；`brain/links.ex:49` 允许前面还有属性，不要求自闭合。

## 3. 适配器

飞书、企微、钉钉的令牌单飞，以及 Slack、Microsoft、Google 的 JSON 解码、`Retry-After` 和下载文件名，已经走 `IMTransport`。`Ankole.Plugins.MarkdownChunks` 负责企微和钉钉的 Markdown 切块。`ChunkedMessagePreview` 负责 Telegram 和 Discord 的预览账本。`ConnectionLifecycle` 负责 Telegram 和 Discord 的连接协调。

还没有收口的：

| 行为 | 位置 |
| --- | --- |
| 凭证缓存命名空间：SHA-256(secret)，函数则 `:erlang.phash2`。企微和钉钉还有空密钥拒绝、`http(s)` base URL 校验 | `plugins/lark_adapter/lib/feishu_openapi/client.ex:292`、`plugins/wecom_adapter/lib/wecom_openapi/corp/client.ex:86`、`plugins/dingtalk_adapter/lib/dingtalk_openapi/client.ex:101` |
| OAuth 访问令牌 ETS 缓存：提前 60 秒过期，缺 `expires_in` 按 300 秒。应改用 `IMTransport.TokenCache`，这两份没有单飞，过期行也不删 | `plugins/google_workspace_adapter/lib/google_openapi/auth.ex:84`、`plugins/microsoft365_adapter/lib/microsoft_openapi/entra_auth.ex:68`。`exchange_code` 的 form 和返回字段同样是同一段（Google `auth.ex:42`，Entra `entra_auth.ex:44`） |
| 错误类型：429、传输层、HTTP ≥ 500 可重试，`Inspect` 把 `raw` 打成 `:redacted` | `slack_openapi/error.ex:13`、`microsoft_openapi/error.ex:13`、`google_openapi/error.ex:13`。企微 `wecom_openapi/error.ex:61` 与钉钉 `dingtalk_openapi/error.ex:68` 的 `message/1`、`transport/1`、`Inspect` 是另一对，字段多两个 |
| 分页里对 429 最多睡 3 次，成功后重试计数归零 | Slack、Microsoft、Google 的 `pagination.ex`。`get_in_path` 的逐段 `Map.fetch` 在飞书 `feishu_openapi/pagination.ex:199`、钉钉 `dingtalk_openapi/pagination.ex:85`、Slack `slack_openapi/pagination.ex:51` |
| 旧域名 `errcode == 0` 才算成功，外加下载、query 规范化、URL 拼接。JSON body 应调用 `IMTransport.HTTP.put_body/2` | `wecom_openapi.ex` 与 `dingtalk_openapi.ex`（解码约 `:122` / `:159`，下载约 `:62` / `:82`，URL 约 `:105` / `:111`） |
| Webhook HMAC-SHA256 + `Plug.Crypto.secure_compare`，缺参直接 false | LINE `line_adapter/signature.ex:9`（Base64）、WhatsApp `whatsapp_adapter/signature.ex:9`（`sha256=` 加小写 hex）、GitHub `github_adapter/connector.ex:253`（与 WhatsApp 编码相同） |
| HTTP 客户端：`retry: false`，错误文案截到 500 | Telegram `telegram_adapter/client.ex:89` 对 Discord `discord_adapter/client.ex:133`。LINE `line_adapter/client.ex:74` 对 WhatsApp `whatsapp_adapter/client.ex:92`。窗口对齐大约 67 行。信封和错误字段不同 |
| 投递错误阶梯：429 和传输可重试，401/403 人工，≥500 可重试，400 永久 | Telegram、Discord、LINE 的 `error_policy.ex`。Discord 多了 404 永久。LINE 把含 “monthly limit” 的 429 改成人工。WhatsApp 默认是 `:permanent`，不并进这一条 |
| 目录同步：先建群成员倒排索引，再按用户 upsert | Google `identity_provider.ex:106`、Microsoft `identity_provider.ex:210`、Slack `identity_provider.ex:122`。窗口上 Google 对 Microsoft 大约 75 行 |
| 用户归一化：部门 id 写入 metadata，再 merge `observed_profile` | 企微 `identity_provider.ex:146` 对钉钉 `identity_provider.ex:109`，窗口大约 102 行。企微丢掉根部门 `1`，钉钉原样转字符串 |
| 群成员 uid：`reduce_while`，`uniq` 再 `sort`；离开则改写 status | Slack `channels.ex`、Teams `teams_channels.ex`、飞书 `im_groups.ex`。同步循环同样是 `ensure_group` → 成员 → `replace_members`，遇错停 |
| 按 grapheme `chunk_every`，空串变成 `[""]` | 飞书 `lark_adapter/delivery.ex:612`、Slack `slack_adapter/delivery.ex:359`、Teams `microsoft365_adapter/delivery.ex:333`。`MarkdownChunks` 按字节切，不管这个 |
| Webhook 按实例 id 找 binding：跨租户列出启用项，租户内读配置，匹配失败打日志并跳过 | LINE `webhook.ex:91`、WhatsApp `webhook.ex:165`、Teams `teams_webhook.ex:83` |
| 每套凭证一个懒启动进程：Registry 查找，没有就 `DynamicSupervisor.start_child`，`:already_started` 取已有 pid | 企微与钉钉的 `token_manager.ex:71`。监督树 `supervisor.ex` 也是同一份：TokenStore、Registry、DynamicSupervisor、Task.Supervisor，`rest_for_one`。飞书再加 `UserTokenManager` |
| 重连 | 企微 `wecom_openapi/bot/client.ex:472` 与钉钉 `dingtalk_openapi/stream/client.ex:376` 是 `1 << min(attempt, N)` 秒。飞书 `feishu_openapi/ws/client.ex:644` 与 Slack `slack_openapi/socket_mode/client.ex:322` 是第一次随机、之后固定间隔 |
| WS `child_spec` | 钉钉 stream、飞书 WS、Slack socket mode、企微 bot 的 `child_spec` 逐字相同，各 8 行。钉钉 stream 与 Slack socket mode 另有大约 100 行客户端骨架对齐（启动、收包、定时器），重连策略仍是上面这两对 |
| 流式卡片状态机 | 钉钉 `dingtalk_adapter/ai_card.ex` 与企微 `wecom_adapter/ai_stream.ex` 归一化后大约 100 行。卡片字段不同 |
| LINE 对 WhatsApp | `inbound.ex` 大约 53 行 |
| Discord 对 Telegram | `config.ex` 大约 60 行、`reply_preview.ex` 大约 41 行、`delivery.ex` 大约 41 行。`deliver/1` 和 `new/2` 函数体逐字相同 |
| 手机号 E.164 | Google `identity_provider.ex:297` 与 Microsoft `identity_provider.ex:355` 都是 trim 后 `NativeKernel.phone_normalize_e164`，失败变 `nil`。飞书、企微、钉钉、Slack 走已共用的 `Phone.normalize_china_mobile/1` |
| 预设 base URL | `china_market_ai_providers` 的 `xiaomi_mimo.ex:56` 与 `zai_coding_plan.ex:47`。trim 后等于两个已知地址或空串则用套餐默认，否则保留操作员填的地址 |

没有 PKCE。时间戳偏移只在飞书 webhook（`feishu_openapi/event.ex:185`）。企微和钉钉的 `@` 前缀剥离、Slack 与 Teams 的可见文本、飞书与钉钉的分页游标、Markdown 降级、emoji 对照表，控制流并不相同。

## 4. 模型供应商、Worker、Resolver

请求体和 Worker 对账已经有 `Ankole.AIGateway.UniversalAIRequest`、`OpenAIRequestOptions`、`ReasoningEffort`、Rust `standard.rs` / `custom_tool_emulation.rs` / `tool_identity.rs`，以及 `Ankole.AgentWorkers.ProviderKind` 和 `ReconcileJob`。阿里云、火山、Google 对话、OpenRouter 对话只是 `UniversalAIRequest.new` 加鉴权。Embeddings、rerank、web search 已分别收进 `normalize_embedding_body`、`resolve_rerank_body`、`normalize_search_body`。

绕过去的：

| 行为 | 位置 | 说明 |
| --- | --- | --- |
| Anthropic 请求头 | `ai_gateway/providers/claude.ex:62`、`plugins/china_market_ai_providers/.../xiaomi_mimo.ex:45` | `maybe_put_beta/2` 三子句相同。都写 `messages` 路径、`anthropic-version`，再按 `auth_mode` 在 `auth_token` / `oauth` 与 `x-api-key` 之间分支。小米 bearer 用 `access_token \|\| api_key` |
| OpenAI 家族三路组装 | `providers/openai.ex:79`、`providers/openai_compatible.ex:60` | Responses + 流式 + websocket、其余 Responses SSE、否则 `chat/completions`。叶子已经进共享模块。OpenAI 每条臂先写 organization/project 头 |
| ChatGPT 订阅重写选项重命名和 Bearer | `providers/chatgpt_subscription.ex:223` 与 `:254`，对照 `openai_request_options.ex:61`、`universal_ai_request.ex:536` | `rename_option` 都是 `Map.pop`，`nil` 保留。`OpenAIRequestOptions.rename_common_options` 已经做 `serviceTier` 和 `promptCacheKey`。Bearer 前缀逻辑也已有 `bearer_auth` |
| Rust Chat 与 Anthropic 的 Responses 流式组装 | `openai_chat.rs:334` 起、`anthropic.rs:187` 起 | `ensure_message_item` 在 `openai_chat.rs:364` 和 `anthropic.rs:227` 逐字相同。`fail`、`finish`、`response_body` 还有大约 80 行同一控制流。`AWSBedrockConverseState` 已经包了 `ChatState`，Anthropic 没有。上游事件解析不是同一套 |
| HTTP 成功门闩 | `openai_chat.rs:719`、`anthropic.rs:603`、`openai_responses.rs:272`、`aws_bedrock_converse.rs:94`、`embeddings.rs:65`、`google_embeddings.rs:139`、`rerank.rs:36`、`openrouter_images.rs:17`、`web.rs:366` | 状态不在 200..299 就 `provider_body_error`，否则拒绝带 `error` 的 JSON，再取对象。`web.rs` 的 `checked_provider_object` 就是这段，但是私有的。应提到 `standard.rs`。传输层在 JSON 解析之前的 `200..300` 不要并进去 |
| 原样保留 usage 对象 | `embeddings.rs:79`、`rerank.rs:58` | `usage` 是对象就克隆，否则 `{}`。要保留 `image_tokens` 这类额外字段，不能改走 `normalize_response_usage` |
| Chat 历史里的 function call 与 custom tool call | `openai_chat.rs:1293` 与 `:1330` | `call_id` 空则生成，`name` 空则 `"unknown"`，再按 namespace 压平。下一行才分叉参数编码 |
| 输出图片 MIME | `openrouter_images.rs:47`、`hosted_responses/image_transport.rs:155` | `jpeg` → `image/jpeg`，`webp` → `image/webp`，其余 → `image/png` |
| 一次性响应里的 function_call | `openai_chat.rs:805`、`anthropic.rs:683` | 外壳相同：生成 id，缺省 name `"unknown"`，`status: completed`，然后 `restore_tool_namespace` + `restore_custom_tool`。参数来源不同。流式路径的 `function_call_item` 已经在 `standard.rs` |
| 搜索结果别名 | `web.rs:422`、`:441`、`:467`、`:484` | 四家的非对象回退和 `title` 读取逐字相同。URL、摘要、日期是各家的键列表。输出已经走 `search_result`。叶子不合成一个函数 |
| 创建冲突后按 owner 标签认领 | `agent_workers/docker.ex:98`、`agent_workers/kubernetes.ex:220` | 创建；409 则按名字再读；标签匹配则当作同一次创建成功；否则 owner mismatch。Docker 匹配后还要 start。Kubernetes 还比对 `ankole.io/agent-uid` |
| 单个 Agent 的清单附上最后 50 行日志 | `docker.ex:165` 与 `:373`、`kubernetes.ex:278` 与 `:651` | `:all` 不拉日志。单个 Agent 取 tail 50，成功就把日志接到 `reason` |
| 已保存引用第一次观测就消失时，只报告一次 exited | Vercel `vercel_worker_provider/provider.ex:166`、函数计算 `function_compute.ex:193` | 404 且 `instance_seen_at` 为 nil：发一条 `phase: :exited`。已经见过则丢掉。Lambda 的未见过 404 返回错误，不合成 exited |
| 游标分页直到没有下一页 | `agent_workers/lambda/client.ex:12`、Vercel `provider/client.ex:34`、函数计算 `images.ex:38` 和 `client.ex:44` | 页大小和下一页令牌的字段不同 |
| `collect/2` | `agent_workers/lambda.ex:450`、Vercel `provider.ex:521` | 函数体相同：`Enum.reduce_while`，`{:ok, values}` 则拼接，其他 `{:halt, error}` |
| HTTP 结果分类 | Vercel `provider/client.ex:4`、函数计算 `client.ex:172` | `retry: false`；2xx 成功；否则 `{api, status, code, message}`；传输失败则 unreachable。超时和错误码字段不同。置信度中 |

SSE 解码只有 `wire.rs`。请求头只有 `request_builder.rs`。用量换算已经在 `standard.rs`：Chat 用 `normalize_response_usage`，Anthropic 用 `normalize_anthropic_usage`，Bedrock 用 `normalize_provider_token_usage`。Cloudflare 是独立适配器协议。Lambda 镜像构建没有对得上的副本。

## 5. 前端和编辑器

已经有主人、扫描确认没有第二套实现的：`formatFileBytes`、`useDebouncedValue`（`app/webapps/common/use-debounced-value.ts`）、`cn`（`libs/uikit/src/lib/utils.ts`）、Console 列表过滤（`console/state/resource-search.ts` 和 `console-list-page.tsx` 的 `useResourceSearchDraft`）、路由加载器（`console-route-loaders.ts`）、uikit 的 `useIsMobile` 和 `commitCronNumberDraft`。auth 和 setup 都用 `common/email-otp-input`。Markdown 有两条管线（`common/markdown-renderer.tsx` 与 `pod/chat/markdown-renderer.tsx`），标题组件没有互相复制。

### 相对时间、绝对时间、下载

相对时间写了两套。`pod/document-mentions.tsx:41` 的 `formatRelativeTime` 不足 60 秒按秒，失败时 `iso.slice(0, 10)`。`pod/content-list.tsx:438` 的 `formatPageTimestamp` 不足 60 秒走 `rtf.format(0, 'minute')`，失败时 `toLocaleDateString()`。调用还在 `page-subpages.tsx`、`chat-sidebar.tsx`、`chat-home-view.tsx`。收到 `common` 的一个函数，亚分钟只留一种。

绝对时间。Console 的主人是 `console/console-primitives.tsx:60` 的 `formatConsoleDate`。Pod 的 `document-history.tsx:77`、`document-insights.tsx:35` 和 `:121` 再写了同样的 `Intl.DateTimeFormat`。`applet-automation.tsx`、`pod-settings.tsx:898`、`base-field-types.ts:75` 用浏览器默认 `toLocaleString()`，没有跟界面语言。`console-primitives.tsx:53` 的 `formatDuration`、`pod/chat/elapsed.ts` 的 `formatElapsed`、`pod/file-comment-anchors.ts:99` 的 `formatMediaTimestamp` 是三套不同的时长，不要并。

`datetime-local`。Console 已有 `console/state/token-quota-editor-model.ts:32` 的 `dateTimeLocalValue` 和 `:41` 的 `instantFromDateTimeLocal`。Pod 在 `state/field-input.ts:9`、`state/pod-settings.ts:60`、`applet-automation.tsx:817` 又用时区偏移加 `toISOString().slice(0, 16)`。

Blob 下载（`createObjectURL` → `<a download>` → 稍后 `revokeObjectURL`）：

- `pod/document-recovery.tsx:63` `downloadFile`
- `pod/state/document-export.ts:266` `saveDownload`
- `pod/chat/export-markdown.ts:55`
- `pod/meta-skill-files.tsx:22`
- `pod/chat/mermaid/mermaid-download.ts:81`（多了 `rel=noopener`）
- `pod/chat/select-share-lightbox.tsx:139`
- `console/pages/agent-files.tsx:313`（立刻 `revokeObjectURL`）

`export-markdown.ts:59` 和 `select-share-lightbox.tsx:142` 的文件名清洗都是 `replace(/[/\\:*?"<>|]/g, '_')`。`documentFilename` 和 `common/bidi.ts` 的 `sanitizeFileName` 合同不同，不要并进去。

`blobToDataUrl` 两份，各 8 行，相似度 0.98。`pod/chat/select-screenshot.ts:97` 和 `pod/chat/mermaid/mermaid-download.ts:9` 都是 `FileReader.readAsDataURL`，只有失败文案不同。

OIDC 回调地址复制。`pod/pod-settings.tsx:990` 的 `copyCallbackURL` 和 `setup/app.tsx:584` 都是写入剪贴板、成功 toast、2 秒后清掉「已复制」。聊天里的「已复制」是另一组，超时 1500ms：`common/markdown-renderer.tsx:41`、`pod/chat/code-block-view.tsx:63`、`message-actions.tsx:50`、`pod/chat/markdown-renderer.tsx:103`、`mermaid-diagram.tsx:154`、`select-share-lightbox.tsx:37`、`page-files.tsx:862`。Website 里两份 `CopyButton` 连 `execCommand` 回退都一样，超时 2000ms：`app/website/src/components/docs/QuickstartTabs.tsx:421`、`app/website/src/components/landing/QuickStartTabs.tsx:35`。Website 不依赖 webapps，主人放在 `app/website/src`。

### Console 草稿、列表和徽章

六处 `captureSave` 是同一协议：记下 generation 和提交时的字段，响应回来只回写没被继续编辑的字段。

| 位置 | 大约行数 | 差别 |
| --- | --- | --- |
| `console/state/principal-group-editor-model.ts:92` | 29 | 五个字符串字段，并清掉 validation |
| `console/state/token-quota-editor-model.ts:106` | 26 | 同上 |
| `console/state/identity-editor-model.ts:65` | 25 | `config` 用 `equal` |
| `console/state/worker-provider-editor-model.ts:132` | 33 | 凭证是差量过滤 |
| `console/state/tenant-editor-model.ts:56` | 18 | `brainPacks` 用 `equal`，不清 validation |
| `console/state/worker-env-editor-model.ts:83` | 15 | 成功时 `valueRevision++` |

凭证差量和 `valueRevision` 留在各自 model。

Cron 文案。`pod/applet-automation.tsx:616` 把 `console/console-form.tsx:621` 的 `cronEditorLabels` 写进了 JSX，逐行对齐约 22 行。字段是 `mode`、六种 mode、weekday 数组、`expression`。Console 的 schedules 和 brain settings 已经调用导出函数。放到两边都能引用的模块，Pod 不要去 import `console-form`。

任务状态徽章。`console/pages/home.tsx:535` 的 `JobStatus` 与 `background-agent-jobs.tsx:625` 的 `StatusBadge` 相似度 1.00：`failed|stopped` → danger，`succeeded` → positive，`running` → info，`waiting_on_user` → waiting，其余 neutral。`schedules.tsx`、`webhooks.tsx`、`automation-jobs.tsx` 的状态词不同。

事实格。`conversations.tsx:453` 的 `DetailField` 与 `background-agent-jobs.tsx:669` 的 `Fact` 相似度 0.99。`automation-jobs.tsx:310` 是更瘦的第三份。扫描还对上：`token-quota-editor.tsx:330` 的 `QuotaFact`、`background-agent-jobs.tsx:921` 的 `Metric`、`provider-credentials.tsx:473` 的 `CredentialFact`。`automation-jobs.tsx:299` 的 `RunLog` 和 `provider-credentials.tsx:484` 的 `CredentialDiagnostics` 是同一块诊断布局，相似度 0.85。

授权表接线。`principal-groups.tsx:584` 的 `GroupGrantsSection` 与 `principals.tsx:403` 的 `PrincipalGrantsSection` 相似度 0.78，都是 `useQuery` → `fromDocument` → `PermissionGrantsSection`。

头像。`principal-groups.tsx:605` 的 `MemberAvatar` 与 `principals.tsx:424` 的 `PrincipalAvatar` 相似度 0.77：有图用图，否则取首字母。记录类型不同，后者多一个 `size`。

主张类型徽章。`console/pages/brain/claims.tsx:179` 与 `brain/principal-audit.tsx:102` 都是 `claim_type === 'fact' ? 'secondary' : 'info'` 再拼 `claim.kind`。`search-preview.tsx:207` 直接显示原始 `claim_type`。

Webhook 与 Schedule 的列表工具栏。`webhooks.tsx:193` 与 `schedules.tsx:365` 都是 `ResourceSearch` 加 `AgentFilter` 加「包含已结束」。

Company Brain 的 `brain/schemas/merge_suggestion.ex` 与 `schema_suggestion.ex` 资源声明大约 100 行同形。Console 的 `pages/brain/merge-suggestions.tsx` 与 `suggestions.tsx` 有多段逐行对齐（约 `:114`、`:166`、`:219`、`:236`）。

`add-membership-picker.tsx` 与 `principal-picker.tsx` 开头约 12 行 import 相同，`:60` 附近还有一段对齐。`custom-model-profiles-editor.tsx:318` 与 `model-profiles-editor.tsx:218` 对齐 7 行。`provider-enterprise-credential.tsx` 与 `provider-chatgpt-login.tsx` 有两段对齐（约 `:129` / `:210`，以及 `:23` / `:65`）。这些是表单骨架，合并前要再看字段是否真的同一协议。

### Pod 交互

菜单关闭后是否把焦点还回行：`pod/page-subpages.tsx:612`、`page-navigation.tsx:701`、`chat/chat-sidebar.tsx:81`。`page-subpages.tsx:724` 的变量名是 `keepFocusInCard`。

成员命令列表：`pod/chat/new-group-dialog.tsx:189` 与 `share-popover.tsx:114`，空态和两组 `CommandGroup` 相同，一边 add、一边 toggle。逐行对齐出现在 `:209` / `:137` 和 `:229` / `:158`。

页面分享的 `SubjectPicker` 接线：`pod/page-sharing/main-view.tsx:112` 与 `invite-view.tsx:83`。邀请页多一个 `onSelectSubject`。

平台判断：`pod/app.tsx:401` 用 `/Mac|iPhone|iPad|iPod/`，`document-tools.tsx:63` 和 `sidebar.tsx:115` 用 `includes('Mac')`。收到一个 `isApplePlatform()`。

省略号截断：`console/console-primitives.tsx:11` 的 `truncate`、`common/request-errors.ts:135`、`common/error-boundary.tsx:290` 和 `:294`。`pod-url.ts:192` 的 `truncatePageSlug` 按词边界切，不是这个函数。

搜索输入防抖。`useDebouncedValue` 已经给 picker 用了（180ms）。`pod/content-list.tsx:78` 手写 180ms 并处理外部 URL 回写。`console/console-list-page.tsx:474` 的 `useResourceSearchDraft` 是 300ms，清空立即提交。收到 `common` 的一个 URL 搜索草稿 hook。`active-support` 的 `debounce` 是回调防抖，替代不了这个 hook。

文件预览。`readPrefix` 在 `pod/page-files.tsx:906` 和 `attachment-preview.tsx:215` 逐字相同，约 31 行，相似度 0.99。`TEXT_BYTES = 64 * 1024` 在两边各写一次。类型判断也是一对。另有一段 6 行对齐：`attachment-preview.tsx:173` 与 `page-files.tsx:692`。`isTextFile` 的扩展名多了 `markdown`。

### 客户端又写了一遍服务端规则

`pod/base-field-types.ts:100` 的 `effectiveFieldType` 对应 `pod/formula.ex:26` 的 `Formula.type`。两边都把 `auto_number` 当成 number，`checkbox` 当成 boolean，`created_at` / `updated_at` 当成 datetime，`user` / `attachment` / `link` 和多选 `select` 当成 array，formula 读 `result_type`。

分叉：服务端把 `created_by` / `updated_by` 落成 text，客户端落成 `person`；非多选 select 在服务端是 text，客户端仍是 `select`。`pod/state/local-query.ts:4` 是第三份，`array` 没有看 formula 的 `result_type`。`base-summary.tsx:69` 里还有内联的 number / datetime 过滤。

日期分桶。`pod/state/table-query.ts:194` 的 `bucket` 复刻 `pod/query.ex:450`：day `YYYY-MM-DD`，week `YYYY-MM-DD`，month `YYYY-MM`，quarter `YYYY-"Q"Q`，year `YYYY`。客户端用 `Intl` 自己算周一，服务端是 `date_trunc`。本地聚合继续走服务端，或者共用桶规格并核对 week 边界。

`table-query.ts:15` 的 `fieldValue` 把 `""` 和 `[]` 收成 `null`，对应 `pod/values.ex:35` 的 `Values.cast`。`table-query.ts:22` 的 `principalUID` 是 `PrincipalKey.canonicalize` 再加上 `query.ex:259` 的 `:principal/` 剥离。客户端只返回 uid。

### 编辑器

页面正规化有两个主人。`app/kernel/src/page_document/tree.rs:256` 约 640 行，`libs/ankole-editor/src/document/normalize.ts:50` 约 500 行。步骤同名：`flatten`、`neighbour`、`convertLineBreaks`、`units`、`blank`、`formatted`、`leaf`。中日文行间断开的字符类也相同。没有库能换掉它。同步手段是 kernel 测试读编辑器 corpus。XML 解析本身没有重写：kernel 用 `quick-xml`，编辑器用 `saxes`。

页面 XML 转义四个主人，规则已经分叉：

| 位置 | 行为 |
| --- | --- |
| `app/kernel/src/page_document/tree.rs:897` | 属性转义 `& < > " \t \n \r`，文本只转义 `& < > \r`，空白写成数字字符引用 |
| `libs/ankole-editor/src/document/xml.ts:58` | 与上一行同一套 |
| `libs/ankole-editor/src/document/markdown.ts:603` | 属性表少了 `>` |
| `app/kernel/src/page_document/knowledge/read.rs:250` | 一律转义引号，不处理 `\t \n \r` |

`quick-xml` 的 `escape` 会转义撇号，也不会把空白写成数字字符引用，换上去会改页面字节。`libs/ankole-editor/src/core/doc/shape.ts:286` 是视图 HTML，文本只转义 `&` 和 `<`，不要并进页面 XML。

评论 id 的 UUIDv7 形状：`page_document/comments.rs:15` 与 `document/comments.ts` 的 `commentIDPattern` 是同一条 8-4-4-4-12、版本位 7、只接受小写。kernel 已依赖 `uuid`。编辑器没有 uuid 包。

`core/set/point.ts` 与 `core/set/range.ts` 的 `mapInner` 大约 50 行是同一套 changeset 映射，差在点还是区间。`copyMappedUpto` 相似度 0.73。抽公共函数会把两种不变量揉在一起。

`toolbarButton`：`editor/code-block.ts:323` 与 `blocks/mermaid/index.ts:153`，相似度 0.94，各 11 行。差在 class 前缀（`editor-code-` / `mermaid-toolbar-`）和 dataset 名。两边的 `mousedown` 也是同一句（`code-block.ts:372`、`mermaid/index.ts:191`）。另有 6 行对齐在 `code-block.ts:410` 与 `mermaid/index.ts:221`。

列表高亮下标 `(index + step + count) % count`，方向键包一层 composing 判断：`react/SlashMenu.tsx:89`、`react/CodeLanguageMenu.tsx:92`、`react/MentionMenu.tsx:206`、`pod/chat/composer-completion.tsx:106`、`pod/comment-thread.tsx:478`。`SelectionToolbar.tsx:134` 已有 `composingKey`，这几处没有用。各菜单的 Enter / Escape 行为不同，不要合成一个 keymap。

防抖只有两处类内定时器：`editor/page-collaboration.ts:79`（30ms）和 `blocks/mermaid/preview.ts:40`（80ms）。不值得为这 6 行加依赖。

uikit 里 `Item` 与 `Badge`（相似度 0.91）、`SheetOverlay` 与 `DialogOverlay`（0.85）、`PopoverContent` 与 `HoverCardContent`（0.84）、`Separator` 与 `ButtonGroupSeparator`（0.80）是同一套浮层和条目原语的兄弟组件，保持分文件。

## 6. Agent Computer 和 ankole-browser

`package.json` 的运行时依赖是 `@agentbull/active-support`、`zod`、`pino`、`phoenix`、protobuf、OpenTelemetry。没有 `diff`、`yaml`、`cron`、`semver` 或 mime 库。YAML / TOML 已经走 `Bun.YAML` / `Bun.TOML`。

`ankole-browser` 的 `atomicJSON` 在 `src/browser/local-chromium.ts:290` 与 `src/browser/remote-cdp.ts:136` 逐字相同（11 行），`src/runner/bootstrap.ts:196` 是第三份。`browser-runtime/materializer.ts:279` 是更短的一份。`waitForExit` 在 `browser-runtime/daemon-supervisor.ts:140` 和 `ankole-browser/src/cli/run-command.ts:225` 逐字相同。

`cli/webhooks/webhook-cli.ts:155` 与 `cli/drive/drive-cli.ts:136` 的 `assertOnlyOptions` 是同一个循环，错误文案不同。应落到 `cli/primitives.ts`。

`worker/turn_execution.ts:67` 与 `worker/active_turns.ts:530` 的 `turnOperation` 都是 `{ id: signalID, producer: 'ankole-worker/turn' }`。后者多一个可选 `flags`。

`pod-cli.ts:551` 与 `:644` 把正整数解析写了两遍，都要求 `/^\d+$/`、`Number.isSafeInteger` 且大于 0。`cli/primitives.ts` 的 `positiveInteger` 接受 `Number()` 能解析的 `1e2`，不是原样替换。

对过函数体、合同不同、不能合并的：

- 路径段清洗。`cli/run-cli-bridges.ts` 的 `sanitizePathSegment` 上限 128、替换 `_`。`core/agent-home-paths.ts` 上限 96、默认 `-`，并折叠连续非法字符。
- 打码。`agent-runtime-manager.ts`、`web-fetch-adapter.ts` 的 `redactedErrorMessage`、`common/content-redaction.ts` 的 `redactText` 三套规则互不包含。
- 深合并。`thread-config.ts` 的 `mergeConfig` 每次返回新对象。active-support 的 `deepMerge` 会改第一个参数。
- 睡眠。`app-server-client.ts` 的 `delay` 会 `unref`。active-support 的 `sleep` 返回 `{ cancel, promise }`，取消时 reject，并且不 `unref`。
- 时长。`command-tool.ts` 的 `formatDuration` 把 1500ms 打成 `"1.5s"`。`seconds` 会先把数值乘 1000。
- UUID。`agent-home-config.ts` 是 `/^[0-9a-f-]{36}$/i`。`isUUID` 还检查连字符位置和 version / variant。
- 重试公式各自不同：daemon `min(5000, 250 * 2^n)`，recovery 上限 1000，传输层 `min(5000, 100 * 2^n)`，checkpoint `50 * 2^(attempt-1)`。
- 路径边界四套：`drive/drive.ts`、`lanes/file/relay.ts`、`lanes/file/path-security.ts`、`skills/effective-skill.ts`。`skills/knowledge-skills.ts` 的 `relative` + `startsWith('..')` 会拒绝名为 `..foo` 的路径，`pathIsWithin` 不会。
- 进程杀死。主人是 `core/execution/process-group.ts`（负 pid，默认 `SIGKILL`，只吞 `ESRCH`）。`worker/lambda-hooks.ts` 是单个正 pid 加 `SIGTERM`。
- 必填字符串在是否 trim、空字符串是否算缺失上不一致。
- 流式缓冲没有第二份 `readJSONLines`。`app-server-client.ts:537`、`socket-line-bridge.ts:75`、`commands.ts:256` 是三种传输。
- 图片字节的主人是 `common/image-bytes.ts`。`fabric/channel_transport.ts:933` 只接受 `ArrayBuffer` 或 `Uint8Array`，否则抛错。

`observability/` 没有新的可合并副本。

## 7. Kernel 其余手写算法

Myers 双向 diff 在 `app/kernel/src/page_document/diff.rs:270`，约 98 行，返回匹配坐标，不是通用 edit script。`Cargo.toml` 里没有 `similar`。不该为这一处加 crate。

`universal_ai_client/spec.rs:521` 约 150 行：`strip_json_code_fence`、`extract_balanced_json_object`、`repair_incomplete_json_object`、`remove_trailing_json_commas`。`sonic-rs` 和 `serde_json` 都不补全残缺 JSON，也不删尾逗号。

`common/`、`vfs/`、`object_store/`、`authz/` 没有第二份 path sanitize、hex、base64、retry、checksum 或 XML escape。path sanitize 只在 `vfs/path_codec.rs:53`。Base64 集中在 `common/encoding.rs`。重试走 OpenDAL `RetryLayer`。WebDAV XML 调用 `quick_xml::escape::escape`。

`FeishuOpenAPI.WS.Frame`（`libs/feishu_protocol/lib/feishu_openapi/ws/frame.ex`）自己实现 varint 和 length-delimited，约 170 行。控制面别处已经 `use Protox`。proto2 必填零值是否被现有用法覆盖，没有对过 schema。

编辑器 `core/state/bidi.ts` 约 479 行，是 UAX #9。包内没有 bidi 库。`@marijn/find-cluster-break` 只做字素边界。

## 8. 同形，但所有权不同

`agent_workers/worker_env/env_var.ex` 与 `site_env_var.ex` 的属性、身份和 `:put` 动作几乎逐字相同，差别是 `tenancy: :tenant` 对 `:site`，以及表名。`app_configure` 的 console 与 site operations、worker env 的 console 与 site operations、`definition.ex` 与 `pattern_definition.ex` 是同一类成对声明。合成宏会把 site 和 tenant 的所有权藏起来。

`ankole_web/browser_auth.ex` 与 `browser_setup.ex` 的 Ash Simple 资源声明同形，公开动作不同。

十几处 `Map.reject(fn {_, v} -> is_nil(v) end)` 已经是标准库写法，换成 `MapHelpers.compact_map/1` 删不掉算法。

## 9. 依赖已经够用时的替换

用仓库里已经有的，不加新库：

- `url::form_urlencoded::Serializer` 替换 kernel `encode_query`。
- `equal`、`isEmail`、`isUrl`、`isLength`、`isNumber`、`isRecord`、`uniq`、`safeJsonParse` 替换第 1 节点名的调用。
- `Phoenix.HTML.html_escape/1` 替换两处手写的 `& < > "`。
- `IMTransport.TokenCache`、`put_body/2`、`retry_after/1`、`filename_from_response/1`。
- 把 `checked_provider_object` 从 `web.rs` 提到 `standard.rs`，九个 resolver 改调用。
- `Ankole.Attrs.parse_datetime/1`、`SecretDigest.token/0`、`HumanUser.email_format/0`、`Ankole.Text.utf8_prefix/2`、`Session.safe_return_to/1`、`formatFileBytes`、`humanizeTechnicalLabel`。

不值得加库的：Myers diff、残缺 JSON 修复、UAX #9、`tools/computer/format.ts` 约 13 行的 ANSI 剥离（顺序有专门注释）、飞书 WS 手写 protobuf 帧。`lodash` 和 `date-fns` 盖不住这些域规则。相对时间和 1024 进制的文件大小继续用 `Intl` 和 `formatFileBytes`。
