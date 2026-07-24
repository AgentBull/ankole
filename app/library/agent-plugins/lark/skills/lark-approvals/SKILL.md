---
name: lark-approvals
version: 1.2.0
description: "飞书审批：以当前 Turn 发起人的身份查询和处理审批待办、已办和实例，搜索可发起审批定义、查看定义详情、上传附件并发起原生审批实例。也用于整理发票或收据压缩包，并在用户点击同意后提交报销。审批待办不是飞书任务；非审批类待办走 lark-oa。不负责创建审批定义；三方审批定义不走原生提单。"
default_enabled: true
category: productivity
tags: [lark, feishu, approval, workflow]
metadata:
  requires:
    bins: ["lark-cli"]
  cliHelp: "/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals"
  upstream: https://github.com/larksuite/cli/tree/a7865cd0a7416655535517a2a630848fde318761/skills/lark-approval
  upstream_commit: a7865cd0a7416655535517a2a630848fde318761
  modified_for: Ankole one-to-many digital coworker runtime
---

# 飞书审批

**CRITICAL — 开始前 MUST 先读取 [`references/user-runtime.md`](references/user-runtime.md)。**

Ankole 是一名数字同事服务多个用户，不是只服务一个人的个人数字助理。每次操作只使用当前 Turn 发起人的独立 user profile。不得把一个用户的 profile、审批列表、人员 ID 或提交上下文复用给另一个用户。

所有命令都必须调用下面的 wrapper：

```text
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals
```

不要为本 Skill 直接调用 `lark-cli`，也不要传 `--as` 或 `--profile`。wrapper 根据当前 Turn 发起人选择 profile，并移除继承的 Agent bot 凭据。审批读取和写入固定使用该 profile 的 user 身份；附件上传固定使用同一 profile、同一 PersonalAgent app 的应用身份。wrapper 只串行化账号配置操作。正常审批读取、附件上传和审批写入可在不同用户 profile 之间并行。

**用户之间的隔离靠这里的规则维持，不是沙箱强制的。** 同一个 Agent 下所有人的 profile 存在同一个 CLI 配置目录里，能被列出来；绕过 wrapper 直接调 `lark-cli --profile` 就会用到别人的身份。所以：不得直接调用 `lark-cli`，不得读取、列出或复制共享 CLI 配置，不得自行设置 `ANKOLE_RUNTIME_*` 环境变量，也不得用其他命令绕过 wrapper。

如果 wrapper 报告当前 Turn 没有有效的人类 Principal 或 profile，立即停止并把错误告诉用户。

调用前按需读取 references 中对应的文件，查参数结构，不要猜字段。**references 是审批命令和表单结构的第一信息源。** reference 未覆盖的字段只用 wrapper 的 `schema <resource> <method>` 确认。

**发起新审批的硬规则：** 先用 `clarify` 把 Markdown 草稿给当前用户看；在用户点击 `同意并提交` 之前，不得调用 `files upload` 或 `instances create`。所有通过 API 发起的新审批都走同一套流程，见下面的“发起审批 SOP”。

## 路由优先级（先判断是不是审批，再选命令）

审批待办不是飞书任务。**只要用户的核心对象是审批单据、审批待办或审批实例，就优先使用 `lark-approvals`，不要让渡给 `lark-oa`。**

### 明确归 `lark-approvals` 的高优先级语义

出现以下任一语义时，优先走 `lark-approvals`：

- 审批待办、审批单据、审批实例、审批意见、审批定义
- 同意、拒绝、转交、退回、撤回、催办、加签、抄送
- 待办列表、待办单据、已发起审批、已办审批、审批详情、同意可编辑
- 发起请假、报销、出差或其他原生审批
- 上传审批表单所需的图片或附件

**判定规则：** 只要最终动作是对审批单据做同意、拒绝、转交、退回、撤回、催办、加签、抄送、查详情、查已发起、查已办、查待办或发起审批，就归 `lark-approvals`。只有非审批类任务、OKR 或考勤操作才走 [`lark-oa`](../lark-oa/SKILL.md)。

## 选哪个命令

