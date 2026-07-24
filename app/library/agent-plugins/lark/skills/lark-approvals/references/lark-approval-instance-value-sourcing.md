# 审批提单值来源

## 目的

本文用于回答一个固定问题：在调用 `approval instances create` 发起原生审批实例时，**每个要填写的值从哪里拿**。

使用本文前先读取 `approval approvals get` 返回的 `form` / `node_list`，并结合
[`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md)
确认各控件的结构。用户点击 `同意并提交` 后，再按
[`lark-approval-initiate.md`](./lark-approval-initiate.md) 创建审批实例。

## 总原则

- `lark-approval-initiate.md` 决定创建请求字段名、字段层级、节点参数结构。
- `approvals.get.form` 决定控件 `id`、`type`、选项值范围、子控件结构。
- `approvals.get.node_list` 决定节点 key、是否必须补审批人、是否允许多人。
- [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 决定各控件 `value` 的最终结构。
- 除非本文明确允许，否则不要猜值来源，不要把展示文案直接当成可提交值。

## 默认来源

- 审批定义、`approval_code`、`is_external`、`create_link` 等基础信息，默认从 `approval approvals search` 获取。
- 控件 `id`、`type`、选项值、子控件结构，默认从 `approval approvals get.form` 获取。
- 节点 key、`need_approver`、`approver_chosen_multi` 等节点信息，默认从 `approval approvals get.node_list` 获取。
- 本文只补充 **这些默认来源之外** 的取值规则，以及当前必须由用户直接提供的值。

## 控件值来源规则

### 联系人 `contact`

- 只推荐写 `open_ids`。
- 不再推荐双写 `value(user_id)` + `open_ids`，避免复杂度继续上升。
- Ankole 当前没有可按姓名、邮箱或账号搜索人员的 user-profile 联系人能力。
- 当前上下文已有唯一、稳定的 `open_id` 时可直接使用；否则向当前 Turn 发起人询问。不要猜测，不要复用另一个用户的人员上下文。

### 部门 `department`

- 最优先：用户直接提供 `open_department_id`。
- 当前上下文已有唯一、稳定的 `open_department_id` 时可直接使用。
- 若用户只说“我的部门”或某人的部门，要求当前 Turn 发起人提供或选择 `open_department_id`。不要把数字同事服务的其他用户或其他 Turn 的部门当作默认值。

### 附件 `attachmentV2`

- 用户已提供 file code 时可直接使用。
- 用户提供本地文件时，先把文件列入 Markdown 草稿。只有用户在 `clarify` 卡片中点击 `同意并提交` 后，才按 `SKILL.md` 的“上传审批附件或图片”契约调用 wrapper：`type=attachment`，文件字段必须是 `content`，并传包含扩展名的 `name`。
- 一次只上传一个文件。成功后使用响应中的 `data.code`。

### 图片 `image` / `imageV2`

- 用户已提供 file code 时可直接使用。
- 用户提供本地图片时，先把文件列入 Markdown 草稿。只有用户在 `clarify` 卡片中点击 `同意并提交` 后，才按 `SKILL.md` 的“上传审批附件或图片”契约调用 wrapper：`type=image`，文件字段必须是 `content`，并传包含扩展名的 `name`。
- 一次只上传一个文件。成功后使用响应中的 `data.code`。

### 文档 `document`

- 用户可直接提供 `token` / `document_id`。
- 如果用户给的是飞书文档链接，应先尝试从链接中提取 token。
- 若链接提取失败，再要求用户手动输入 token。

### 关联审批 `connect`

- 用户直接提供目标审批实例的 `instance_code`。
- 当前不默认做“搜索关联实例再反查 code”的自动流程。

### 地址 `address`

- 用户直接提供地理库 `id`。
- 若用户无法提供该 `id`，当前不支持自动取值。

## 特殊控件组

以下控件组的结构仍按 [`lark-approval-instance-form-control-parameters.md`](./lark-approval-instance-form-control-parameters.md) 组装：

- `leaveGroupV2`
- `workGroup`
- `outGroup`
- `shiftGroup`

补充规则：

- 控件组自身和子控件的 `id` / `type` 从 `approval approvals get.form` 中识别。
- 组内单选/多选或业务枚举值，优先从 `approval approvals get.form` 返回的选项结构中取。
- 不要把控件组整体当成普通字符串或扁平对象提交。

## 不支持自动准备的值

以下值当前不建议由 `lark-approval` 自动准备：

- 地址控件的地理库 `id`
- 无法唯一确定的部门 `open_department_id`

遇到这类值时，应明确告诉用户需要提供什么，而不是继续猜测。

## 最小决策表

| 场景 | 处理 |
|---|---|
| 用户说“找张三当审批人”但没有稳定 ID | 要求当前 Turn 发起人提供张三的 `open_id` |
| 用户说“我的部门”但没有稳定 ID | 要求当前 Turn 发起人提供或选择 `open_department_id` |
| 用户给了文档链接 | 先尝试提取 token |
| 用户给了图片或附件文件 | 按 `SKILL.md` 的上传契约逐个上传并取 `data.code` |
| 用户要填关联审批 | 要求直接提供 `instance_code` |
| 用户要填地址 | 要求直接提供地理库 `id` |
