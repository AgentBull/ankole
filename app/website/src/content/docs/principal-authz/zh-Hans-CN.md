---
title: 主体与 AuthZ
description: Ankole 实例的权限治理边界——涵盖主体模型、授权规则、权限组成员关系与运行时权限检查。
section: Developer guide
order: 106
---

在 Ankole 中，每一项操作都有明确的责任主体：人员登录控制台、Agent 执行推理回合、后台任务唤醒归属所有者。某个主体究竟获准执行哪些操作，由 AuthZ 在动作发生时实时判定。本文对照 `Ankole.Principals` 与 `Ankole.AuthZ` 的实际代码实现，阐述这一权限边界。

授权是在系统边界强制执行的运行时契约，而非写进提示词里寄希望于模型自觉遵守的软性约定。主体（Principal）是持久且可问责的身份标识，授权规则持久化存储在 PostgreSQL 中；每次受检操作都由 Rust Kernel 基于控制面构造的确定性快照求值，调用方必须无条件服从求值结果。

## 主体：统一的问责身份

人员、Agent 与系统服务共享同一套持久、可问责的主体模型。每个 Principal 严格归属于单个租户，持有全局唯一的不透明标识符 `uid`。`principals` 表记录了主体的类型 `type`（`:human`、`:agent` 或 `:system`）、状态 `status`（`:active` 或 `:disabled`），以及仅针对 `:human` 生效的成员身份 `membership`（`:member` 或 `:guest`，`:agent` 与 `:system` 固定为 `nil`）。

在关联关系上，一个人员主体对应一条 `HumanUser` 记录、零至多条站点级 `SiteCredential` 记录（存于 `principal_site_credentials`，如通过校验的邮箱验证码地址），以及零至多条租户级 `ExternalIdentity` 记录（存于 `principal_external_identities`，来自外部联邦身份源）；一个 Agent 主体则对应一条 `Agent` 记录。所有类型的主体收敛在同一张核心表中，使整套问责体系完全统一：每一条审计日志、授权规则与权限组成员关系都直接指向同一个稳定的 Principal `uid`。

人员的 `membership` 属性界定了租户内的协作边界：内部成员（`member`）会自动纳入计算式权限组 `all_humans`；外部访客（`guest`）则必须获得显式的 Pod 页面共享或 Agent 授权才能访问对应资源，且不可加入内置管理员组（`siteadmin` 或 `pod_admin`）、没有 Private 根目录，也不会获得 Brain 的 `world` 范围。

已停用的主体不存在所谓“部分可用”的中间态——Kernel 对其任何权限请求都会直接返回 `principal_disabled`。因此，只需停用主体本身即可在整个实例范围内一键收回其全部权限，无需逐条删除既有授权规则。

## grant：谁能做什么

`permission_grants` 表中的每条记录必须且只能归属于以下三类受让人所有者之一（由 `Ankole.AuthZ.Validations.GrantShape` 与 PostgreSQL Check 约束 `num_nonnulls(principal_uid, group_id, source_node_id) = 1` 双重保障）：

- **单个主体**（`principal_uid`）；
- **单个权限组**（`group_id`）；
- **Drive 节点 Userset**（`source_node_id` 搭配精确的 `source_action`：`node_view`、`node_contribute`、`node_edit`、`node_manage` 或 `node_comment`）。

涉及 Drive ACL 的授权记录还会保存 `target_node_id` 与 `target_scope`（`container` 作用于整棵继承子树，`self` 仅作用于目标节点自身）。每条授权规则包含以下核心字段：

- `resource_pattern`：经 `Input.validate_resource_pattern_syntax` 校验的资源模式，覆盖统一的冒号分隔命名空间——包括 `site_console:**`（站点控制台）、`tenant_console:**`（Pod 管理）、`agent:<uid>`（运行时 Agent 访问），以及 `drive:**`（如 `drive:space:**`、`drive:private:<uid>:**`、`drive:**:<node-id>:**`、`drive:**:<node-id>:node`）。系统禁止使用无前缀的裸 `"**"` 通配模式；
- `action`：精确动作名字符串，禁止包含冒号；
- `condition`：CEL 布尔表达式，默认为 `"true"`，写入前经 `Input.validate_condition_syntax` 校验语法；
- `description` 与 `metadata`：供运维与审计人员查阅的备注信息。