| 想做什么 | wrapper 命令 | 按需读取 reference |
|---|---|---|
| 搜可发起定义 | `approvals search` | [`lark-approval-approvals-search.md`](references/lark-approval-approvals-search.md) |
| 看审批定义详情或提单前确认表单与流程 | `approvals get` | [`lark-approval-approvals-get.md`](references/lark-approval-approvals-get.md) |
| 提交用户已同意的原生审批 | `instances create` | [`lark-approval-initiate.md`](references/lark-approval-initiate.md) |
| 查待办或已办 | `tasks query`（`topic`：1 待办、2 已办、17 未读、18 已读） | [`lark-approval-tasks-query.md`](references/lark-approval-tasks-query.md) |
| 看表单、进度或当前节点 | `instances get` | [`lark-approval-instances-get.md`](references/lark-approval-instances-get.md) |
| 同意审批 | `tasks approve` | [`lark-approval-tasks-approve.md`](references/lark-approval-tasks-approve.md) |
| 拒绝审批 | `tasks reject` | [`lark-approval-tasks-reject.md`](references/lark-approval-tasks-reject.md) |
| 转交审批 | `tasks transfer` | [`lark-approval-tasks-transfer.md`](references/lark-approval-tasks-transfer.md) |
| 加签审批 | `tasks add_sign` | [`lark-approval-tasks-add-sign.md`](references/lark-approval-tasks-add-sign.md) |
| 退回审批 | `tasks rollback` | [`lark-approval-tasks-rollback.md`](references/lark-approval-tasks-rollback.md) |
| 催办审批 | `tasks remind` | [`lark-approval-tasks-remind.md`](references/lark-approval-tasks-remind.md) |
| 撤回已发起审批 | `instances cancel` | [`lark-approval-instances-cancel.md`](references/lark-approval-instances-cancel.md) |
| 给审批实例追加抄送 | `instances cc` | [`lark-approval-instances-cc.md`](references/lark-approval-instances-cc.md) |
| 按定义查已发起审批 | `instances initiated` | [`lark-approval-instances-initiated.md`](references/lark-approval-instances-initiated.md) |
| 上传一个审批图片或附件 | `files upload` | 本文件的“上传审批附件或图片” |

处理链：

- 发起审批：整理材料 -> 没有 `approval_code` 时执行 `approvals search` -> `approvals get` -> 用 `clarify` 展示 Markdown 草稿 -> 用户点击 `同意并提交` -> `files upload`（有附件时）-> `instances create --yes`
- 处理审批：`tasks query` 拿 `instance_code` + `task_id`（操作必须成对带上）→ 只有用户明确需要查看详情、当前节点、表单内容或流程进度时，再 `instances get` → 执行操作

## 执行原则（减少误路由、误重试和无效消耗）

### 1）先拿最小必要信息，再执行

- 目标只是处理待办时，优先 `tasks query` 获取 `instance_code` + `task_id`。
- **只有**用户明确要看详情、当前节点、表单内容或流程进度时，才调用 `instances get`。
- 用户已明确给出 `instance_code` / `task_id` 时，不要先查列表再过滤。
- 当前 Turn 已有足够新鲜的查询结果时，不要重复查询。

### 2）已知对象时直达动作

- 已拿到 `instance_code` + `task_id` 后，优先直接执行 `tasks approve/reject/transfer/add_sign/rollback/remind`。
- 不要默认走 `list -> filter -> detail -> write` 全链路。
- 发起新审批必须执行“发起审批 SOP”。其他真实写操作按对应 reference 执行。

### 3）错误码驱动，不盲目重试

- 写操作失败或响应不明时，不得立即重复相同写操作。先看错误码和报错语义，再补查或结束。
- 只有本 Skill 或对应 reference 明确说明恢复方法，并且用户完成了所需操作后，才能按说明重试。

## 写操作失败处理：1395001 决策树

拒绝、转交、退回、撤回、同意等写操作返回 `1395001`（任务状态异常或写前置校验失败）时：

1. 不要重试相同写操作。
2. 优先检查：任务是否已被他人处理；单据状态是否已变化；当前 Turn 发起人是否仍有操作资格；当前节点是否支持该动作。
3. 如需确认，只补一次 `tasks query` 或 `instances get`。
4. 给用户明确结论和下一步。

拒绝、转交和撤回最容易遇到状态切换，必须严格按此规则处理。

```bash
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals approvals search --data '{"keyword":"请假"}'
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals approvals get --params '{"approval_code":"<code>"}'
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals tasks query --params '{"topic":"1"}'
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals tasks approve --data '{"instance_code":"<ic>","task_id":"<tid>","comment":"同意"}' --dry-run
```

