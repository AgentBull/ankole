# Auto Ontology 源码调研与 Ankole 原生能力方案

日期：2026-11-07。本文面向 Ankole 的产品与架构设计，记录源码事实、推导依据和实现建议。建议尚未构成已实现的系统契约。

上游分析固定在 NVIDIA Auto Ontology 的 [`c4495670947eb7b4616f0dd9900e5ced2a48ca1e`](https://github.com/NVIDIA/auto-ontology/commit/c4495670947eb7b4616f0dd9900e5ced2a48ca1e)，版本为 1.2.0。Ankole 部分依据调研时的工作树，包含正在开发的未提交改动。验证方式为源码、测试源码和设计文档交叉检查，未运行上游服务或真实数据准确率评测。

本文侧重以现有 Base 为起点的原生实现。面向外部 OLTP、OLAP 和数据湖的长期设计，见[结构化数据与 Brain 补充报告](ankole-2-structured-data-brain.md)。

## 主要判断

Ankole 值得吸收 Auto Ontology 的核心能力：把业务口径绑定到真实字段、关联和计算，并让 Agent 利用可验证的数据执行结果回答问题。主要投入应放在可复用的业务定义，以及正确处理数据粒度的跨表查询。

如果首批目标数据位于 Base，原生实现可以复用 Brain、Base 和现有 Agent 的职责。如果首批目标数据位于外部 PostgreSQL、Snowflake 或 Databricks，通过 Connectors 接入 Auto Ontology 更容易验证完整用户流程。数据所在地决定实施顺序。

## 源码中的完整处理流程

Auto Ontology 围绕关系型数据建立业务语义目录，再利用目录生成、检查和执行 SQL。它使用 PostgreSQL 和 pgvector 保存目录及语义信息，应用包括 FastAPI 后端、摄取服务和 Next.js 界面。[组件说明](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/README.md#L34-L53)

| 环节 | 源码行为 | 可借鉴能力 |
| --- | --- | --- |
| 获取结构 | 提取表、列、视图、主外键和历史查询，检查已发现表的列信息是否完整 | 同时使用结构、关系和已有查询经验 |
| 分析字段内容 | 获取有限样本，计算样本内唯一性和常见值，进一步探测低基数字段 | 将业务说法绑定到数据库实际值 |
| 生成业务术语 | 为表生成 Term，为列生成 ColumnAttribute，保存名称、说明、同义词和物理绑定 | 为技术字段建立可检索的业务解释 |
| 重建关联 | 利用声明外键、候选唯一列、语义检索、模型判断和数据值重叠 | 为查询寻找连接路径及中间表 |
| 积累计算方式 | 从历史 SQL 提取表达式，生成 SqlAttribute，支持人工修改 | 保存已有计算方法 |
| 回答问题 | 抽取概念、检索候选、补充关联上下文、生成 SQL、检查、探测、执行和有限修复 | 将数据库实际反馈纳入回答过程 |

对应源码入口：

- [`catalog/extract.py`](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/catalog/extract.py#L80-L118)：获取结构和历史查询。
- [`semantic/visit_enter.py`](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/semantic/visit_enter.py#L406-L562)：样本与字段分析。
- [`dal/schema.py`](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/dal/schema.py#L456-L663)：Term、ColumnAttribute、SEMANTIC_FK 和 SqlAttribute。
- [`semantic/semantic_fk.py`](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/semantic/semantic_fk.py#L466-L528)：推测关联候选。
- [`semantic/sql_attribute_suggester.py`](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/semantic/sql_attribute_suggester.py#L584-L764)：从已有 SQL 建议计算属性。
- [`text_to_sql_graph.py`](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/retrieval/text_to_sql/text_to_sql_graph.py#L329-L612)：问答运行图。

它的工程价值集中在让模型逐步获得足够具体的查询依据。检索到「客户」和「收入」两个概念，还需要找到连接它们的字段、中间表和实际枚举值。

## 影响方案的能力边界

### Term 的主要粒度是表

提取提示倾向「一表一个 Term」，只对特定关联表考虑第二个 Term，并明确不生成 `IS_A`、`PART_OF`、`ROLE` 关系。这里的 ontology 与 Brain 的对象分类、知识关系具有不同侧重点。[提取规则](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/semantic/term_extractor.py#L33-L51)

### 可回答性分数衡量候选覆盖

`check_answerable` 的核心覆盖率是「找到字段候选的概念数 / 抽取出的概念数」。该计算没有证明字段可以正确关联、具有所需时间范围，或者符合业务口径，不能将其展示为答案正确概率。[覆盖率计算](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/retrieval/entity_coverage/agents/coverage.py#L38-L75)

### 结构合法仍可能算错

上游关联修复代码明确指出：通过共同父表连接两个子表，在关系图上合法，却可能产生意外的多对多展开。SqlAttribute 等定义又主要作为 SQL 生成上下文进入模型，不能据此承诺确定性执行某个指标。[关联修复边界](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/retrieval/text_to_sql/db_probe/join_path_check.py#L649-L681)、[SQL 生成上下文](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/retrieval/text_to_sql/agents/sql_from_semantic.py#L128-L180)

### 修复流程需要区分结果状态

当前实现会对原因不明的空结果再重建一次查询；还有一条路径，在意图验证耗尽后返回最后一份静态合法 SQL。调用方需要区分「生成了 SQL」与「执行成功并获得结果」，并允许零行成为真实答案。[空结果处理](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/retrieval/text_to_sql/agents/empty_result_value_repair.py#L97-L145)、[SQL 回退](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/retrieval/text_to_sql/main.py#L304-L340)

### 学习能力需要逐项验证

历史 SQL 表达式建议中的 `_usage_score` 明确返回 `0.0`，没有按真实使用频次完成预期排序。人工修正、历史查询利用和自动学习应分别评估，不能从产品描述推断它们已经形成完整的反馈机制。[评分实现](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/semantic/sql_attribute_suggester.py#L69-L118)

## 从用户任务推导必要能力

以「上季度华东客户按产品的净收入」为例，系统至少需要确定：

- 收入按订单、开票还是收款确认，是否扣税、折扣和退款。
- 时间范围使用哪个日期字段和时区。
- 华东客户取客户归属地区还是订单发生地区。
- 每条金额代表订单、订单行还是收款记录。
- 退款如何归属产品，不同币种是否可以相加。
- 哪些表和字段实现上述定义，执行时绑定是否有效。

假设一笔订单金额为 100，有两条商品明细和三条退款记录。直接连接三张表会得到六行，订单金额可能被累计为 600。`SUM(DISTINCT 金额)` 也不能解决问题，因为两笔金额同为 100 的订单又会被合并。

正确计算通常需要先按适当粒度聚合，再连接。如果退款只记录在订单上，用户却要求按产品计算净收入，数据库结构无法决定退款分摊规则。Agent 应寻找已有业务规则；规则缺失时，只确认实际影响结果的歧义。

因此需要区分三个层次：

| 层次 | 示例 | 职责 |
| --- | --- | --- |
| 业务概念 | 客户、净收入、有效订单 | 解释含义、别名、适用条件与来源 |
| 可执行定义 | 净收入的字段、过滤条件、时间轴和关联路径 | 把业务含义绑定到具体数据源 |
| 业务实例 | 某家公司、某张订单 | 保存对象身份、具体记录及相关知识 |

Auto Ontology 主要强化可执行定义及其检索上下文。Brain 已经拥有业务知识和对象的基础。为每张表创建 Brain 类型，或者为每行记录创建知识对象，都不能自然补齐业务含义与执行之间的连接。

## 在 Ankole 中复用现有职责

Brain 已有稳定 Page 身份、来源关联、知识版本、实时权限过滤、混合检索和图浏览。Base 已有稳定字段 UUID、类型化查询、聚合、公式、视图及数据库执行入口。Agent Computer 已暴露 `base.tables`、`base.schema`、`base.query` 和 `base.aggregate`。[Brain 契约](../design-docs/BrainV3.md)、[Base 契约](../design-docs/PodContentModel.md)、[CLI](../../app/agent_computer/src/cli/pod/pod-cli.ts)

| 内容 | 建议归属 | 实现原则 |
| --- | --- | --- |
| 业务术语、解释、制度依据 | Brain / Knowledge Page | 复用概念、别名、来源和检索 |
| 表、字段、类型、枚举及已有关联 | `Pod.Bases` | 读取现有定义，避免复制 Base catalog |
| Base 内可复用计算定义 | Base 查询所属模块 | 绑定字段 UUID，由服务器解释执行 |
| 外部数据库能力与凭据 | `Connectors` | 复用账户、凭据和工具边界 |
| 提问、上下文补充和有限重试 | Session Agent | 复用现有模型运行机制 |
| 答案、图表和报告 | 对话、Base 视图、Applet、Pod 文档 | 使用现有呈现与保存能力 |

`BaseView` 的图表配置已经保存 `AggregateQuery`，简单命名分析可以直接复用；单行计算已有 `Pod.Formula`。当多个问题、图表和 Agent 确实需要共享同一口径时，才值得增加独立于展示的指标定义。[视图与聚合配置](../design-docs/PodContentModel.md#formulas-queries-views-copies-and-limits)

针对 Base 的最小指标定义可以包含名称、说明、业务依据 Page、起始表、计算粒度、字段 UUID、固定过滤、时间字段、单位、可变参数、关联路径和版本。它复用已有查询表达，由 Base 所属模块管理。图表可以引用定义，临时图表继续使用自身查询。Brain 检索解释和来源，执行端使用结构化定义；同一个已命名指标只保留一个可修改的计算规则来源。

此处归属建议适用于 Base 范围内的指标。跨外部数据源的组织级语义定义，需要按补充报告讨论的职责划分处理。

## 原生查询路径

1. 限定问题的数据范围。用户在 Base 中提问时，从该 Base 的结构、视图和说明开始；跨工作区发现时再使用 Brain。
2. 直接读取字段类型、枚举和显式关联，仅对必要字段取样。
3. 模型选择指标和参数，服务器解析固定计算规则。改变日期或分组不应隐式改变指标公式。
4. `Pod.Query` 继续接收表、字段和关联 UUID，并编译真实 SQL。
5. 结果附带实际口径、来源、查询时间和必要版本信息，支持展开条件和下钻记录。

Auto Ontology 不能通过反射 Ankole 控制平面 PostgreSQL 自动获得完整 Base 逻辑模型。小表记录位于控制平面 JSONB，大表和关联表位于租户 Base shard，物理表和字段使用内部 UUID。原生查询应继续通过 Base 模块处理存储、权限和版本。[存储契约](../design-docs/PodContentModel.md#inline-and-physical-storage-modes)

## 跨表分析的实现范围

`Pod.Query.aggregate` 当前接受一张表及其字段定义。Base 关联字段要求两端属于同一个 Base；添加关联会将两端表提升到租户物理存储。第一批跨表能力可以沿同 Base 已声明的关联实现。[聚合入口](../../app/control_plane/lib/ankole/pod/bases.ex)、[关联约束](../../app/control_plane/lib/ankole/pod/bases_schema.ex)

建议先支持：

- 一个事实粒度，沿关联获取维度，例如订单按客户地区聚合。
- 使用关联对象判断条件，例如统计购买过某类产品的客户。存在性判断避免复制客户行。
- 子表先聚合再连接主表，例如按订单汇总退款后计算净收入。

多对多分摊依赖明确业务规则。任意跨 Base、跨数据库连接可以后置。

后端执行这些形态能减少整表搬运，并统一检查粒度、关联和读取事务。偶发的小规模探索仍可由 Agent Computer 通过 Base API 取数分析。单表查询继续使用现有 inline 或 physical 路径，无需为统一表面形态而强制所有表物理化。

## 生成、纠正和版本

业务说明应按实际需要生成，优先使用既有说明、枚举、公式、视图和关联。模型推测需要保留来源，不能覆盖人工定义。用户纠正口径后，按现有权限保存可复用定义；后续问题直接使用，不要求逐字段认证。

Brain `SourceLearning` 在事务外调用模型，并在提交时重新核对来源版本。业务语义生成可复用这一模式，但输入版本应包含依赖的 Base schema 与指标定义版本。[来源学习](../../app/control_plane/lib/ankole/brain/source_learning.ex)

字段改名依靠 UUID 保持绑定；删除或类型变化应指出失效依赖。数据行变化通常只影响执行结果，无需重建整套语义。

定义版本、查询参数和执行时间可以解释结果来源，不能保证未来重跑得到相同数字。长期保存的报告需要同时保存当时结果。该需求本身不要求对全部数据建立时光回溯机制。

界面可以在 Base 中提供业务说明和口径入口，对话显示结果及依据，复杂分析使用 Applet。关系图复用现有图组件；可执行数据库关联仍由数据所属模块管理。

## 外部数据库接入路线

| 路线 | 适用条件 | 收益与代价 |
| --- | --- | --- |
| Connectors 接入 Auto Ontology | 首批目标为外部仓库 | 复用连接器、目录构建和查询修复；承担服务部署、身份接入和独立语义管理成本 |
| Ankole 原生实现 | 首批目标为 Base 和工作区知识 | 复用权限、字段身份、版本和交互；补齐语义绑定及跨表计算 |
| 整体移植上游应用栈 | 缺少已验证需求 | 会引入另一套认证、界面、模型配置、目录和任务流程，不建议作为默认路线 |

上游 MCP 提供术语搜索、字段说明、SQL 属性、可回答性检查和问答。其 MCP 认证使用调用者 OAuth 身份；公共 REST API 的用户 API token 是另一条接入途径。Ankole 应通过现有 Connector 或 Skill 的 MCP 依赖接入，并验证真实账户路径。[MCP 工具](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/mcp/auto_ontology_mcp/tools.py#L60-L133)、[MCP 认证](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/docs/mcp.md#L78-L101)、[Ankole MCP 契约](../design-docs/MCPBackedSkills.md)

MCP 返回截断后的结果行，同时提供 `row_count` 和 `truncated`。Agent 不能把这些行当作完整数据再次计算总额。[结果封装](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/mcp/auto_ontology_mcp/chat.py#L46-L101)

支持多种数据库不等于跨库查询。上游候选准备会选定目标数据库并收敛候选；原生设计同样应明确实际执行范围。[数据源选择](https://github.com/NVIDIA/auto-ontology/blob/c4495670947eb7b4616f0dd9900e5ced2a48ca1e/auto_ontology/retrieval/text_to_sql/agents/candidates_retrieval.py#L426-L731)

## 实施与验收

| 顺序 | 交付内容 | 完成标准 |
| --- | --- | --- |
| 1 | 一个真实 Base、代表性问题、业务定义和人工核算结果 | 分清口径、字段定位、关联、计算和数据本身造成的错误 |
| 2 | 单表发现、视图复用、必要共享口径、实际聚合、依据与修正 | 不同问法使用同一口径，用户修正可在后续对话中复用 |
| 3 | 同 Base 关联查询、粒度检查、子表预聚合与下钻 | 多表结果正确，不因关联重复而增大金额 |
| 4 | 一个真实外部数据源 | 身份、目录、执行、结果完整性与错误处理均可用 |

阶段 2 是垂直切片。如果目标包含多表业务分析，阶段 3 属于完整交付。首批数据位于外部仓库时，可以优先完成桥接版本，再根据真实使用决定原生化范围。

完整实现涉及 `Pod.Bases`、`Pod.Query`、必要声明与迁移、RPC 和 Session 工具入口、界面及生成客户端，并更新所属规范。简单聚合适合由 Session 直接调用；长时间探索继续使用 BackgroundAgentJob。

应验证以下用户行为：

- 同额订单和多条明细、退款既不重复累计，也不错误去重。
- 日期边界、空值、零值、精确小数及产品分摊符合口径。
- 字段改名有效，删除或变型明确指出失效绑定。
- 用户修正影响后续对话，后台生成不覆盖人工修正。
- 来源权限变化后，检索与执行均使用当前权限。
- 聚合覆盖完整匹配数据，空结果与截断结果得到正确解释。

上游评测比较「schema 单次提示、无工具」与完整 Auto Ontology Agent。该比较可评估整套系统增益，不能将增益全部归因于 ontology。[评测方法](https://github.com/NVIDIA/auto-ontology-eval/blob/ec41b2c5b795637759297b90c1d19b42693200f9/README.md#L21-L44)

Ankole 应固定 Agent、模型和调用预算，比较现有 schema 工具、加入业务定义、再加入关联和值探测的效果。同时记录静默错误、用户追问、人工维护成本、数据库负载和响应时间。

首个原生样例适合选择具有主表、明细、退款或状态记录的真实 Base，验证定义、查询、结果、纠正及再次使用的完整流程。
