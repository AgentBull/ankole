# Alma Harness 深度分析：榜单证据、实现细节与 Ankole 对照

> 分析日期：2026-11-11  
> 榜单快照：2026-11-11 15:51:54 +08:00  
> 本地应用：`/Applications/Alma.app`，版本 `0.4.567`  
> 榜单参评版本：`0.4.212`  
> 方法：参考 [REA](https://github.com/morluto/rea) 从应用包、JavaScript 运行层到原生二进制的逆向思路，静态阅读 Alma 本地 bundle、公开参评包中的目标文件、RTK 0.29.0 规则与 Alma 发布记录，并复算 FrontierHarness 公开数据。本文没有声称运行 REA 自动分析，也没有 Alma 的逐次模型请求轨迹。

## 0. 结论先行

**现有证据显示 Alma 处于过程榜第一梯队，但还不能支持「稳定、全面、跨模型 SOTA」的判断。** 用户提供的截图是一次过程榜快照；评测尚未结束时，不同 harness 的模型、任务和 attempt 覆盖并不均匀。总榜名次不能单独回答「为什么 Alma 更强」。

本报告先分析 Alma 本身，再列出它与 Ankole 的对应关系和可验证问题。辅助模型、自由脚本、激进输出预算等机制都按「实现—潜在收益—成本—适用条件」展开，不在分析阶段预设采纳或排除。

从代码看，与 harness 表现直接相关的机制主要有四组：

1. **改变模型面对的信息量。** `run_script` 把多次调用、循环、筛选和聚合放进脚本；RTK 再把常见命令的冗长输出变成面向任务的摘要。前者减少中间结果进入模型的次数，后者减少单次结果中的噪声。
2. **针对模型和协议差异做兼容。** 工具名与参数修复、文本工具调用中间件、按提供商设置 reasoning 和缓存选项、网络与空流重试，针对「模型会做任务，但没有按协议表达」这类失败。
3. **把长任务当作状态恢复问题。** 安全边界上的部分 compaction、真实 usage 校准、工具参数流中断续跑、缺失工具结果续跑、归档与读取，用于避免长任务因一次截断或一次协议错误丢掉全部进度。
4. **对执行结果做分层预算。** Alma 不是简单地把所有内容截到同一长度，而是组合命令语义过滤、单路输出窗口、结构化字段预算、最终序列化预算、后台输出窗口和归档。

第二轮阅读补充了第一轮没有展开的实现事实：

- PTC 的嵌套工具结果以 `rawToolResults=true` 返回，**完整结果会先进入脚本进程内存**；只有脚本选择的 `stdout` 回到模型。它让脚本可以基于未截断结果做精确聚合，同时把内存和大结果治理交给脚本。
- `run_script` 直接运行 Bun 脚本并提供 `sh()`；`allowNetwork: true` 在当前 executor 中没有形成隔离检查。这里实现的是**模型上下文隔离和工具调用身份隔离，不是额外的 OS 安全沙箱**。外层 Runta sandbox 与 Bun 进程边界是两个层次。
- RTK 不只是「缩短文本」：`rtk read` 可以删除普通注释，`curl` 的 JSON schema 化会丢弃实际值，`git log` 默认排除 merge。不同规则会改变 agent 能看到的事实集合。
- 辅助模型参与工具预选和不确定命令分析。它可能减少主模型的 schema 负担和选择干扰，也引入额外调用、缓存命中、超时和空结果路径；当前公开数据不能分解这些方向各自的贡献。
- 94% 左右的 cached input 比例不代表 token 总量低。Alma 在 GLM-5.3 上的平均输入和输出都明显高于 Codex、Pi，成本表现也不同。
- 新版若开启了 `promptCacheKey`，也不能据此解释 Baseten 参评请求。代码对 custom provider、Volcengine 和自建 OpenAI base URL 有条件分支，实际命中必须由提供商响应证明。

### Alma 机制与 Ankole 的对照入口

下表只定义可研究的问题，不代表优先级或采纳结论。

| Alma 机制 | Ankole 的对应现状 | 可以通过实验回答的问题 |
|---|---|---|
| PTC 的 3+ 调用、循环、聚合策略 | 已有隔离、可恢复的 `program`，描述已包含 loops、conditionals 和 intermediate processing | 更具体的使用策略是否改变自然调用率、通过率与实际 token；单调用是否保持直接执行 |
| Bun 自由脚本、`sh()` 和完整嵌套结果 | 隔离 JS，无 Node/network/filesystem/timers，有 memo/resume | 两类运行时分别能表达哪些任务；代码错误、内存、恢复、可重放性和实际完成率有何差异 |
| RTK 语义过滤与多级输出预算 | 普通命令 50K、read 100K，动态工具另有独立预算 | 语义投影与不同预算如何影响信息损失、重复读取、通过率和成本 |
| 辅助模型语义预选与 Tool Search | 本地确定性 client/server Tool Search | 辅助模型、本地检索和组合路由的命中率、空结果率、延迟、成本有何差异 |
| 工具 alias/coercion 与协议恢复 | 主要是 nudge/repair | 各模型实际产生哪些协议错误；自动修复改变了多少结果 |
| 真实 usage、部分 compaction 与 anti-thrash | 默认 90%，保留用户原文、pending clarify 和 Tool Search 合同 | 不同阈值和压缩边界如何影响摘要成本、信息丢失、重复读取与长任务完成 |
| 长任务原题验收与尽早写当前最佳草稿 | Background Agent Job 已有结果验证和证据要求 | 是否能减少探索后无交付物；如何区分草稿、猜测和已验证完成 |
| 长期记忆与 Herdr | 产品形态和状态所有权不同 | 在 fresh benchmark 中是否实际生效；哪些日常使用收益与 harness 成绩无关 |

---

## 1. 先划清证据边界

### 1.1 证据等级

本文使用四种标记：

- **A｜参评版直接证据**：从公开 `0.4.212` 包中读取的文件、二进制版本字符串，或不晚于参评版本的官方发布记录。
- **B｜本机新版实现**：从本机 `0.4.567` 的 `server.mjs`、Skill 和 RTK 二进制读取的实现。它解释「Alma 如何实现」，但不能自动解释 `0.4.212` 的成绩。
- **C｜榜单数据**：用户截图、FrontierHarness 公开 API 和官方设置。过程数据只描述快照。
- **D｜因果假设或建议**：由代码机制推导的候选解释，必须通过同模型、同任务、同配置的消融实验验证。

`server.mjs` 是压缩、混淆后的 bundle。本文保留 `O9e`、`Abn`、`COe` 等本版符号名，便于在本地文件中定位；这些名字不是稳定 API，也不应进入 Ankole 的命名。

### 1.2 版本不是细节，而是结论成立的前提

本机版本由 `/Applications/Alma.app/Contents/Info.plist:20` 和 `/Applications/Alma.app/Contents/Resources/alma-server/VERSION:1` 确认为 `0.4.567`。FrontierHarness API 的 harness 清单标记 Alma 为 `0.4.212`。

| 版本 | 已确认内容 | 能说明什么 | 不能说明什么 |
|---|---|---|---|
| `0.4.113` | 发布记录已有按真实 context usage 的 auto-compaction | 参评版之前已有这类能力 | 当前版 80% 阈值和全部恢复逻辑在旧版完全相同 |
| `0.4.165` | 发布记录已有 overflow archive 与 Read 读取归档 | 参评版之前已有输出归档思路 | 当前所有字段预算、归档上限和后台缓冲行为都相同 |
| `0.4.198` | 发布记录修复工具参数流中断恢复、OpenAI-compatible reasoning effort | 参评版已经包含这些修复 | 每个模型在榜单中都实际触发了这些路径 |
| `0.4.212` | 包内已有 PTC Skill；RTK 二进制报告 0.29.0，并能看到相同过滤规则字符串 | PTC 使用策略与 RTK 不是参评后才增加的概念 | 旧版每一条默认路由、输出阈值、缓存配置均已核实 |
| `0.4.506` | 才加入误调 deferred tool 后自动加载并重试的修复 | 当前版的易用性改进 | **不能算作 `0.4.212` 成绩原因** |
| `0.4.537` | 才修复普通命令输出过早裁切 | 当前版输出管线的相关修复 | **不能把当前完整输出行为直接套到参评版** |
| `0.4.567` | 本文详细阅读的本地实现 | 可以逐函数解释当前架构 | 不能把新功能倒推为榜单优势 |

旧版完整 ASAR 中的 `server.mjs` 多次分段读取超时，因此没有完成全量核对。本文不会把「旧版有 PTC Skill 和 RTK 二进制」扩大成「旧版所有默认执行路径与新版完全一致」。

### 1.3 本机重点阅读位置

| 主题 | 本机 `0.4.567` 位置 |
|---|---|
| RTK 查找与命令改写 `O9e` | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:5370` |
| 输出分类与 `Abn` | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:5383` |
| 工具参数修复 | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:5450` |
| 压缩摘要与确定性 fallback `TOe` | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:5704` |
| PTC 执行器与 session | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:5778` |
| `run_script` 入口、输出和 token 估算 | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:5829` |
| 后台进程 200K 尾部缓冲 | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:6234` |
| Bash 风险分析 `sSn` | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:6290` |
| Read 的 2000 行/51,200 字节窗口 | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:6302` |
| Tool Search 与工具路由 | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:6454` |
| 基础 active tool 集合 `Eqe` | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:10504` |
| 长任务提示 | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:11528` |
| 主生成循环与恢复 | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:11996` |
| 真实 usage、阈值、模型与缓存选项 | `/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs:11972` |
| PTC 模型可见使用策略 | `/Applications/Alma.app/Contents/Resources/alma-server/resources/bundled-skills/programmatic-tools/SKILL.md:12` |

---

## 2. 榜单能证明什么，不能证明什么

### 2.1 官方设置与复算口径

[FrontierHarness live API](https://frontierharness.org/api/live) 在本次快照中给出：

- 21 个 harness、5 个模型、62 个任务，每个组合计划 4 次，合计 **26,040** 次。
- 任务子集为 `tb21=45`、`tb4=17`；provider 为 Baseten，榜单设置声明 `effort=max`。
- sandbox 为 Runta；CPU 为 1–4 核，内存 2–8 GiB，存储 32 GiB。
- agent timeout 按任务为 900–28,800 秒，multiplier 为 1。
- 快照时 `complete=false`，`finished` 为 **10,254** 条，约为计划数量的 39.4%；另有 `running` 记录，不能当作已完成结果。

`effort=max` 是榜单的外部配置声明，不代表 Alma 内部所有主模型、辅助模型、摘要模型都统一使用最高档。Alma 代码有请求、thread、project 多层覆盖和独立辅助模型路径。

成本指标应写成：

```text
cost per pass = 全部已完成试跑成本之和 / 通过试跑数
              ≈ average cost per task / pass rate
```

用户截图满足 `$0.579 / 72.7% ≈ $0.796`。因此它不是只计算成功那次调用的费用，**失败和超时的成本也包含在分子中**。通过率和每次尝试成本会共同影响这个指标。

### 2.2 总榜快照：Alma 有竞争力，但不是 token 最少

以下数值由 API 的 `finished_fields` 解码后重新聚合，不直接照抄页面四舍五入值。`pass/fail/timeout` 都进入分母；成本按记录中的 `cost_usd` 求和。

| Harness | 完成数 | 通过数 | 通过率 | 平均成本/试跑 | 成本/通过 | 平均输入 token | 平均输出 token | cached/input |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Codex CLI | 381 | 299 | 78.5% | $0.358 | $0.456 | 1.576M | 23.6K | 92.8% |
| Pi | 432 | 314 | 72.7% | $0.302 | $0.415 | 0.628M | 26.7K | 88.2% |
| **Alma** | **273** | **196** | **71.8%** | **$0.583** | **$0.812** | **2.496M** | **47.3K** | **94.4%** |
| Claude Code | 466 | 325 | 69.7% | $0.588 | $0.842 | 2.423M | 55.2K | 93.0% |

Codex 有一条记录缺少成本，表中成本按已有记录求和，不对缺失记录补值；这不支持精细到小数点后三位的优劣判断。当前 Alma 的 cached/input 最高，但输入总量约为 Pi 的 4 倍，输出也明显更多。可见：

> **缓存命中率、输入 token 总量、模型推理次数、最终美元成本是四个不同指标。高缓存率可以和重复读取、长历史、过多推理同时存在。**

### 2.3 逐模型结果：Alma 的优势不均匀

下表的排名是在同一模型下，对 21 个 harness 按本次完成记录重算的过程排名；它不是最终榜。成本/通过用完整精度计算后再显示。

| 模型 | Alma 完成数 | 通过率 | 通过率排名 | 成本/通过 | 成本排名 | 平均输入 | 平均输出 | cached/input |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| GLM-5.3 | 49 | 65.3% | 7/21 | $1.680 | 20/21 | 3.311M | 80.9K | 95.1% |
| GLM-5.3-Flash | 41 | 68.3% | 6/21 | $0.249 | 14/21 | 3.122M | 64.7K | 89.2% |
| DeepSeek-V4.1-Flash-1017 | 44 | 75.0% | 8/21 | $0.163 | 6/21 | 3.434M | 59.0K | 97.3% |
| Muse Spark Open | 69 | 66.7% | 9/21 | $1.076 | 11/21 | 2.780M | 34.0K | 95.3% |
| **Kimi-K3** | **70** | **81.4%** | **2/21** | **$0.764** | **3/21** | **0.688M** | **19.3K** | **93.8%** |

Kimi-K3 上的直接对照为：

| Harness | 完成数 | 通过率 | 平均成本/试跑 | 成本/通过 | 平均输入 | 平均输出 |
|---|---:|---:|---:|---:|---:|---:|
| Codex CLI | 90 | 84.4% | $0.561 | $0.665 | 0.664M | 17.8K |
| Pi | 125 | 76.8% | $0.552 | $0.719 | 0.492M | 20.9K |
| **Alma** | **70** | **81.4%** | **$0.622** | **$0.764** | **0.688M** | **19.3K** |
| Claude Code | 109 | 76.1% | $0.796 | $1.046 | 0.828M | 26.7K |

GLM-5.3 上则是另一种情况：Alma 平均输入约 3.311M、输出约 80.9K；Codex 约 1.561M/19.7K，Pi 约 0.801M/34.9K。Alma 的成本/通过在 21 个 harness 中排第 20。

**这排除了「Alma 只是统一压缩得更狠，所以所有模型都省」的解释。** 更合理的研究问题是：哪些机制在 Kimi 上减少了无效循环，为什么同类机制在 GLM 上没有控制住历史增长和输出量。

### 2.4 配对比较：修正总榜覆盖偏差

为了降低不同任务进度造成的混杂，再按 `(task, model, attempt)` 连接 Alma 与对照 harness，只保留双方都有完成记录的试跑。下表的 `Δ通过率` 是百分点差，`Δ平均成本` 是 Alma 减去对手的平均每条试跑成本，不是成本/通过。

| 对照 | 配对数 | Alma 通过率 | 对照通过率 | Δ通过率 | Δ平均成本 |
|---|---:|---:|---:|---:|---:|
| Alma − Codex | 206 | 81.1% | 78.6% | +2.4 pp | +$0.095 |
| Alma − Pi | 208 | 76.9% | 74.0% | +2.9 pp | +$0.098 |
| Alma − Claude Code | 239 | 74.1% | 69.0% | +5.0 pp | −$0.100 |

进一步看关键模型子集：

| 对照与模型 | 配对数 | Alma | 对照 | Δ通过率 | Δ平均成本 |
|---|---:|---:|---:|---:|---:|
| Alma − Codex，Kimi-K3 | 57 | 86.0% | 87.7% | −1.8 pp | +$0.071 |
| Alma − Pi，Kimi-K3 | 67 | 83.6% | 80.6% | +3.0 pp | +$0.081 |
| Alma − Claude Code，Kimi-K3 | 63 | 82.5% | 79.4% | +3.2 pp | −$0.009 |
| Alma − Claude Code，Muse Spark Open | 57 | 71.9% | 61.4% | +10.5 pp | −$0.313 |
| Alma − Pi，DeepSeek-V4.1-Flash-1017 | 33 | 87.9% | 81.8% | +6.1 pp | +$0.023 |

这组结果有三个重要意义：

1. **总榜和配对子集可以讲出不同故事。** Alma 原始总通过率低于 Codex，但共同子集上略高；这说明当前任务覆盖选择的影响很大。
2. **不能把 Alma 的优势简单归为 Kimi 专属适配。** 在 Kimi 共同子集上，Alma 略低于 Codex；对 Claude Code 的最大配对差反而出现在 Muse Spark Open。
3. **通过率优势不自动等于成本优势。** Alma 对 Codex、Pi 的配对平均成本更高，对 Claude Code 才更低。

本次 Alma 在非 Kimi 的 203 条记录上为 139 次通过，即 68.5%；Kimi 是强结果之一，但不是统一解释。配对试跑仍共享相同任务，不能把 4 次 attempt 当作完全独立样本；当前也没有置信区间和逐次工具轨迹。以上数据只足以筛掉过度宣传，不能给出某个功能的因果增益。

---

## 3. 「为什么强」的候选因果链

| 候选机制 | 版本证据 | 可解释的改善路径 | 反例、成本与尚未证明之处 |
|---|---|---|---|
| PTC 的循环、筛选、聚合 | A：参评包已有 Skill；B：读完当前执行链 | 多次工具结果不直接进入模型，减少历史重复计费和无关上下文干扰 | 生成代码本身要 token；脚本错误要调试；大结果进入进程内存；没有参评轨迹证明自然使用率 |
| RTK 命令语义过滤 | A：参评包含 RTK 0.29.0；B：当前规则详细可读 | 单次测试、git、搜索、安装输出更短，减少噪声和后续 replay | 旧版自动改写路径未完整核实；规则可能丢弃关键细节；没有 ablation |
| 模型协议与参数修复 | A：发布记录有 reasoning 与参数流恢复；B：当前 alias/coercion 和中间件 | 减少工具名、参数类型、流中断造成的无效轮次 | 静默修复可能改变意图；各模型触发频率未知 |
| 输出分层预算与归档 | A：旧版已有归档；B：当前字段预算和恢复路径 | 保留开头、结尾和可恢复引用，避免单次大输出占满上下文 | 截断会丢信息；后台早段不可恢复；归档有大小上限；不是「永远完整」 |
| 真实 usage 驱动的 compaction | A：旧版已有此能力；B：当前部分压缩和 anti-thrash | 延迟信息丢失，同时防止 context overflow 后任务终止 | 摘要本身有损且收费；缺摘要模型时会跳过；当前 80% 阈值不能倒推到参评版 |
| 自动续跑与分类重试 | A：参评前已有参数流恢复修复；B：当前完整分类 | 把瞬时错误与真正失败分开，避免整个任务报废 | 重试增加 token 和墙钟；过多 continuation 可能延续错误方向 |
| 缓存边界与稳定会话标识 | B：当前代码明确；C：cached/input 很高 | 稳定前缀与最近边界可复用提供商缓存 | Baseten 请求是否带 key、如何计费未核实；高缓存率没有阻止 GLM 高 token 总量 |
| 工具预选与 Tool Search | B：当前辅助模型语义选择 | 减少工具 schema 占用的上下文和选择干扰 | 增加辅助模型依赖；失败可返回空集合；参评目录规模与默认路径未知 |
| 长任务提示、子 agent 收尾 | B：当前提示和 100 step 收尾 | 提醒按原题验收，避免无限工具调用和无最终答案 | 提示存在不等于模型遵守；参评版完整提示未核实 |
| 长期记忆、Herdr | 产品材料中的能力 | 跨会话工作流可能改善日常使用 | 没有证据表明它们在该 fresh benchmark 中生效，更不是当前 harness 对比的必要解释 |

最可信的总解释不是某一个「神奇功能」，而是：

> **PTC 和语义输出控制减少无效上下文，协议修复与恢复减少无效失败，长任务管理避免最后丢结果。不同模型对这些机制的受益和副作用不同，所以结果强烈依赖模型与任务。**

这是按代码合理性排序的因果候选，不是已完成的消融结论。

---

## 4. Alma 的实际工具输出管线

### 4.1 不是一次截断，而是多级处理

本机 `0.4.567` 的 Bash 路径可以概括为：

```text
模型提出 Bash 命令
  │
  ├─ sSn：本地规则分析；不确定时可用辅助模型分析风险
  │
  ├─ O9e：仅限本地、无 shell 元字符、白名单中的简单命令
  │        改写为 RTK 命令；远程工作区不改写
  │
  ├─ 执行：前台 / 自动转后台 / 显式 timeout
  │
  ├─ ape：每路输出先保留 30K 字符，头部 30% + 尾部 70%
  │
  ├─ 若为 RTK 改写命令：Abn 只做 secret redaction
  │  否则：按工具与字段继续做通用输出压缩
  │
  └─ 返回模型：结构化结果 + complete/truncated 标记 + 可选归档引用
```

关键细节是：**RTK 已经处理过的 Bash 输出不会再走同一层通用窗口压缩。** 这避免 RTK 摘要把失败原因压缩出来后，通用逻辑又把摘要的头尾切掉。但 secret redaction 仍会执行。

### 4.2 命令风险分析并不等于执行前零成本

`sSn` 先做本地规则分析。规则无法确定时调用 `fi()` 选择的辅助模型，分析超时约 10 秒；没有可用辅助模型或 provider 不可用时，返回需要权限，而不是默认为安全。

这条路径说明 Alma 把「权限判断」和「输出压缩」分开了。即使操作最终自动批准，不确定命令也可能先付出一次辅助模型调用的延迟和成本。评测是否配置了这个辅助模型、多少命令走到该分支，没有轨迹可证。

### 4.3 前台、后台和超时不是同一个机制

| 路径 | 当前实现 | 对 agent 行为的影响 |
|---|---|---|
| 默认前台 | 默认 120 秒；60 秒仍未结束可自动转后台 | 让模型继续处理其他事，但也要求正确读取后台状态 |
| 显式 `timeout` | 最大 600 秒；不走上述自动转后台，并禁用 90 秒无输出 stall guard | 长命令语义与默认路径不同，不能只看一个统一 timeout |
| 后台 stdout/stderr | 每路仅保留最后 200K，再应用可选 regex 和输出窗口 | **200K 之前的早段会丢失**，不能声称完整归档 |
| 流式输出窗口 | 每路 30K 字符，头 30% + 尾 70%，并维护 complete 标志 | 同时保留初始配置和末尾错误，但中段可能消失 |
| 工具 watchdog | 当前生成循环中的工具超时为 600 秒 | 与 Bash 自动转后台不是同一个计时器 |

这些计时器产生了四类可分别观测的状态：「进程仍在运行」「输出被截断」「输出已读完」「模型是否继续轮询」。它们也可以作为 Ankole 对照实验的记录维度；若混成一个 success 字符串，就无法区分执行失败与输出治理造成的行为差异。

### 4.4 通用输出预算按工具和字段区分

当前代码中的典型预算如下。单位是字符，不是 provider token；实际比例会随语言、JSON escaping 和字段结构变化。

| 工具/字段 | 典型预算 | 备注 |
|---|---:|---|
| Bash 整体序列化 | 24K | stdout、stderr 还各有字段限制 |
| Bash stdout | 12K | RTK 改写结果跳过这一通用层 |
| Bash stderr | 6K | 错误通道有独立预算 |
| `run_script` 整体 | 24K | 此前还有脚本进程 256K 硬上限 |
| `run_script` stdout | 16K | 工具描述约称 16K |
| `run_script` stderr | 2K | 必要诊断需要进入最终输出，否则可能受这个小预算影响 |
| WebFetch | 25K | 页面读取与命令输出分开 |
| WebSearch | 3.4K | 搜索结果更强调条数和摘要 |
| Grep | 5K | 与 RTK grep 自己的 50 条限制是不同层 |
| Glob | 9K | 文件列表独立预算 |
| 名称含 `__` 的 MCP | 通常 2.6K | 工具命名影响输出策略，不同 MCP 可能走不同分支 |

普通 `Read` 是 **2000 行或 51,200 字节先到为止**，不返回半行；超长单行会提示使用 byte range 或结构化提取。它与 Bash、WebFetch、PTC 的预算不同，对应「模型主动读取文件」和「命令产生日志」两种使用方式。

### 4.5 截断、归档与完整读取对应不同数据层

Alma 有归档机制，但存在以下边界：

- 普通字段可能先被窗口化，再保存某个阶段的原始内容；归档不必然恢复所有更早阶段已经丢掉的字节。
- 后台进程只保留最后 200K，早段不能被后续归档恢复。
- RTK tee 默认偏向失败时保存原始输出，最多 20 个文件、每个 1 MiB；不是所有命令的永久全量日志。
- compaction archive 的上限为单 archive 32 MiB、单值 2 MiB、总量 2 GiB，截断会带显式标记。

因此，准确表述是「**在特定阶段和大小限制内保存可恢复原文**」，不是「模型看到的是摘要，但完整内容永远可读」。

---

## 5. RTK：第一轮漏掉的语义输出层

### 5.1 它是什么

本地 RTK 是 [rtk-ai/rtk](https://github.com/rtk-ai/rtk) 的 0.29.0 二进制，对应源码标签 [v0.29.0](https://github.com/rtk-ai/rtk/tree/v0.29.0)。它把自身描述为在系统输出进入 LLM 上下文前进行过滤和总结的 CLI proxy。

参评 `0.4.212` 包内也有 RTK，并明确包含 0.29.0 与相关规则字符串。这个证据比「新版突然加入一个工具」更强；不过旧版 `O9e` 自动改写的全部条件仍未逐行核实。

Alma 的自动改写只针对本地、简单、白名单命令，包括 `git/npm/pnpm/yarn/bun/cargo/grep/rg/find/fd/ls/tree/cat/tsc/eslint/vitest/jest/pytest/curl/wget/docker/pip` 等。包含 shell 元字符的复合命令不走这条自动路径。

### 5.2 规则的作用与信息变化

| 命令 | RTK 0.29.0 的具体行为 | 可能的作用路径 | 信息变化与反例 |
|---|---|---|---|
| `rtk read` | 默认 minimal：删普通注释、压缩空行；保留 Python docstring、Rust doc comment；JSON/YAML 等数据文件不剥注释 | 减少样板和空白，保留 API 文档 | 普通注释可能解释算法、限制或 bug；精确源码阅读需要另一种读取路径 |
| `rtk grep` | 每行默认 80 字符，最多 50 条，每文件最多 10 条；按文件分组并显示 `+N` 遗漏 | 防止一个生成文件或高频模式淹没结果 | 第 51 条可能才是关键；80 字符可能截掉错误上下文 |
| `pytest` | 强制 `--tb=short` 和 quiet；最多 5 个失败，每个最多 3 条关键行；保留退出码 | 失败摘要通常足够决定下一次定位 | 第 6 个失败、完整 traceback、warning 可能揭示共同根因 |
| `vitest` | 强制非 watch 和 JSON reporter；JSON → regex → passthrough 分级降级 | 避免 watch 挂住，优先结构化解析 | 降级路径决定解析失败时模型看到什么，退出码仍需单独保留 |
| `git log` | 默认 10 条、`--no-merges` | 压缩例行历史浏览 | merge commit 可能正是冲突或回归来源 |
| `git diff` | stat + 压缩 diff；单 hunk 30 行、总 500 行 | 先看变更结构再决定细读 | 大 diff 的上下文可能不足；精确代码审查需要原文件或完整 diff |
| 部分 `git show` | 特定格式和 blob show 直接 passthrough | 保留精确对象内容的读取出口 | 与普通日志摘要形成不同的数据路径 |
| `curl` | 加 `-s`；JSON 更短时转成 schema，**实际值被丢弃** | 探索超大 API 响应结构 | 需要真实值、错误正文或验收数据时，schema 不能回答原问题 |
| `npm` 等安装命令 | 去 lifecycle、WARN、progress；空结果显示成功摘要；保留退出码 | 减少进度条与重复 warning | warning 可能解释后续运行时失败，需要结合原始输出出口分析 |

这些规则表明，Alma 的语义压缩同时由「数据类型和下一步决策」驱动，而不只是由「文本太长」驱动。

测试 runner 关心失败数、失败测试名、断言差异、堆栈位置和退出码；精确读取源码关心指定行与注释；API 调试关心实际 body。把三者统一成「头 30% + 尾 70%」会丢失不同位置、不同类型的信息。

### 5.3 退出码与解析降级路径

RTK 的测试和安装规则保留进程退出码，使输出长度变化不直接改变成功/失败语义。

Vitest 的 JSON → regex → passthrough 则形成三级解析路径：结构化解析失败时退回较弱的解析或原文，而不是生成一个空摘要。在 Ankole 对照实验中，可以把 `projection_status=parsed|degraded|passthrough` 和解析器错误作为观测字段，区分投影节省与解析失败造成的影响。

### 5.4 RTK 的节省数字不是美元账单

RTK 与 Alma PTC 都使用大约 `ceil(byte_len / 4)` 的 token 估算。这个估算：

- 不是模型 provider 的 tokenizer；
- 对中文、代码、JSON 和多字节字符会有偏差；
- 不包含后续每轮历史 replay 的全部影响；
- 不扣除生成脚本、修复脚本和辅助模型的成本；
- 不构成「直接调用工具」的反事实对照。

因此，不能用 RTK 自报的 `savedTokens` 直接推算 `$0.796` 的成本/通过，也不能把它当作 PTC 的通过率消融实验。

---

## 6. PTC：脚本策略、完整中间结果与执行边界

### 6.1 参评版已经明确告诉模型何时使用

本地 [`programmatic-tools/SKILL.md`](/Applications/Alma.app/Contents/Resources/alma-server/resources/bundled-skills/programmatic-tools/SKILL.md) 与参评包中读取到的文件一致。关键策略不是「有一个脚本工具」，而是：

- **3+ 工具调用、循环、筛选/聚合大结果、依赖或条件链**时优先 `run_script`。
- 在代码里循环和过滤，`console.log` **只输出最终结果**。
- **单工具调用不要包脚本**：没有聚合收益，还会降低 UI 可观察性。
- `Task` 和 `AttemptCompletion` 必须直接调用，保持独立进度和完成语义可观察。

这套策略同时规定了正向使用场景和反向边界。它可能改变模型的自然工具选择，而不是只在模型已经决定写脚本后提供执行能力。

### 6.2 当前实现的真实数据流

当前 `run_script` 默认启用，脚本可以使用：

- `almaTool(name, args)` 调用允许的工具；
- `listTools()` 读取工具名、描述和 input schema；
- `sh(cmd)` 执行 shell；
- `alma(subcmd)` 调用 Alma CLI。

执行流程为：

1. 外层 `run_script` 先请求批准；代码预览自身有 4000 字符限制。
2. Alma 为这次执行创建独立 PTC session/token，并过滤掉 `run_script`、`ToolSearch`、widget、`Task`、`AttemptCompletion` 等不允许嵌套的工具。
3. Alma 生成带辅助函数的临时 JS/TS 文件，直接以 `bun run` 执行。默认 120 秒，参数允许最大 600 秒。
4. `/api/tools/invoke` 执行嵌套工具。`rawToolResults=true` 表示结果只经过 secret redaction，不经过 Alma 的通用输出截断。
5. 完整结果进入脚本进程；脚本在内存中循环、筛选和聚合。
6. 回到模型的主体是脚本选择的 `stdout`、执行状态和嵌套调用元数据，而不是每个完整结果。
7. stdout/stderr 先在代码里硬截到 256K，再进入通用 `run_script` 输出安全层，典型为整体 24K、stdout 16K、stderr 2K。

嵌套调用仍会产生元数据：参数预览约 600 字符、`resultPreview` 约 1200 字符、耗时、错误和估算 token。故「中间结果完全不进入模型」也不准确；准确说法是「**完整中间结果不直接进入模型，有限的调用元数据和最终输出会进入**」。

`listTools()` 的结果也留在脚本进程内。模型可以让脚本先按名称找到工具，再只输出相关 schema，而不必把整个工具目录放进主模型上下文。它与 Tool Search 的关系不是简单的替代：Alma 禁止在 PTC 内调用 Tool Search，但允许脚本读取已有工具目录。

### 6.3 `rawToolResults=true` 同时改善表达能力和增加资源责任

这条路径避免了宿主先把结果截小，导致脚本无法做准确聚合。例如，脚本需要扫描 100 个文件并找出 3 个匹配项时，可以在每个完整结果上执行同一套过滤逻辑，再把 3 个匹配项返回模型。

它提供的不只是 token 节省，还包括：

- **过滤正确性**：脚本可以看到宿主通用预算可能会截掉的字段。
- **跨结果计算**：可以合并、去重、排序、求差集，或在前一结果满足条件时提前停止。
- **复用完整结构**：不必把结构化结果先变成适合模型阅读的文本，再由模型重建对象。

相应的资源责任也留在脚本侧：

- 一个巨大工具结果可以完整进入 Bun 进程内存；
- 循环里累积所有结果可能造成高内存或 OOM；
- 脚本若直接 `console.log` 所有结果，就失去了 PTC 的上下文价值；
- 256K 硬上限与最终 24K 预算仍会丢掉未筛选的输出。

因此，这条数据流可以准确描述为「**完整中间结果由脚本持有，模型只拥有有限元数据和脚本选择的输出**」。它既不是宿主预截断，也不是无限数据免费处理。

### 6.4 Bun、`sh()` 与隔离边界分别提供什么

当前 executor 接收 `allowNetwork: true`，但相关执行路径没有据此建立网络或文件系统隔离；脚本还能调用 `sh()`。独立 session/token 管理的是 Alma 工具调用身份，不是额外的 OS 级进程隔离。

自由脚本层提供了几类普通工具编排不一定具备的能力：

- 直接组合 `rg`、`jq`、Python、构建工具等本机程序，而不必为每个操作定义新的模型工具；
- 用 shell pipeline、临时文件和现有 CLI 处理批量数据；
- 使用 Bun/Node 生态中的解析器和网络能力；
- 在同一个脚本中混合本地计算与 `almaTool` 的领域操作。

这些能力可能减少「工具合同本身无法表达任务」造成的失败，也可能减少为主模型新增工具 schema 的数量。另一方面，脚本生成错误、依赖差异、进程资源消耗和恢复语义都会进入执行结果。

需要区分两层边界：FrontierHarness 声明使用 Runta sandbox，Alma 的 Bun executor 没有再建立一层等价的 OS 隔离。**外层任务沙箱是否已满足评测的运行需求，与 Bun 是否自称沙箱，是两个问题。** 本次没有 runner 的完整权限配置，不能从静态 bundle 推出实际进程拥有哪些外部访问能力。

Ankole 当前 `program` 的描述明确禁止 Node、network、filesystem 和 timers，见 `app/control_plane/lib/ankole/ai_gateway/programmatic_tool_calling.ex:173`；还有 fingerprint、memo/resume 和最多 256 个 nested calls 的合同。两种实现可以按以下维度对照，而不是只按「自由」或「安全」排序：

| 维度 | Alma `run_script` | Ankole `program` | 对任务结果的待测影响 |
|---|---|---|---|
| 本地程序与 shell | 直接提供 `sh()` | 不暴露通用 shell | 哪些任务需要现有 CLI；替代路径增加多少轮次 |
| 中间结果 | 完整结果进入 Bun 进程 | 由现有 PTC runtime 和工具合同处理 | 聚合正确性、峰值内存和最终输出量 |
| 恢复 | 当次进程、session 与输出元数据 | fingerprint、memo/resume | 中断后的重复副作用、恢复时间和成本 |
| 可重放性 | 可执行任意本地代码，确定性取决于脚本与环境 | runtime 明确限制多类环境能力 | 同一程序重放的差异和调试难度 |
| 资源边界 | 120 秒默认、600 秒上限、输出硬 cap；无额外 OS 隔离证据 | 有 nested calls 上限和隔离 runtime | OOM、超时、无法表达的操作和完成率 |
| 可观察性 | 外层脚本和 nested 元数据；Task 等必须直接调用 | 公共 program item 与 nested 合同 | 错误定位、人工介入与审计需要的信息 |

### 6.5 PTC 为什么可能同时改善通过率和成本

合理的路径包括：

- 多次结果只 replay 一次最终摘要，而不是每次请求都带上所有原始结果；
- 模型不用逐一阅读无关结果，降低选错下一步的概率；
- 循环与条件分支由确定性代码处理，减少重复工具名和 JSON 参数生成；
- 提前退出避免不需要的后续调用；
- 嵌套工具结果无需逐条转成模型消息，减少消息结构和上下文膨胀；
- 自由脚本可以直接完成未被工具 schema 覆盖的转换或系统操作。

净收益需要同时计入脚本生成、错误修复、额外 stdout、权限等待和内存成本。Alma 的 `savedTokens=max(0, estimatedNestedResultTokens−estimatedStdoutTokens)` 没有完成这笔总账。

---

## 7. 工具路由与辅助模型

### 7.1 辅助模型选择

当前 `fi()` 优先使用显式 `toolModel.model`；否则从已配置的 OpenAI、Anthropic、Google 等 provider 的小模型候选中选择，例如 GPT-4o mini、Claude Haiku、Gemini Flash。没有合适模型时返回 `null`。`z4()` 先使用 `memory.toolModel`，再回退到 `fi()`。

这意味着「有一个便宜小模型」不是无条件成立。在只有第三方 OpenAI-compatible endpoint 的配置中，工具路由与命令分析可能没有辅助模型可用。参评环境实际配置了哪些 provider、辅助模型是否可用，公开 API 没有给出。

### 7.2 工具预选与 Tool Search 是语义模型调用

`GGt`/`OKn` 的预选超时约 25 秒，外层并行分析约 30 秒。失败可能返回空 tools/skills，而不是本地确定性搜索结果。Tool Search 也使用同一类辅助模型，目录 hash 结果缓存约 30 分钟；`rRn` 默认最多返回约 20 个工具。

当前 `Eqe` 的基础 active set 包含 Tool Search、AskUserQuestion 和 widget 工具；PTC 开启时再加 `run_script`、`Task`、`TaskOutput`。之后按预选、历史选择和 Tool Search 结果累积扩展。`Bash` 会带出 `BashOutput`、`KillShell`，`Task` 会带出 `TaskOutput`。

目录大于 40 且 activeTools 缺失时有最小集合回退。`0.4.506` 才加入误调 deferred tool 后自动加载并提示重试，不能把这个修复算作 `0.4.212` 的优势。

### 7.3 辅助模型可能改变主模型的哪些行为

**第一条路径是减少主模型的 schema 负担。** 预选只把与当前任务相关的工具描述放入主上下文，可能减少每轮输入，也可能降低名称和参数相近的工具之间的误选。这个收益与目录规模正相关；目录只有几个基础工具时，辅助调用的作用空间较小。

**第二条路径是利用语义判断而不是字面匹配。** 用户说「检查这段改动为什么破坏构建」时，辅助模型可以把测试、git diff、文件读取和终端诊断组合起来，即使请求中没有出现工具名。它还可以根据当前任务上下文选择 Skill，而不只匹配关键词。

**第三条路径是改变主模型的决策序列。** 工具被预选后，主模型看到的选项更少；`activeTools` 又根据历史选择累积扩展。它既可能减少无关选择，也可能因早期遗漏而需要 Tool Search 补载。辅助模型的价值因此不仅是一次检索命中率，还包括后续是否少走了弯路。

**第四条路径是把部分成本移出主模型。** 如果辅助模型更小、更便宜，语义路由可能用较低成本换取主模型输入下降。目录 hash 的 30 分钟缓存和并行预选可摊薄部分延迟与费用。公开榜单只标记主模型，无法从当前记录分解辅助模型 token、缓存与价格；若辅助模型与主模型不同，还需要核对 harness 如何把这些调用计入成本。

### 7.4 失败模式与对照实验所需数据

辅助模型路径也有可观察的失败分支：

- 没有合适 provider 时 `fi()` 返回 `null`；
- 预选超时或失败可返回空 tools/skills；
- 语义误判可能漏掉真正需要的工具；
- 目录 hash 缓存提高复用，也使目录内容或描述的版本归属变得重要；
- Bash 不确定命令分析会增加一次最长约 10 秒的辅助调用，没有模型时转为要求权限；
- 主模型上下文的减少与辅助调用的新增可能方向相反。

因此，一个完整对照至少包含「不使用预选」「本地确定性检索」「辅助模型语义检索」「本地候选 + 辅助模型重排」四种路由，并记录首轮工具命中率、补载率、空结果率、主模型输入、辅助模型输入/输出、缓存命中、路由延迟和最终任务结果。

Ankole 的 `app/control_plane/lib/ankole/ai_gateway/tool_search.ex:1` 已明确实现 client/server 两种 Tool Search，由本地索引和合同选择工具；deferred tools 加载后再加入 PTC bindings。它提供了与 Alma 不同的现成对照组：在相同目录和请求下，本地实现的结果是确定的，也不会产生额外 LLM 路由调用；Alma 的语义路径则可能对隐含意图和同义描述更敏感。两种方式或组合方式的实际差异需要任务轨迹区分。

---

## 8. 模型协议、reasoning 与缓存细节

### 8.1 reasoning 不是统一最高档

当前默认选择函数 `oTr` 的默认档位为 medium；请求、thread、project 可覆盖，并按模型支持的 levels 就近匹配。榜单声明的 `effort=max` 是外部设置，实际 adapter 如何传给 Alma 需要请求轨迹确认。

OpenRouter 分支的 reasoning `max_tokens` 映射为：

| 档位 | 预算 |
|---|---:|
| low | 4,096 |
| medium | 16,384 |
| high | 32,768 |
| xhigh | 131,072 |
| max | 196,608 |
| ultra | 262,144 |

OpenAI 分支传 reasoning effort；Google、Anthropic、DeepSeek 各有自己的映射。该数值是预算，不是实际消耗，更不是「统一最高档」的证据。

不支持原生 function calling 的模型可走文本工具调用 middleware。`AttemptCompletion` 的特殊逻辑只针对 Gemini 文本模型；本轮五个模型没有 Gemini，**不能用它解释本次成绩**。

### 8.2 工具名与参数修复

当前 `sde` 一类路径会修复常见工具调用偏差，例如：

- `readfile/openfile/cat` → `Read`；
- `cmd` → `command`；
- `path/file/filename` → `file_path`；
- 对数字、布尔、数组和对象做类型 coercion；
- 为 WebFetch 补默认 prompt。

这种修复可能挽救本来会浪费一轮的调用，尤其是跨模型使用同一工具集时。宽松转换也可能把本来应报错的不明确参数变成另一个有效动作。评估时需要同时记录原始调用、映射规则、修复后的参数和最终任务结果，才能区分协议容错与语义误判。

### 8.3 缓存不是一个全局开关

当前实现包含多种机制：

- OpenAI provider options 中按条件设置 `promptCacheKey=e`，并维持稳定的 `x-session-id`。
- 代码明确排除 custom、Volcengine、自建 OpenAI base URL 等部分路径；OpenAI SDK/plugin 分支也有条件判断。不能把官方 OpenAI 的行为直接套到 Baseten。
- `Hqe` 给前两个 system 和最后两个非 system 消息设置 ephemeral cache control，覆盖 Anthropic、OpenRouter、Bedrock、OpenAI-compatible、Copilot 等分支。
- `XXo` 在 Anthropic/Bedrock 上按 `SYSTEM INFO` 拆分静态 persona 与动态内容；其他 provider 可使用单 system。
- `ZXo` 清掉旧消息上的 cache options，只让最近边界参与缓存。
- `lD` 清理 `store=false` 时不应历史重放的 provider options，避免旧消息中的选项污染后续请求。

这些代码说明 Alma 在认真管理缓存前缀与边界，但**只有实际 provider usage 能证明命中和计费**。cached/input 很高也可能只是同样的超长历史被反复读取，不能替代总输入和输出分析。

Ankole 已有自然 cache key 与 `prompt_cache_key` 输入，见 `app/control_plane/lib/ankole/ai_gateway/request_context.ex:114`。Alma 的差异主要在 provider 分支、消息边界和静态/动态 system 组织方式，是否迁移这些分支可以由实际 cache 响应判断。

---

## 9. Compaction、归档与失败恢复

### 9.1 当前版如何触发压缩

当前默认值为：

- threshold：80%；
- `keepRecentMessages`：4；
- 输出预留：32K；
- `RB` 的目标约为 context window 的 60% 减固定 overhead，最低约 15%。

触发估计同时使用：

1. 最近 assistant 消息中的真实 `inputTokens/outputTokens/cachedInputTokens`；
2. 自该消息之后追加的工具结果和消息；
3. 本地启发式 token 估算；
4. 根据真实 usage 反推的 wire/estimate ratio。

真实 usage 包含了 provider 协议、工具 schema 和推理相关开销，本地字符估算则用于补齐最新追加部分。wire/estimate ratio 把两者校准起来，减少「本地看还有空间，provider 已经 overflow」的偏差。

**80% 是当前版默认值，不是已核实的参评版默认值。** Ankole 当前默认 90% 和最多 400K trigger，见 `app/control_plane/lib/ankole/ai_gateway/compaction_policy.ex:18`。这两个数字代表不同的行为点：

- 较早触发会更早支付摘要成本，也可能在任务仍需要原文时引入摘要损失；同时为下一次长工具结果和输出留下更多空间。
- 较晚触发保留更久的逐字历史，减少压缩次数；但单轮请求更长，发生 overflow 时可用的恢复空间更小。
- Alma 压缩目标不是刚好低于 80%，而是进一步降到约 60% 减 overhead。一次压缩会改变后续多少轮可以保留原文，也会影响重新读取已摘要内容的概率。

因此，阈值本身需要和压缩后目标、摘要质量、工具结果大小、cached token 单价以及重新读取行为一起分析。

### 9.2 部分压缩保留工具协议边界

`COe` 不只支持「删除前 N 条」。它会寻找已完成的 tool/step 边界，把较早部分生成摘要，保留最近用户目标和最近 4 条消息。若最新交换本身就超过窗口，才折叠整段。

活跃 turn 的 live-only compaction 会在 turn 末以 tool call 为锚点持久化，避免 active path 上存在没有结果的调用。这里有两个不同目标：减少历史 token，以及保持工具调用和结果的可解释性。只实现第一点而破坏第二点，可能把上下文溢出转化成协议错误。

Ankole 已选择安全 compaction 边界，并通过 `app/control_plane/lib/ankole/ai_gateway/compaction_retention.ex:46` 保留 pending clarify pair，通过同文件 `:82` 保留已加载 Tool Search 合同。Alma 的部分压缩与这些保留规则对应不同的上下文契约；两者可以在同一实验框架中比较，而不需要假设实现路径相同。

### 9.3 摘要、fallback 与 anti-thrash

当前 Alma 使用结构化九节摘要，可合并前次摘要；摘要输出被截断时会缩小 transcript 重试。其他关键路径为：

- 压缩后没有 token 减少，不持久化这次「无效压缩」，使用确定性 `TOe`；
- 摘要失败也有确定性 fallback；
- 没有可用 summary model 时可以跳过 AI compaction；
- 压缩后真实 usage 仍高于阈值会进入 suspended；直到估计使用量低于阈值再低 10 个百分点才恢复，避免每轮都重复摘要；
- archive 中的大对象有显式截断和上限。

`verify → suspended → 低于 threshold−10 后恢复`说明 Alma 把「稳定状态本身就超过阈值」与「临时超出阈值」分开。没有这一区分时，即使每次摘要只能带来很小改善，也可能在每轮重复支付摘要成本并持续丢失信息。

Ankole 的摘要器使用 `light` profile，输出 8K、特定失败重试 16K，见 `app/control_plane/lib/ankole/ai_gateway/compaction_summarizer.ex:13`。可比较的变量包括摘要模型、输出上限、失败后的确定性路径、是否持久化无效压缩，以及是否存在 anti-thrash 状态；这些变量不必绑定成同一个实验。

### 9.4 主循环把多种「没完成」分开处理

当前实现中的主要恢复策略为：

| 情况 | 当前行为 |
|---|---|
| 工具结果缺失、`length` 截断、工具参数流中断、非 stop 但有工具调用 | 自动 continuation，最多约 10 次，并附恢复提醒 |
| 空 stream | 独立重试最多 3 次，间隔约 500ms |
| 可重试网络错误 | 最多 3 次，指数退避封顶 60 秒，并尊重 `Retry-After` |
| token/context limit | 先尝试 compaction，再重试 |
| 主循环 | 约 100 step |
| generation watchdog | 约 4 小时 |
| stream idle | 默认约 60 秒 |
| 工具执行 watchdog | 约 600 秒 |
| 子 agent 到最后 step | 强制 `toolChoice:"none"`；没有最终文本时返回 incomplete 解释，不伪装成功 |

这些分类把「协议还没完成」「暂时网络失败」「上下文需要整理」「任务实际失败」分开。它们对成本的方向不同：恢复一次可能挽救已经投入的整段历史，重复延续错误方向则会增加额外消耗。因此，恢复率、恢复后的通过率与恢复成本比单独的重试次数更有解释力。

参评版 `0.4.198` 已明确有工具参数流恢复修复；其他当前阈值仍需新版证据限定。

### 9.5 PTC、RTK、缓存与 compaction 可能形成组合效应

这些机制不应只按独立 token 数字相加：

- PTC 减少进入消息历史的 nested tool result，既减少上下文占用，也减少工具消息插入造成的后续前缀变化。
- RTK 缩短单次结果，使触发 compaction 的时间可能后移；语义摘要也可能减少后续重新读取同一输出的需要。
- 更少、更短且更稳定的历史有利于缓存前缀复用，但缓存命中仍取决于 provider 和请求组织。
- compaction 又可能摘要掉 RTK/PTC 的输出引用；archive 的可读性和保留期限决定模型能否找回细节。
- 恢复路径把单次异常从整个任务失败中分离，可能保留此前已经付出的上下文与工具执行成本。

这组相互作用是一个待验证的系统性解释，比单独比较某一个阈值更接近 Alma 的实际架构。

---

## 10. 长任务提示与子 agent 收尾

当前提示中有两类针对长任务的策略：

- **按原始任务标准验收**：提示模型不要根据已经做过的工作自行降低完成标准。
- **尽早写出当前最佳答案/产物，再持续改进**：减少大量时间花在探索上、最后没有任何交付物的情况。

第二类策略与验证约束共同出现才有完整语义。当前最佳草稿不是已验证结果，猜测也不是完成声明。子 agent 最后强制停止工具调用并生成最终说明；无最终文本时返回 incomplete，而不是把工具历史当成任务成功。

Ankole 已有基本验收要求：

- `app/control_plane/priv/sessions/prompts/completion_contract.eex:3` 区分只读请求和修改请求，并要求如实说明未验证部分；
- `app/agent_computer/src/core/codex-runner/job/runtime-files.ts:48` 要求按任务交付物验收，并把证据、路径和风险写入结果。

可对照的具体行为是「保存原始验收标准、尽早写当前最佳草稿、最后逐项核验」，并分别测量最终产物存在率、外部验收通过率和未完成声明的准确性。

---

## 11. Ankole 现状与待比较维度

| 领域 | Ankole 当前实现 | Alma 实现 | 待比较的问题 |
|---|---|---|---|
| PTC 运行时 | 隔离 JS，无 Node/network/filesystem/timers；支持 fingerprint、memo/resume；`programmatic_tool_calling.ex:173` | Bun 自由脚本和 `sh()`，独立 PTC session/token | 任务表达能力、完成率、恢复、重放、资源消耗和权限模型分别有何差异 |
| PTC 模型可见策略 | 描述说明 loops、conditionals、Promise.all 和 intermediate processing | 明确 3+、聚合、依赖链；单调用直接执行；只输出需要的结果 | 自然选择率、单调用行为、代码质量和实际 token 是否改变 |
| PTC 默认开启 | `app/agent_computer/src/core/codex-runner/runtime/agent-home-config.ts:144` 已启用 `code_mode` | Alma 默认启用 `run_script` | 已开启能力在不同模型上的真实使用率是多少 |
| PTC 测试 | `tool_search_real_llm_test.exs:352` 强制一次 `program` 并验证 pause/resume | Skill 引导模型自然选择 | 强制能力验证之外，自然选择能否带来任务收益 |
| Tool Search | 本地确定性 client/server 实现；`tool_search.ex:1` | 辅助模型语义预选与搜索 | 本地、语义和混合路由的命中率、成本、延迟和空结果率 |
| 普通命令输出 | `app/agent_computer/src/tools/computer/format.ts:5` 为 50K，头 40% + 尾 60% | RTK 语义过滤、30K 流窗口与约 24K 通用预算 | 语义过滤与不同长度、头尾比例如何影响任务和重复读取 |
| 文件读取 | 同文件 `MAX_READ_CHARS=100_000`，另有行宽限制 | Read 为 2000 行或 51,200 字节，RTK read 另有 minimal 规则 | 主动文件读取和命令输出是否还应继续区分；注释规则有何影响 |
| 动态工具结果 | `app/agent_computer/src/core/codex-runner/job/projection.ts:13` 默认 16 KiB；web/read 有独立更大路径 | 按工具、字段和 MCP 名称分别预算 | 当前截断点是否落在关键字段；结构化投影能否减少后续调用 |
| Compaction | 默认 90%，保留 4 行 tail；`compaction_policy.ex:18` | 当前默认 80%，真实 usage、部分压缩、anti-thrash | 阈值、目标、边界和 fallback 的独立与组合影响 |
| 摘要 | light profile，8K/16K 重试 | 结构化摘要、合并旧摘要与无效压缩 fallback | 摘要质量、成本、重复读取和恢复率 |
| 缓存 | 自然 key、session key 和 affinity；`request_context.ex:114` | 多 provider cache boundaries 和 system 组织 | 哪些 provider 分支实际改善命中与成本 |
| 长任务验收 | 已有验证记录、路径和剩余风险要求 | 原题标准和尽早写当前最佳草稿 | 交付物存在率、验收通过率和完成声明准确性 |
| 工具参数错误 | 主要是 nudge/repair，不是通用 alias/coercion | 常见别名与类型修复 | 每类错误出现频率、修复成功率和语义误判率 |
| 长期记忆、Herdr | 对应产品能力和状态所有权需要另行界定 | 长期记忆与远程多 agent 管理 | fresh benchmark 中是否生效；日常使用中的实际作用如何单独测量 |

KimiCode 在 FrontierHarness 的成绩不是 Ankole 的成绩。不能用同一份榜单声称 Ankole 已经验证这些机制。

---

## 12. 用于后续取舍的实验矩阵

本节只提供区分机制所需的实验，不预先决定采用哪一种实现。

### 12.1 统一记录实际成本和状态转移

对直接工具、PTC、RTK 类投影统一记录：

- task、模型、attempt、harness 配置和工具 schema 版本；
- 每轮主模型和辅助模型的实际 input/cached/output tokens、模型单价与成本；
- 工具调用次数、轮次、墙钟、continuation、timeout 和最终 outcome；
- 每个工具的原始字节、投影后字节、`projection_status`、归档位置；
- PTC nested result 总量、stdout 量、脚本生成/修复轮数、峰值内存和 OOM；
- 因截断或摘要丢信息而重新读取、重新搜索、重复测试的次数；
- 工具路由的首轮命中、补载、误选、空结果和缓存命中；
- 恢复次数、恢复后继续的轮数、恢复后的通过率和额外成本。

4 字节/token 估算可作为本地启发式指标，与 provider usage 分开保存。成本/通过按全部试跑成本除以通过数计算，同时报告平均尝试成本和失败成本。

### 12.2 把 PTC 使用策略与运行时能力拆成两个变量

| 组 | 使用策略 | 执行能力 | 可以区分什么 |
|---|---|---|---|
| A | 当前 | 不启用 PTC | 直接工具基线 |
| B | 当前 | Ankole 隔离 PTC | 仅增加当前执行能力的影响 |
| C | Alma 式 3+/聚合/单调用边界 | Ankole 隔离 PTC | 仅改变模型可见策略的影响 |
| D | 与 C 相同 | 具备 `sh()` 或等价系统操作的运行时 | 自由系统能力带来的增量 |
| E | 与 C 相同 | 隔离运行时，但允许更完整的嵌套结果 | 完整中间结果本身的影响 |

Alma 式策略可以完整描述为：3+ 调用、循环、筛选/聚合、依赖或条件链时考虑脚本；脚本只输出后续需要的数据；单调用保持直接执行；需要独立可观察语义的 Task 等保持直接调用。

D/E 还需要记录哪些具体操作无法由隔离运行时表达、这些操作是否决定任务通过，以及恢复、重放、依赖和资源行为。这样才能区分「模型不会选择 PTC」「脚本能力不够」「完整结果被宿主截断」三种不同瓶颈。

### 12.3 把语义投影与长度预算做因子实验

可以先使用 pytest、Vitest/Jest、TypeScript/ESLint、依赖安装和 grep 等具有明确结构的输出。投影记录退出码、失败名称、断言差异、关键堆栈、遗漏条数和原始输出位置；解析失败时标记 degraded 或 passthrough。

| 变量 | 可比较的配置 | 需要观察的结果 |
|---|---|---|
| 投影方式 | 原始输出、头尾窗口、RTK 式语义投影、完整原文仅归档 | 信息损失、重复读取、通过率、输入 token |
| 输出预算 | Ankole 当前值、Alma 对应值、其他扫描点 | 是否出现预算更小但总成本更高的拐点 |
| 头尾比例 | 40/60、30/70、仅尾部、结构化字段 | 初始配置、关键中段与末尾错误分别丢失多少 |
| 嵌套结果 | 宿主预截断、完整进入脚本 | 聚合正确性、内存与最终输出量 |
| 精确读取 | 普通 Read、RTK minimal、指定行/byte range | 注释与长行信息对实际任务的影响 |

`curl` schema 化、默认 `git log --no-merges`、固定 grep 条数也适合作为独立样本，观察它们在需要真实值、merge 历史或低频匹配时的行为，而不是预先归入普遍收益或普遍损失。

### 12.4 比较辅助模型、本地检索和组合路由

| 组 | 路由方式 | 主要观察点 |
|---|---|---|
| A | 全量或当前 active set | 无额外路由模型时的 schema 成本和误选 |
| B | Ankole 本地确定性 Tool Search | 首轮命中、补载和确定性 |
| C | Alma 式辅助模型语义预选/搜索 | 隐含意图识别、主模型输入减少与辅助调用成本 |
| D | 本地候选召回 + 辅助模型重排 | 两种路径组合后的命中率、延迟和成本 |

每组都应覆盖小目录和大目录、明确工具名和隐含意图、工具描述相似、需要中途补载的任务。辅助模型的费用应按其真实模型和 provider 单独记录，不能只统计主模型缓存命中。

### 12.5 分解 compaction、预算和恢复

- 比较 80%/90% 及其他触发点，同时记录压缩后目标，而不只比较触发百分比。
- 分别切换真实 usage 校准、部分压缩、无效压缩 fallback 和 anti-thrash，观察各自的长任务结果。
- 比较不同 stdout/stderr 和总序列化预算，记录截断后是否出现新的工具调用。
- 分析 `length`、参数流中断、空 stream、网络错误和实际任务失败的比例，以及各类 continuation 的恢复后通过率。
- 对工具参数 alias/coercion 记录原调用、修复后调用、模型是否重试以及最终语义；不同模型分别统计。

### 12.6 长任务同时检查产物与声明

Background Agent Job 的对照可以组合「原始验收标准」「尽早写当前最佳草稿」「最后逐项核验」三项提示，并检查真实保存的 Page、文件或 Drive 产物。结果至少区分：

- 有产物且外部验收通过；
- 有草稿但验收未通过；
- 没有产物但模型声称完成；
- 明确报告 incomplete 且原因可定位。

---

## 13. 其他容易误读的实现细节

| 机制 | 代码事实 | 与本次成绩的关系 |
|---|---|---|
| Hashline 编辑 | 使用 `LINE#ID` 内容哈希；当前 `tools.hashlineEdit=true` 才启用，默认 `JAn=false` | 可研究其对 stale edit 和定位错误的影响，但当前默认状态和参评状态不能支持成绩归因 |
| `AttemptCompletion` | 特殊逻辑针对 Gemini 文本模型 | 本轮五个模型没有 Gemini，不是当前榜单候选解释 |
| Provider-native context management | 当前代码还有 `YYn` 等 Anthropic/OpenAI 分支 | 是否启用、与本地 compaction 如何组合，需要实际 provider 配置；不能把所有路径混为一谈 |
| `store=false` | 清理不应历史重放的 provider options | 是 provider 状态管理，不等于禁用 prompt cache |
| 长期记忆 | 当前配置存在 `memory.toolModel` 等入口 | 产品记忆能力是否在该评测 fresh runtime 中积累并跨任务复用，没有轨迹证据 |
| Herdr | 负责集中查看和远程管理多个 agent | 属于操作与交互层；是否改变单任务 harness 执行结果需要另外的数据 |
| PTC token 统计 | 嵌套结果和 stdout 都按约 4 字节/token 估算 | 用于本地观测，不等于 provider 实际计费或反事实净节省 |
| RTK tee | 默认偏向失败保存，最多 20 个文件、每个 1 MiB | 能支持部分错误恢复，不代表所有原始输出永久完整 |

---

## 14. 综合解释

Alma 的实现可以浓缩为三个相互连接的问题：

- **信息在哪里处理**：多次调用由代码聚合，单次高噪声输出由命令语义压缩，脚本可以持有完整中间结果，精确读取另有窗口与归档。
- **失败如何分类并保持协议有效**：模型适配、工具参数、流中断、上下文溢出和网络失败分别处理，不用一种通用重试表示所有问题。
- **长任务如何保留可继续状态与可验收产物**：部分 compaction、真实 usage、归档、continuation 和最终 incomplete 状态共同承担这一工作。

辅助模型和自由 Bun 脚本也是这套设计的一部分：前者用一次额外语义调用改变主模型可见的工具集合，后者用更宽的本地执行能力扩大脚本能表达的任务。它们的净收益与引入的依赖、延迟、资源和恢复语义一样，都是后续实验需要测量的变量，而不是分析阶段预先排除的选项。

当前公开数据没有 Alma 的逐次工具轨迹或功能 ablation，本地静态代码也无法证明某个机制贡献了多少通过率；本机新版与参评旧版的差异进一步限制了回溯归因。基于现有证据的回答是：**Alma 已经实现了多条可能相互增强的 harness 路径，并在过程榜取得有竞争力的结果；每条路径的净收益、模型适用范围和向 Ankole 迁移后的表现，仍需要独立实验确定。**

---

## 附录 A：复核方法

### A.1 榜单

数据源：[FrontierHarness live](https://frontierharness.org/live/)、[公开 API](https://frontierharness.org/api/live)、[公开任务与结果仓库](https://github.com/frontier-harness-eval/eval)。

复算步骤：

1. 记录抓取时间与 `complete`，不能省略过程状态。
2. 用 `finished_fields` 解码每条记录，并用 `harnesses/models/outcomes` 数组还原索引。
3. 按 harness/model 聚合完成数、通过数、总成本、输入、输出和 cached tokens。
4. `cost per pass = sum(cost_usd) / pass_count`；成本缺失不能被静默当成真实 0 做精细结论。
5. 配对分析按 `(task, model, attempt)` 取交集，报告交集大小，不把子集结论外推到未完成任务。
6. 不把同一任务的重复 attempt 当作完全独立样本，不根据一次快照声称统计显著。

### A.2 Alma 与 RTK

- 本地版本：`/Applications/Alma.app/Contents/Info.plist:20`。
- 当前服务端：`/Applications/Alma.app/Contents/Resources/alma-server/lib/server.mjs`。
- PTC 使用策略：`/Applications/Alma.app/Contents/Resources/alma-server/resources/bundled-skills/programmatic-tools/SKILL.md:12`。
- 当前 RTK：`/Applications/Alma.app/Contents/Resources/alma-server/resources/rtk/rtk`。
- 参评包：[Alma v0.4.212](https://github.com/yetone/alma-releases/releases/tag/v0.4.212)。
- 早期能力：[v0.4.113](https://github.com/yetone/alma-releases/releases/tag/v0.4.113)、[v0.4.165](https://github.com/yetone/alma-releases/releases/tag/v0.4.165)、[v0.4.198](https://github.com/yetone/alma-releases/releases/tag/v0.4.198)。
- 后加能力：[v0.4.506](https://github.com/yetone/alma-releases/releases/tag/v0.4.506)、[v0.4.537](https://github.com/yetone/alma-releases/releases/tag/v0.4.537)。
- RTK 源码：[v0.29.0](https://github.com/rtk-ai/rtk/tree/v0.29.0)。

## 附录 B：未验证事项

- 没有完整读取参评 `0.4.212` ASAR 中的 `server.mjs`，因此未核实旧版默认 80% compaction、全部输出阈值和完整默认工具路由。
- 没有 Alma 参评时的逐次模型请求、工具调用日志、辅助模型配置和 RTK/PTC 自然使用率。
- 没有 Alma 的功能消融，不能把任何静态机制直接换算为确定的通过率提升。
- 没有在相同 benchmark 上运行 Ankole，KimiCode 的成绩也不代表 Ankole。
- 本次任务是只读分析，未修改 Alma 或 Ankole 产品代码，未运行产品测试；统计结论来自公开 API 复算，代码结论来自静态阅读。