## 上传审批附件或图片

只有用户在 `clarify` 卡片中点击 `同意并提交` 后，才能上传审批附件。接口返回 file code；创建实例时把 code 数组写入 `attachmentV2`、`image` 或 `imageV2` 控件的 `value`。

### 请求契约

- 方法和路径：`POST /open-apis/approval/v4/files/upload`
- 应用权限：`approval:approval` 和 `approval:instance.file`。这两个权限属于当前用户的 PersonalAgent app，不属于用户 OAuth scope；首次上传前，用户必须在飞书开发者后台同意并发布。
- Content-Type：`multipart/form-data`
- 身份：wrapper 使用当前 Turn 发起人的 profile，并以该 profile 所属 PersonalAgent app 的应用身份上传。它不使用继承的 Agent bot 凭据。不要手写 `Authorization`，不要传 `--as` 或 `--profile`。
- 一次请求只能上传一个文件；多个文件必须分别上传。
- `attachment` 最大 50 MB；`image` 最大 10 MB。
- 不要把旧示例中的 `/approval/openapi/v2/file/upload` 替换进本 Skill；Ankole wrapper 固定调用上面的 v4 路径。

如果接口返回 `99991672` 或 `app_scope_not_applied`，停止上传和提交，把错误中的开发者后台权限链接交给用户。用户确认权限已发布后，只重试这一个失败文件；不要重新上传已经成功的文件，也不要重试状态不明的提交。

multipart 请求体字段：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `name` | string | 是 | 文件名，必须包含扩展名，例如 `invoice.pdf` |
| `type` | string | 是 | `attachment` 或 `image`；必须与审批定义中的控件类型一致 |
| `content` | file | 是 | 文件内容；在 CLI 中必须显式写成 `--file content=<path>`，不能使用默认字段名 `file` |

`attachmentV2` 使用 `type=attachment`；`image` 和 `imageV2` 使用 `type=image`。

```bash
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals files upload --file content=./receipts/invoice.pdf --data '{"name":"invoice.pdf","type":"attachment"}' --format json
```

### 响应契约

| 字段 | 类型 | 说明 |
|---|---|---|
| `code` | int | `0` 表示成功；非 `0` 表示失败 |
| `msg` | string | 返回码说明 |
| `data.code` | string | 文件标识码；写入创建实例的图片或附件控件 `value` |
| `data.url` | string | 文件 URL，有效期 12 小时 |

```json
{
  "code": 0,
  "msg": "success",
  "data": {
    "code": "D93653C3-2609-4EE0-8041-61DC1D84F0B5",
    "url": "https://example.com/lark-approval-attachment/file"
  }
}
```

发起审批后，每次读取审批详情都会得到新的文件 URL。如果 URL 参数包含字面量 `\\u0026`，将它替换为 `&` 后再打开。提单依赖 `data.code`，不要依赖短期 URL。

控件值示例：

```json
{
  "id": "widget1",
  "type": "attachmentV2",
  "value": ["D93653C3-2609-4EE0-8041-61DC1D84F0B5"]
}
```

## 发起审批 SOP

用户要求发起任何新审批时，必须按以下顺序执行，包括请假、报销、出差、通用审批和带附件审批。普通审批只整理实际提供的字段和附件；报销审批还要分析发票或收据。

### 1）整理原始材料

- 保留原始上传文件，不覆盖或改名。
- 压缩包先列出目录，再解压到新建的 workspace 相对目录。可使用 `unzip`、`7z`、`unrar`、`tar` 等已安装工具。
- 发现绝对路径、通过 `..` 越界的路径或符号链接时，停止解压。
- 忽略 `__MACOSX`、`.DS_Store` 等归档元数据，但不得漏掉真实业务文件。
- 加密、损坏、格式不支持或解压后体积异常时，告诉用户具体问题，不猜密码，不继续提单。

### 2）逐文件分析

普通审批至少记录每个真实文件的原文件名、文件类型、用途和无法识别的问题。发票或收据还要记录：

- 原文件名
- 商户或开票方
- 日期
- 发票号或收据号
- 币种
- 含税总额
- 税额（文件中存在时）
- 建议费用类别
- 费用用途
- 无法识别的字段
- 疑似重复项

