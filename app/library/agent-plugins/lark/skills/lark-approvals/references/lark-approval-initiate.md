# 创建审批实例

## 执行摘要

- **只在当前输入是 `clarify` 卡片的结构化选择，且 `Selected value` 是 `同意并提交` 时，才能上传附件和创建审批实例。**
- **普通文字消息不是按钮选择。** 即使文字是“同意并提交”“确认”或“直接提交”，也必须重新执行 `SKILL.md` 中的“发起审批 SOP”。
- **没有 `approval_code` 时先用 `approvals search` 查找定义。提交前必须用 `approvals get` 读取真实审批定义，并用 `clarify` 向用户展示完整 Markdown 草稿。**
- **`is_external=true` 的定义是三方定义。** 这类定义不要调用 `instances create`，应优先使用 `create_link`。
- **所有人员类参数默认使用 `open_id`。** 人员姓名唯一匹配当前 `auth status --verify` 返回的用户时，可使用该用户的 `open_id`。Ankole 当前没有可按其他姓名或邮箱搜索人员的 user-profile 联系人能力；其他人员没有唯一、稳定的 `open_id` 时，向当前 Turn 发起人询问，不要猜测或复用其他用户的人员信息。
- **组装表单时必须同时使用本文、[`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 和 [`lark-approval-instance-value-sourcing.md`](./lark-approval-instance-value-sourcing.md)。**
- **`approvals.get.form` 不是创建 payload 的原样模板。** 它主要用于识别控件 `id`、`type`、选项值范围和明细子控件结构；真正的 `instances create --data.form` 中，控件 `value` 结构以 [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 为准。
- **节点参数只从 `node_list` 和本文里的节点参数规则里取。** 节点 key 必须来自定义详情返回的节点标识；审批人/抄送人列表传用户 ID 时，不要混用姓名或其他身份标识。
- **看到 `need_approver=true` 就说明该节点需要发起人补充审批人。** 如果 `approver_chosen_multi=false`，该节点只允许一个 `open_id`。
- **每次点击 `同意并提交` 最多调用一次 `instances create --yes`。** 响应不明时先查询结果，不得重试提交。

## 使用前提

本文件只说明用户点击 `同意并提交` 后如何创建审批。准备材料和请求用户确认时，不要读取或执行本文件中的创建命令。

只有下面的条件全部成立时才能继续：

1. 上一条 Agent 回复通过 `clarify` 展示了完整 Markdown 草稿。
2. 当前输入包含系统生成的 `The user invoked a structured card action.`。
3. 紧随其后的 `Selected value` 是 `同意并提交`。
4. 当前操作人与请求审批的用户是同一个 Principal。

任一条件不成立时，返回 `SKILL.md` 的“发起审批 SOP”，不得上传附件或创建审批实例。

## 适用场景

- “帮我提交一个请假审批”
- “帮我发起报销审批”
- “我想提一个出差审批”
- “先搜可发起的审批，再帮我提单”

## 严禁行为

- **严禁在未先阅读本文中的创建参数规则、[`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 和 [`lark-approval-instance-value-sourcing.md`](./lark-approval-instance-value-sourcing.md) 的情况下直接提单。**
- **严禁跳过 `approvals.get`。** 未拿到 `form` 和 `node_list` 前，不得调用 `instances create`。
- **严禁把姓名直接写进 `node_approver_list`、`node_cc_list` 或表单人员控件。** 必须先转成 `open_id`。
- **严禁对三方定义调用 `instances create`。**
- **严禁对 API 不支持的控件硬提单。** 如果目标定义包含创建实例 API 不支持的控件，应明确告诉用户该定义不能仅通过 API 完整发起。
- **严禁把 `approvals.get.form` 当成可直接提交的原样模板。**

## 工作流

### 1. 搜索可发起审批定义

先搜索定义：

```bash
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals approvals search --data '{"keyword":"请假"}'
```

处理规则：

- 若结果为空，告诉用户当前关键词下没有可发起定义。
- 若命中多个定义，必须把候选项列给用户选择，不要自行猜测。
- 若目标定义 `is_external=true`，优先返回 `create_link`，说明这是三方定义，不能走原生 `instances create`。
- 只有 `is_external=false` 的原生定义才继续下一步。

### 2. 获取审批定义详情

拿到 `approval_code` 后，读取定义详情：

```bash
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals approvals get \
  --params '{"approval_code":"7C468A54-8745-2245-9675-08B7C63E7A85"}'
```

重点关注返回：

- `approval_name`: 当前发起的是哪个审批定义。
- `form`: 表单定义快照，用于识别控件 `id`、`type`、选项值范围以及明细子控件结构；不是创建实例时可直接原样提交的 payload 模板。
- `node_list`: 流程节点信息，是后续 `node_approver_list` / `node_cc_list` 的唯一可靠来源。

### 3. 创建请求参数速查

输入参数如下：

| 参数 | 必填 | 说明 |
|---|---|---|
| `--data '{...}'` | 是 | 请求体，使用 JSON 传入 |
| `approval_code` | 是 | 审批定义 Code；必须先通过 `approvals search` / `approvals get` 确认 |
| `form` | 否 | 表单值，**JSON 数组字符串**，不是普通对象；API 层非必填，但审批定义存在必填控件或用户需要提交表单值时必须传 |
| `node_approver_list` | 否 | 节点审批人列表；仅在定义要求补充审批人时传 |
| `node_cc_list` | 否 | 节点抄送人列表；仅在用户明确需要补充节点抄送人时传 |
| `uuid` | 否 | 幂等标识；重复重试同一请求时建议显式传入 |
| 用户身份 | 自动 | wrapper 固定使用当前 Turn 发起人的 user profile；不要传 `--as` 或 `--profile` |
| `--yes` | 是 | 执行创建请求 |

### 4. 组装 `form`

`instances create --data.form` 是可选字段；传入时必须是一个 JSON 数组字符串。无表单或无需填写表单值的审批可省略 `form`，但只要审批定义包含需要提交的控件，就必须按控件结构组装后传入。组装原则：

- 先用 `approvals.get.form` 识别有哪些控件、每个控件的 `id` / `type` / 可选值范围，再按本文中的创建参数规则与 [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 重新组装创建 payload。
- 提交时必须至少保证每个控件的 `id`、`type` 与 `value` 符合当前接口要求；不要假设定义快照里出现的其他字段都能直接照搬。
- 如果用户提供的是人员信息，优先转换成 `open_id` 后再写入对应控件。
- 单选/多选控件提交的是选项 `value`，该值可从 `approvals.get.form` 的选项定义中取得。
- `contact`、`department`、`fieldList`、`dateInterval`、`amount`、`telephone`、`document` 等控件的 `value` 结构各不相同，必须按 [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 单独组装，不要套用文本控件的写法。
- 值本身从哪里拿，优先按 [`lark-approval-instance-value-sourcing.md`](./lark-approval-instance-value-sourcing.md) 处理；不要把“知道结构”误当成“已经拿到可提交值”。
- 若 [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 标明某控件不支持通过创建实例 API 提交，则不要硬猜绕过；应明确告诉用户该定义当前无法仅通过 API 提单。
- 若遇到当前 skill 未明确覆盖的复杂控件，不要硬猜；先依据 [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 判断支持性与传值结构，再向用户确认。

## API 不支持的控件

根据 [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md)，创建审批实例 API 不支持的控件至少包括：

- `text`
- `mutableGroup`
- `account`
- `serialNumber`
- `tripGroup`
- `apaascorehrOnboardingGroup`
- `apaascorehrRegularateGroup`
- `remedyGroupV2`
- `apaascorehrJobAdjustGroup`
- `apaascorehrOffboardingGroup`

如果目标审批定义包含上述控件，不要继续硬拼 `form`；应直接告诉用户该定义不能仅通过当前 API 完整提单。

## 高频控件速查

优先按 [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 组装，下面只保留最常用、最容易出错的格式：

- `input` / `textarea`: `value` 是字符串
- `date`: `value` 是 RFC3339 时间字符串
- `dateInterval`: `value` 是对象，包含 `start` / `end` / `interval`
- `radio` / `radioV2`: `value` 是单个选项值，取定义详情里的 `option.value`；关联外部选项时传 `options.id`
- `checkbox` / `checkboxV2`: `value` 是选项值数组
- `number`: `value` 是数字
- `amount`: `value` 是数字，还要带 `currency`
- `formula`: `value` 必须与定义中的公式结果匹配，否则会报错
- `contact`: 只推荐写 `open_ids`，由人员信息先转换成 `open_id`
- `connect`: `value` 是关联审批实例 `instance_code` 数组，当前默认要求用户直接提供 `instance_code`
- `document`: `value` 是对象，至少含 `token` 和 `type=docx`
- `attachmentV2` / `image` / `imageV2`: `value` 是 file code 数组；用户点击 `同意并提交` 后，才按 `SKILL.md` 的“上传审批附件或图片”契约逐个上传，再使用返回的 `data.code`
- `fieldList`: `value` 是二维数组，子项继续按各自控件类型组装
- `department`: `value` 是对象数组，元素字段名为 `open_id`，其值填写部门的 `open_department_id`
- `telephone`: `value` 是对象，包含 `countryCode` 和 `nationalNumber`
- `address`: `value` 是对象数组，至少包含地理库 `id`，可选 `detailAddress`；当前默认要求用户直接提供该 `id`

## 特殊控件组

[`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 还明确给出了若干特殊控件组的提单格式，至少包括：

- `leaveGroupV2`
- `workGroup`
- `outGroup`
- `shiftGroup`

这类控件组不是简单文本控件，通常内部还嵌套 `radioV2`、`date`、`fieldList`、`image`、`contact` 等子控件。遇到这些控件组时：

- 先从 `approvals.get.form` 找到控件组及其子控件 ID
- 再严格按 [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 的示例组装 `value`
- 不要把控件组整体当成普通字符串或扁平对象提交

### 5. 组装节点参数

从 `node_list` 推导节点参数：

- 若某节点 `need_approver=true`，则必须在 `node_approver_list` 中补该节点的审批人。
- `key` 优先取 `custom_node_id`；若不存在，再用 `node_id`。
- `value` 是审批人 `open_id` 列表。
- 若 `approver_chosen_multi=false`，该节点只允许一个审批人 `open_id`。
- `node_cc_list` 仅在用户明确需要补充节点抄送人时才填写；其 `key/value` 规则与 `node_approver_list` 相同。

### 6. 创建审批实例

创建命令使用 `instances create`，需要的 scopes: ["approval:instance:write"]

只有“使用前提”中的四个条件全部成立时，才能执行下面的命令：

```bash
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals instances create \
  --data '{
    "approval_code":"7C468A54-8745-2245-9675-08B7C63E7A85",
    "form":"[{\"id\":\"widget1\",\"type\":\"input\",\"value\":\"请假半天\"}]",
    "node_approver_list":[
      {
        "key":"manager_node_id",
        "value":["ou_xxx"]
      }
    ]
  }' \
  --yes
```

执行规则：

- 只提交用户在 `clarify` 卡片中看到的表单值、审批人、抄送人和附件。
- 调用一次 `instances create --yes`。
- 若需要幂等，可补 `uuid`。
- 成功后回报 `instance_code` 与 `instance_link`。
- 响应不明时，先用只读查询确认是否创建成功，不得重复提交。

## 组装时优先依据的资料

优先级固定如下：

1. 本文中的创建请求参数、节点参数和返回结果说明：决定 `instances create` 要传哪些字段、怎么执行、成功后回什么。
2. [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md)：决定每种控件的 `value` 结构与支持范围。
3. [`lark-approval-instance-value-sourcing.md`](./lark-approval-instance-value-sourcing.md)：决定每类值应该从哪里拿，以及当前哪些值必须由用户直接提供。
4. `approvals.get.form`：提供当前审批定义里实际有哪些控件、控件 `id`、控件 `type`、选项值范围、明细子控件结构。
5. `approvals.get.node_list`：提供节点 key 与是否需要补充审批人/抄送人的线索。

不要反过来把 `approvals.get.form` 当成第一优先级，更不要把它当成可直接提交的 JSON 模板。

## 最小判断表

| 你手上有什么 | 下一步 |
|---|---|
| 只有口语需求，比如“帮我提个请假审批” | 先 `approvals.search` |
| 已经拿到 `approval_code` | 直接 `approvals.get` |
| 已拿到 `form` / `node_list`，且用户已给出表单值和审批人 | 按 `SKILL.md` 调用 `clarify` 展示 Markdown 草稿 |
| “使用前提”中的四个条件全部成立 | 上传草稿中的附件，再执行一次 `instances create --yes` |
| `is_external=true` | 返回 `create_link`，不要调 `instances create` |

## 返回结果

完成创建后，至少向用户返回：

- `approval_name`
- `instance_code`
- `instance_link`

建议整理为下面这种结构：

```text
审批已创建成功：

- approval_name: 请假申请
- instance_code: 19EAC829-F1CB-527F-BE2A-1330422E60C0
- instance_link: https://...
```