主体授权、权限组授权与 Userset 授权分别通过各自的部分唯一索引，确保自然键（`owner + resource_pattern + action + condition`）不重复。授权规则的新建、Upsert 与更新统一经由控制面完成，底层数据库会拒绝任何所有者结构非法或语法畸形的写入。

## group：静态与计算式成员

权限组用于将一批具名主体归集起来统一授权，避免逐人维护零散规则。每条权限组记录包含来源域 `domain`（`:operator`、`:directory`、`:im_group` 或 `:signal_source`）、类型 `kind`（`:static` 或 `:computed`），以及供动态组求值使用的 CEL 表达式 `computed_condition`。

每个租户均内置动态组 `all_humans`（判定条件为 `principal.type == "human" && principal.membership == "member" && principal.status == "active"`）与静态组 `pod_admin`（授予该 Pod 内的 `tenant_console:**` 管理权限）；特权站点租户还额外内置静态组 `siteadmin`（授予 `site_console:**` 与 `tenant_console:**` 权限）。只有启用状态的内部人类成员（`member`）才可加入 `siteadmin` 或 `pod_admin`。运维人员在站点控制台切换当前查看的数据租户时，其操作者自身身份及 `siteadmin` 权限查找均保持不变。在存储层面，静态组成员关系保存在 `principal_group_memberships` 表中，计算式成员关系基于授权快照实时求值，外部目录组与 IM 群组则通过 `principal_group_external_bindings` 表关联同步。

## 一个决定是如何做出的

控制面与 Rust Kernel 职责分明，共同确保 AuthZ 成为不可绕过的硬性执行边界：

- **控制面负责维护持久状态、执行 Ash 授权检查并组装快照。** 受保护的动作通过 `Ankole.AuthZ.Extension` 声明规则，`Ankole.AuthZ.Authorizer` 根据 `%Ankole.AuthZ.Actor{principal, turn_authority, authn}` 校验执行主体。Agent 回合使用 Agent 自己的资源权限。经验证的认证事实写入 `context.request.authn`，适用于该 Agent 的 grant 提供 CEL 条件。`turn_authority` 与 `WorkAccess` 分别检查指令是否仍然有效。
- **Rust Kernel 与 PostgreSQL 负责确定性规则求值。** 执行常规权限检查时，`Ankole.AuthZ.Snapshot` 通过单条 SQL 一次性加载主体状态、所属权限组与候选授权规则，随后交由 Rust Kernel 完成资源模式匹配、动态组判定与 CEL 条件求值。对于 Drive 节点访问控制，系统采用 5 位 ACL 锚点图（`node_view=1`、`node_contribute=2`、`node_edit=4`、`node_manage=8`、`node_comment=16`；角色掩码为 `view=1`、`contribute=19`、`edit=23`、`manage=31`）：先在 Rust Kernel 中一次性求值与当前请求相关的 CEL 条件，再由 PostgreSQL 通过 `WITH RECURSIVE`（`UNION` 最小不动点）合并直接授权、权限组继承、容器子树继承与 Userset 传递边。

`Ankole.AuthZ` 对外暴露的公开调用入口包括：`authorize(subject, resource, action, context)`、返回布尔值的 `allowed?/4`、返回单动作完整决策 Map 的 `authorize_decision/4`、针对同一资源批量校验多个动作的 `authorize_all_decision/4`、基于单次快照并行校验多组独立“资源 + 动作”对的 `authorize_checks/3`，以及用于求值 Drive 访问上下文的 `evaluate_drive_context/2`。所有入口均自行核查底层快照，绝不采信调用方自报的权限声明。

## 决定状态

每次权限求值都会返回以下四种确定状态之一，调用方须严格履行对应的处理义务：

- **`allow`**：操作获准，可继续执行。
- **`deny`**：操作被拒绝，同时返回 `deniedAction` 指明受阻动作；调用方必须立即中止操作。
- **`principal_disabled`**：目标主体已被停用，按带明确原因的权限拒绝处理。
- **`invalid_request`**：鉴权请求自身格式不合法；调用方应修正传参，切勿盲目重试。

每次求值都会同步产出结构化诊断信息，确保拒绝原因清晰可查。调用方也可使用 `Ankole.AuthZ.Decision.result/1` 将决策 Map 转换为标准的 `:ok | {:error, reason}` 元组进行分支处理。

## 强制实际发生在哪里

AuthZ 之所以无法被 Agent 绕过，是因为运行时在每一道关键入口都部署了硬性校验：