草稿必须提到每个真实业务文件。准备提交的文件列在“待上传附件”中；不能提交或仍有问题的文件列在“未解决项目”中。不得编造值。报销审批还要逐项复算总额，并确认总额等于明细金额之和。

### 3）读取真实审批定义

- 未给 `approval_code` 时，用 `approvals search` 搜索。多个定义都合理时，让当前用户选择。
- 用 `approvals get` 读取目标定义。`is_external=true` 时返回 `create_link`，不调用 `instances create`。
- 准备草稿前读取 [`lark-approval-instance-form-control-parameters.md`](references/lark-approval-instance-form-control-parameters.md) 和 [`lark-approval-instance-value-sourcing.md`](references/lark-approval-instance-value-sourcing.md)。用户点击 `同意并提交` 后，再读取 [`lark-approval-initiate.md`](references/lark-approval-initiate.md)。
- 按真实控件 `id`、`type`、选项值和节点规则映射材料。文件和对话无法提供的必填值必须向用户询问。
- 人员姓名唯一匹配当前 `auth status --verify` 返回的用户时，可使用该用户的 `open_id`。其他人员或部门无法从稳定 ID 唯一确定时，要求用户提供 `open_id` 或 `open_department_id`；不要把姓名、邮箱或另一个用户的上下文当成 ID。

### 4）用 `clarify` 展示草稿

使用当前用户的语言。把草稿写入 `clarify.question`。普通审批使用下面的格式：

```markdown
## 审批申请草稿

- 审批定义：<approval name>

### 表单值

- <field label>: <value>

### 审批人

- <approver>

### 抄送人

- 无

### 待上传附件

- <file>

### 未解决项目

- 无
```

报销审批使用下面的格式：

```markdown
## 报销申请草稿

- 审批定义：<approval name>
- 费用用途：<purpose>
- 币种：<currency>
- 合计：<total>

| # | 原文件 | 商户 | 日期 | 发票或收据号 | 金额 | 类别 | 备注 |
|---|---|---|---|---|---:|---|---|
| 1 | <file> | <merchant> | <date> | <number> | <amount> | <category> | <notes> |

### 表单值

- <field label>: <value>

### 待上传附件

- <file>

### 未解决项目

- 无
```

草稿末尾加上问题：“是否提交以上审批？如需修改，请在自定义输入框中填写修改意见。”

调用 `clarify` 时只提供两个选项：

```json
[
  {"label": "同意并提交", "description": "按以上内容正式发起审批。"},
  {"label": "取消申请", "description": "停止处理，不发起审批。"}
]
```

`clarify` 会自动显示自定义输入框，并在调用后结束当前回复。调用前和调用后都不得上传附件或创建审批实例。

用户选择 `取消申请` 时停止。用户填写修改意见时，按意见修改草稿，再次调用 `clarify`。定义、表单值、审批人、抄送人或附件发生变化时，也必须更新草稿并再次调用 `clarify`。

用户首次提出创建或提交审批，不表示用户已经同意草稿。用户选择审批定义、补充字段或替换附件，也不表示同意提交。只有 `同意并提交` 这一次点击才是同意。

### 5）用户同意后提交

- 只把草稿中列出的文件作为附件。报销时上传每个已分析的发票或收据，不要只上传外层压缩包。只有草稿明确列出压缩包本身时，才上传压缩包。
- 每个文件只调用一次 `files upload`，并按本文件中的请求契约传 `name`、`type` 和 `content`。除非用户修复并确认本文件所述的应用权限问题，否则上传失败或响应不明时不得重试。
- 保存每次成功响应的 `data.code`，并映射到对应控件。任一上传失败或响应不明时立即停止，不得静默省略附件，不得创建审批实例。
- 根据真实定义组装 `form`，把上传得到的 file code 放进对应控件。只在定义要求时添加节点审批人或抄送人。
- 调用一次 `instances create --yes`。
- 成功后返回 `approval_name`、`instance_code`、`instance_link`、初始状态和附件数量。报销审批还要返回提交总额。响应不明时先用只读查询确认结果，不得重复提交。

## 不在本 Skill 范围

不创建审批定义；这类操作走飞书客户端或审批管理后台。三方定义只返回 `create_link`。非审批类任务走 `lark-oa`。本 Skill 不引入面向单个主人的长期“我的联系人”或“我的部门”假设；每次都以当前 Turn 发起人为边界。
