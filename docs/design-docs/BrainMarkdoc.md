# Brain 正文语法与 Object 编辑

Brain Object 正文使用 CommonMark、块级 `audience` 标签和 `[[slug]]` 内部链接。
native kernel 的 `brain_markdoc` 模块拥有规范语法：comrak 解析 Markdown
结构，`brain_markdoc` 在这些结构边界上识别标签。控制面通过一个 NIF 调用它，
校验作用域并裁剪读取结果。Console 的本地分段只用于预览，不能决定写入或披露。

## 正文契约

数据库 `brain_objects.body` 只保存正文。`slug`、`type`、`subtype`、`title`、
`meta` 和 `effective_date` 由结构化字段拥有，正文没有 frontmatter 概念。

### `audience` 标签

唯一的标签是块级 `audience`：

```markdoc
{% audience scope="principal:alice" %}
Only Alice can read this.
{% /audience %}
```

- 开标签是 `{% audience scope="..." %}`，闭标签是 `{% /audience %}`。
  标签行必须顶格并独占一行，行尾允许空白，前后不要求空行。
- 标签必须配对，不能嵌套。标签外的文本属于 `world`。每个 segment 只有
  一个作用域，对应分块后的 `brain_chunks.audience_scope`。
- fenced code、indented code 和 inline code 中的标签文本是代码，不是标签。
- scope 形状是 `world`、`group:<name>` 或 `principal:<uid>`，由
  `Ankole.Brain.Scope` 校验。scope 是否存在、写入者是否有权使用它，由控制面
  在数据库事务内校验。`world` 只覆盖当前租户，详见 [BrainV3](BrainV3.md)。
- 未被识别为标签行、也不在代码范围内的 `{% audience` 或
  `{% /audience` 候选文本返回 `misplaced_audience_tag`。这包括行中间、
  heading、blockquote、list 和 HTML block 中的标签。写入拒绝歧义输入。

以下闭标签在 fenced code block 内，不能结束保密块：

````markdoc
{% audience scope="principal:alice" %}
private
~~~markdoc
{% /audience %}
~~~
tail that must stay private
````

规范解析器返回 `unclosed_audience_tag`，写入被拒绝。读取无法解析的正文时，
`GetPage` 返回空正文，不能把尾部文本当作 `world` 内容披露。

### `[[slug]]` 内部链接

`[[companies/minghu-ai]]` 是内部页面链接；`[[目标|标题]]` 取 `|` 前的部分
为目标。comrak 的 `wikilinks_title_after_pipe` 扩展识别链接，Dreaming
将它物化为 link 边。代码块和 inline code 中的 `[[...]]` 不产生链接。

## 规范解析器

实现位于 `app/kernel/src/brain_markdoc/mod.rs`，语法测试位于同目录的
`tests.rs`。Cargo feature `brain_markdoc = ["dep:comrak"]` 使用关闭默认
features 的 comrak，包含在 `nif` 中。

### NIF 契约

`brain_markdoc_analyze_nif` 接收 UTF-8 正文，返回 JSON 字符串。公开包装函数
`Ankole.Kernel.brain_markdoc_analyze/1` 用 `Torque.decode!` 解码为 map。
NIF 在 DirtyCpu 调度器运行，不启动独立进程。

成功结果：

```json
{"segments": [{"scope": "world", "text": "..."},
              {"scope": "principal:alice", "text": "..."}],
 "wikilinks": ["companies/minghu-ai"]}
```

语法错误也是正常返回的数据：

```json
{"error": {"code": "unclosed_audience_tag", "line": 12}}
```

错误码是 `nested_audience_tag`、`unopened_audience_tag`、
`unclosed_audience_tag` 和 `misplaced_audience_tag`；`line` 从 1 开始。
原生边界不能分析或编码输入时，NIF 调用失败，不把失败当作有效正文。

### 分析过程

1. comrak 解析全文并开启 wikilink 扩展。解析器收集 `CodeBlock`、`Code`
   和 `HtmlBlock` 的 sourcepos，以及 `WikiLink` 的目标。
2. 逐行识别顶格且独占一行的标签。位于代码或 HTML block 内的行不成为标签行。
3. 逐一检查 audience 候选文本；未落在标签行或代码范围内的候选返回
   `misplaced_audience_tag`。
4. 按文档顺序配对标签。segment 使用标签之间的原始字节切片，保留空白；
   标签外的文本形成 `world` segment。
5. 链接目标按文档顺序 trim、剔除空值并去重。

comrak 提供结构范围和 wikilink 事实，`brain_markdoc` 提供 audience 语法。
AST、segment 和诊断不持久化，也不缓存；读取直接调用解析器。

### 控制面接口

`Ankole.Brain.Markdoc` 调用规范解析器，并提供以下接口：

