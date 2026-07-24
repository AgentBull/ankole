
# approval approvals search

搜索**当前用户可发起**的审批定义（launchable approvals）。只读操作，不会创建审批实例。

需要的 scopes: ["approval:approval:read"]

## 命令

```bash
# 按关键词搜索可发起审批定义
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals approvals search --data '{"keyword":"请假"}'

# 使用 page_token 翻页
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals approvals search --data '{"keyword":"请假", "page_token":"example_page_token"}'

# 表格格式输出，便于快速浏览候选定义
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals approvals search --data '{"keyword":"出差"}' --format table

# 预览 API 调用，不执行
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals approvals search --data '{"keyword":"请假"}' --dry-run
```

## 参数

| 参数 | 必填 | 说明 |
|------|------|------|
| `--data '{...}'` | 是 | 查询参数，使用 JSON 传入 |
| `keyword` | 是 | 搜索关键词，例如 `请假`、`报销`、`出差`、`采购` |
| `locale` | 否 | 返回语言，例如 `zh-CN`、`en-US`、`ja-JP` |
| `page_size` | 否 | 分页大小 |
| `page_token` | 否 | 翻页标记；首次请求不填，后续使用上一次返回的 `page_token` |
| 用户身份 | 自动 | wrapper 固定使用当前 Turn 发起人的 user profile；不要传 `--as` 或 `--profile` |
| `--format` | 否 | 输出格式：`json`（默认）、`ndjson`、`table`、`csv` |
| `--dry-run` | 否 | 预览 API 调用，不执行 |

## 这个命令解决什么问题

当用户只有自然语言意图，还没有 `approval_code` 时，先用它把“可发起的审批定义候选项”找出来。

典型场景：

- “帮我找一下请假审批”
- “有哪些可以发起的报销单？”
- “先搜一下出差审批，再帮我提单”

## 输出重点字段

返回结果里，优先关注以下字段：

| 字段 | 说明 |
|------|------|
| `approval_code` | 审批定义 Code；后续 `approvals get` 和 `instances create` 都要用它 |
| `approval_name` | 审批定义名称；给用户做候选选择时最关键 |
| `is_external` | 是否为三方审批定义；`true` 表示不能走原生 `instances.create` |
| `create_link` | 三方审批定义的发起链接；`is_external=true` 时优先返回给用户 |

## 使用规则

- **这是“发起审批 SOP”的第一步。** 标准顺序是：`approvals search` -> `approvals get` -> 用 `clarify` 展示 Markdown 草稿。用户点击 `同意并提交` 后，才能创建审批实例。
- **搜索结果为空时，不要猜。** 直接告诉用户当前关键词下没有可发起定义，并建议用户换关键词。
- **命中多个结果时，不要替用户拍板。** 先把候选定义列出来，让用户选择目标审批定义。
- **`is_external=true` 时不要调用 `approval instances create`。** 这类定义属于三方审批，优先返回 `create_link` 并说明需要通过链接发起。
- **只有 `is_external=false` 的原生定义，才继续 `approvals get`。**
- **如果用户已经明确给出 `approval_code`，不要再 search。** 直接执行 `approval approvals get`。

## 结果整理方式

**将结果整理为候选清单，优先展示“名称 + approval_code + 是否三方定义 + 下一步建议”。**

建议输出成下面这种结构：

```text
找到 3 个可发起审批定义：

1. 请假申请
   - approval_code: 7C468A54-8745-2245-9675-08B7C63E7A85
   - is_external: false
   - next: 可继续读取 definitions 详情（approvals get）

2. 差旅报销
   - approval_code: 99887766-xxxx
   - is_external: true
   - next: 返回 create_link，引导用户通过链接发起
```

## 常见后续操作

### 1）用户选中了某个定义，继续查看详情

```bash
/repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals approvals get --params '{"approval_code":"<APPROVAL_CODE>"}'
```

### 2）确认是原生定义后，准备审批草稿

按照 `SKILL.md` 的“发起审批 SOP”读取表单和节点，整理 Markdown 草稿，再调用 `clarify`。

### 3）确认是三方定义时，直接返回链接

当 `is_external=true` 时，优先向用户返回 `create_link`，说明该审批需在三方系统或跳转页面中发起，而不是通过原生 `instances.create`。