- **AIGateway 边缘**：根据经过验证的访问令牌解析调用方主体，并严格依据该主体的授权规则决定允许访问的模型选择符与上游提供商。
- **工具装配与派发**：执行 Agent 必须处于启用状态，工具必须在其声明的目录中，参数和指令也必须有效。工具所属模块按该 Agent 的身份校验实际访问的资源。
- **会话与后台任务提交**：会话 Driver 在持久化提交前校验租约栅栏（fence）；Worker 上报 Job 操作时，控制面同样会核验持久化的 Job Attempt 栅栏与已认证连接身份。
- **管理控制台接口**：调用站点控制台（`/api/v2`）与 Pod 管理接口（`/api/v2/pod/admin`）时，必须同时具备经验证的浏览器凭证、有效的 CSRF 令牌，以及当前生效的 `site_console:**` 或 `tenant_console:**` 授权。

模型无法靠输出文本自行宣称“我拥有权限”——所有请求均由系统边界对照主体身份与授权规则独立裁定，并强制落地。

## 运维界面

站点控制台在 `/api/v2` 下提供面向全局运维的 JSON:API 路由，管理主体、权限组与授权规则（需 `site_console:**` 权限）；Pod 管理员则通过 `/api/v2/pod/admin/*` 管理本租户成员、邀请、租户设置与身份源提供商（需 `tenant_console:**` 权限）：

`site_console:drive` 权限覆盖所选租户的完整 Drive 树，包括成员和 Agent 的 Private 内容。运维人员可根据该权限授予的动作读取、更新或删除内容。

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/principals` | 列出主体 |
| `POST` | `/api/v2/principals` | 预创建人类内部成员主体 |
| `GET` | `/api/v2/principals/:uid` | 读取单个主体详情 |
| `PATCH` | `/api/v2/principals/:uid` | 更新人类主体资料（`display_name`） |
| `PATCH` | `/api/v2/principals/:uid/membership` | 修改人类主体的 `membership`（`member` 或 `guest`） |
| `GET` | `/api/v2/principals/:uid/access` | 查看人类访问状态、限制项与恢复审查投影 |
| `POST` | `/api/v2/principals/:uid/access-disables` | 暂停（`suspended`）或离职解绑（`offboarded`）人类主体 |
| `POST` | `/api/v2/principals/:uid/access-restorations` | 清除限制项后恢复已停用的人类主体 |
| `GET` | `/api/v2/principals/:uid/groups` | 列出主体所属的权限组 |
| `GET` | `/api/v2/principals/:uid/grants` | 列出主体的授权规则 |
| `GET` | `/api/v2/principal-groups` | 列出权限组 |
| `POST` | `/api/v2/principal-groups` | 创建运维权限组 |
| `GET` | `/api/v2/principal-groups/:name` | 读取单个权限组详情 |
| `PATCH` | `/api/v2/principal-groups/:name` | 更新权限组 |
| `DELETE` | `/api/v2/principal-groups/:name` | 删除运维权限组 |
| `POST` | `/api/v2/principal-groups/computed-member-previews` | 预览计算式权限组的匹配成员 |
| `POST` | `/api/v2/permission-grants` | 创建运维授权规则（通过 `/api/v2/permission-grants/:id` 执行 `PATCH`/`DELETE`） |

所有授权与成员变更均统一经由 `Ankole.AuthZ` 处理，写入前会严格校验所有者结构、资源模式语法与 CEL 条件语法；同时，PostgreSQL 在存储层通过 Check 约束与部分唯一索引守护同一组不变量。

## 主体和 AuthZ 不是什么

- **不是提示词约束**：AuthZ 不依赖模型“听话”，而是在系统边界直接核验主体身份并强制阻断越权请求。
- **不是临时角色标签**：主体既不是用于在单实例内拼凑多租户隔离的临时字段，也不是按次随手挂接的请求角色，而是可被授权、编组与审计的稳定问责身份。
- **Kernel 不是第二套独立策略中心**：控制面持有持久状态并组装快照，Rust Kernel 仅对传入快照执行纯函数式的确定性求值，最终由调用方落实裁定结果。

## 下一步

- 了解经过验证的令牌如何在 AIGateway 边缘解析为主体身份，请参阅 [AIGateway API](../ai-gateway/)。
- 了解会话 Driver 栅栏如何为单次 Agent 回合建立并发隔离边界，请参阅 [Sessions](../sessions/)。