| 接口 | 行为 |
| --- | --- |
| `segments/1` | 校验 scope，将语法错误映射为 atom，剔除纯空白 segment |
| `scopes/1` | 返回正文使用的不同作用域 |
| `prune/2` | 按 `keep?` 保留原始 segment，为保留的 scoped segment 重加标签，保持作用域 |
| `wrap/2` | 为非 `world` 正文加一对规范标签；`world` 正文原样返回 |
| `wikilinks/1` | 返回内部链接目标；无效正文返回空列表 |
| `diagnostic/1` | 返回供编辑器使用的原生语法错误码和行号 |

Objects 校验写入作用域并按 segment 分块。GetPage 按读取与披露边界裁剪正文，
无效正文投影为空。SourceLearning 和 Synthesis 等派生正文写入器通过 `wrap/2`
保留来源作用域。

## Console 创建与编辑

### 正文所有权

`managed_by_source_id` 表示正文由一个 Brain Source 拥有。SourceLearning
使用受 Source 身份约束的内部 upsert 路径；普通 Object 更新拒绝 managed
正文。服务端返回 `editable` 和 `edit_block_reason`，Console 据此选择操作。

| 状态 | 正文操作 | 引导 |
| --- | --- | --- |
| 租户自有且未删除 | 创建、编辑、保存 | `Objects.create_object/3` 或 `Objects.update_object/4` |
| 已删除 | 只读 | 先恢复，再编辑 |
| SourceLearning media 投影 | 只读 | 打开 Source 重新学习或归档 |
| `agent-skills` 投影 | 只读 | 打开 Agent Library |

### Console API

以下路径相对于 `/api/v1`。Object slug 可包含 `/`，创建和更新在请求 body
中携带 slug。

| 方法与路径 | 用途 | 关键输入或输出 |
| --- | --- | --- |
| `GET /brain/objects/show?slug=...` | 加载详情和编辑基线 | raw `body`、`content_hash`、`editable`、`edit_block_reason` |
| `POST /brain/objects` | 创建租户自有 Object | slug、type、subtype、title、body、meta、effective_date |
| `PUT /brain/objects` | 更新租户自有 Object | slug、可变字段、`expected_content_hash` |

创建和更新要求 `brain:update`；raw body 只在 `brain:read` 管理边界返回。
语法错误返回 422，包含错误码和正文行号；content hash 冲突返回 409。

### 编辑器行为

Console 使用 `/brain/objects/new` 和 `/brain/objects/:slug/edit` 全页路由。
源码输入使用 textarea。`previewBrainObjectBody` 用本地 fence 状态和标签行
识别生成预览 segment，`MarkdownBody` 渲染正文并显示 scope badge；
`[[slug]]` 在预览中显示为字面文本。

本地分段只服务预览。保存时服务端重新分析全文；预览与服务端不一致时，以服务端
结果为准。Problems 区显示服务端的语法错误和行号。

保存携带加载时的 `expected_content_hash`。409 时保留本地草稿；操作员可加载
最新版本对比并更新保存基线，不自动覆盖正文。离开有未保存修改的页面时提示。
并发基线覆盖同次保存替换的 title、body、meta、subtype 和 effective_date；检索、
embedding 等派生状态不改变它。升级会转换已有基线，升级前打开的草稿可能需要
重新加载最新基线。已删除页的普通保存和版本回滚在持有 Object 锁时拒绝，返回
`object_deleted`；必须先显式恢复。历史版本仍只回滚 body 和 meta。

保存及对比结果只属于发起操作的本次编辑页。离开后请求仍可完成服务端写入和
全局查询刷新，但迟到结果不改变之后打开的草稿、错误状态或导航。
创建可填写 slug、type、subtype、title、effective_date 和 meta；编辑时 slug
和 type 只读。

存储中存在无效正文时，管理员可通过 raw body 编辑修复。普通读取继续返回空正文，
写入继续拒绝无效语法，不通过兼容解析器绕过边界。

## 实现边界

- 只支持上述 audience 标签和 wikilinks，不实现完整 Markdoc 的变量、函数、
  条件、partial、annotation、inline tag 或嵌套标签。
- 规范解析由进程内 NIF 提供。Console 预览不能替代服务端解析或权限校验。
- 正文按输入保存，不提供 formatter。编辑器没有 WYSIWYG、CodeMirror 或语法高亮。
- Object 编辑器不提供按 Principal 预览正文的端点。真实披露通过目标 Principal
  的读取路径验证；检索预览属于独立的 recall 管理功能。
- `GetPage.rendered` 保持裁剪后的拼接投影。无效正文不通过迁移或运行时 fallback
  获得宽松解释。

## 参考

- comrak：<https://docs.rs/comrak>。
- Markdoc 标签语法形状：<https://markdoc.dev/docs/tags>。
