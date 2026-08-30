# Brain 正文语法与 Object 运行时编辑设计

状态：已实现

## 结论

Brain Object 正文的规范语法是：CommonMark，加一个块级 `audience` 标签（借用
Markdoc 的标签语法形状），加 `[[slug]]` 内部链接。这个语法只有一个 owner：
native kernel 的 `brain_markdoc` 模块。它用 comrak（CommonMark 规范级 Rust
实现）解析块结构，在其上做一层薄的标签识别。控制面通过一个 NIF 函数调用它；
系统里不存在第二个解析器。

替换前的 `Ankole.Brain.Markdoc` 用三个正则表达式在扁平字符串上扫描标签。它没有
块结构概念，分不清标签行和代码块里的代码文本，并且对歧义静默接受。这造成一个
已确认的越权披露 P0。它必须被原子替换，不能加补丁，也不能保留为 fallback。

本设计不引入 `@markdoc/markdoc`、不引入任何 JavaScript 运行时、不引入独立
进程。一次解析就是一次进程内的 NIF 调用，故障语义与其他 kernel 原语相同。

交付分两个 commit，各占一个 changelog 版本：

1. 服务端语法原子替换（安全修复，第一阶段）。
2. Console 创建与编辑 Object（新能力，第二阶段）。

## 已确认的 P0 泄漏路径

以下正文中的 `audience` 结束标签位于 fenced code block 内。按块结构，它是
代码文本，不是标签：

````markdoc
{% audience scope="principal:alice" %}
private
~~~markdoc
{% /audience %}
~~~
tail that must stay private
````

正确的解析把 fence 内那一行当作代码，于是文档只剩一个未闭合的开标签，写入
必须被拒绝。当前正则扫描器却把它当成真实结束标签，使后面的文本成为 `world`
segment：写入校验通过，检索分块和页面裁剪随后把本应属于 `principal:alice`
的尾部内容暴露给无权 Principal。

同类错误还出现在 inline code、缩进代码和其他块结构中。继续扩充正则表达式
不能建立可靠边界。

## 根因

1. **语法实现没有块结构。** `audience` 是块级构造，实现却做扁平字符串匹配。
   "一个字符串是不是标签"取决于它所在的块上下文，而块上下文只能由 CommonMark
   级解析器回答。
2. **对歧义静默接受。** 解析器不能确定含义的位置，正确行为是拒绝写入。
   `audience` 决定保密边界，猜错直接改变披露范围。
3. **同一正文有多种解释。** 控制面按正则解释 scope，Console 按 Markdown
   渲染。替换后两者共享同一规范语法，服务端是唯一权威。

## 正文契约（规范语法）

数据库 `brain_objects.body` 只保存正文。`slug`、`type`、`subtype`、`title`、
`meta` 和 `effective_date` 由结构化字段拥有，正文不得重复声明。正文没有
frontmatter 概念；`.okf` 文件导入器在调用解析前剥离 frontmatter（现状不变）。

### `audience` 标签

唯一的标签是块级 `audience`：

```markdoc
{% audience scope="principal:alice" %}
Only Alice can read this.
{% /audience %}
```

规则：

- 开标签 `{% audience scope="..." %}`，闭标签 `{% /audience %}`。语法形状与
  Markdoc 块级标签一致，将来需要更多标签时可以迁移到完整 Markdoc。
- 标签行必须顶格（第 0 列）并独占一行，行尾允许空白。标签行前后不要求空行。
- 代码块（fenced 或 indented）内的标签文本是代码，不是标签。
- 标签必须配对，不能嵌套，只能在 document root 层。标签外的文本是 `world`。
  一个 segment 只有一个 scope，对应一个 `brain_chunks.audience_scope`。
- scope 形状是 `world`、`group:<name>` 或 `principal:<uid>`，由
  `Ankole.Brain.Scope` 校验（现状）。scope 是否存在、写入者是否有权使用它，
  仍由控制面在数据库事务内校验（现状）。
- 在上述位置之外出现的任何 `{% audience` 或 `{% /audience` 子串——行中间、
  heading、blockquote、list、HTML block、多行段落——都是
  `misplaced_audience_tag` 校验错误，阻止写入。语法不能确定含义的位置一律
  拒绝，不猜。

### `[[slug]]` 内部链接

`[[companies/minghu-ai]]` 是内部页面链接；`[[目标|标题]]` 形式取 `|` 前的
部分为目标。这是现存契约：Dreaming 把它物化为 link 边，部署实例的存量正文
包含它，必须保留。

解析改由 comrak 的 wikilink 扩展承担（`wikilinks_title_after_pipe`），从
AST `WikiLink` 节点取目标。代码块和 inline code 里的 `[[...]]` 不再产生
链接。链接抽取没有保密语义——误差只影响关系边，不影响披露——但同一个解析器
顺带把它做对。

## 语法所有者：kernel `brain_markdoc`

实现位置与模式照抄 `program_runner`：

- `app/kernel/Cargo.toml`：新增 optional 依赖 `comrak`
  （`default-features = false`），新 feature `brain_markdoc = ["dep:comrak"]`，
  加入 `nif_dev` 和 `nif_prod` 的 feature 列表。
- `app/kernel/src/brain_markdoc/mod.rs` 加同目录 `tests.rs`，在 `lib.rs` 按
  `program_runner` 的方式 feature-gate，在 `nif_exports` 注册。
- 编辑 NIF 边界前先读 `.agents/skills/elixir-rust-nif-coding/SKILL.md`。

### NIF 契约

kernel 只暴露一个函数：

```elixir
@spec brain_markdoc_analyze_nif(binary()) :: result(String.t())
```

输入正文 UTF-8 binary，输出 JSON 字符串；Elixir 侧公开包装函数
`Ankole.Kernel.brain_markdoc_analyze/1` 负责 `Torque.decode`，模式照抄
`authz_authorize/1`。解析是 CPU 工作，用 DirtyCpu 调度器。

成功输出：

```json
{"segments": [{"scope": "world", "text": "..."},
              {"scope": "principal:alice", "text": "..."}],
 "wikilinks": ["companies/minghu-ai"]}
```

语法错误输出（正常返回值，不是 NIF error）：

```json
{"error": {"code": "unclosed_audience_tag", "line": 12}}
```

`code` 取值：`nested_audience_tag`、`unopened_audience_tag`、
`unclosed_audience_tag`、`misplaced_audience_tag`。`line` 是 1-based 行号，
第二阶段的编辑器诊断直接使用。NIF 级 `{:error, String.t()}` 只表示实现缺陷
（例如非法 UTF-8），按现有 `result()` 惯例处理。

### 分析算法（规范）

1. comrak 解析全文，开启 `wikilinks_title_after_pipe`，不开启其他扩展。
   AST 节点自带 sourcepos。
2. 收集代码范围：每个 `CodeBlock` 节点的行范围，每个 inline `Code` 节点的
   sourcepos 区间。
3. 标签行：整行匹配 `^\{%\s*audience\s+scope="([^"]*)"\s*%\}[ \t\r]*$` 或
   `^\{%\s*/audience\s*%\}[ \t\r]*$`，且该行不在任何 `CodeBlock` 行范围内。
4. 越位检查：源文中每个匹配 `\{%[ \t]*/?[ \t]*audience` 的位置必须落在某个
   标签行上或某个代码范围内，否则返回 `misplaced_audience_tag`。
5. 对标签行按文档顺序跑配对状态机，错误码同上。segment 文本是标签行之间的
   原始字节切片（按行边界），逐字保留；开标签行之前和闭标签行之后的 root
   文本是 `world` segment。
6. wikilinks：AST `WikiLink` 节点的 `url`，按文档顺序，trim 后剔除空目标，
   去重。

comrak 在这里只回答两个事实："哪些范围是代码"和"哪里有 wikilink"。段落、
列表、标题等其他结构信息一概不用。规范语法就是以上六步，不多不少。

### Elixir 侧

`Ankole.Brain.Markdoc` 保持全部公开函数和签名不变：`segments/1`、
`scopes/1`、`prune/2`、`wrap/2`、`wikilinks/1`。内部改为调用一次
`Ankole.Kernel.brain_markdoc_analyze/1`：

- `segments/1`：错误码映射为现有 atom（`{:error, :nested_audience_tag}`
  等），对每个非 `world` scope 跑 `Ankole.Brain.Scope.parse/1`（保持
  `{:error, {:invalid_audience_scope, scope}}`），最后剔除 trim 后为空的
  segment（现状）。
- `prune/2`：使用未剔除空白的原始 segment 列表，保留通过 `keep?` 的
  segment，scoped segment 重新包上规范标签——保持"裁剪结果再写入时 scope
  不变"的现有性质。
- `wrap/2`：纯字符串拼接，保持现状；其输出天然符合新语法（标签顶格独占
  一行）。
- `wikilinks/1`：直接返回分析结果中的 wikilinks。
- 删除 `@open_tag`、`@close_tag`、`@wikilink` 三个正则、`tokenize/1` 和
  `build_segments/2`。

调用方 `Objects`、`GetPage`、`Dreaming`、`Forget`、`SourceLearning`、
`Synthesis` 不改动。`GetPage` 对坏正文投影空正文的 fail-closed 行为保持
不变。segment 切片的空白细节与旧实现可能有差异，允许更新测试 fixture，
但 scope 归属语义必须一致。

## 存量数据

- 系统写入器全部经过 `wrap/2`，其输出符合新语法，主路径存量数据不受影响。
- 曾经通过旧扫描器但违反新语法的正文（例如标签文本出现在行中间）：读取
  投影为空（现有 fail-closed 路径），更新被拒绝。操作员用第二阶段的原始
  body 编辑修复；在此之前用数据库直连修复。不为它写迁移。
- 产品库文件已盘点：不含 `audience` 标签文本，不含 `[[slug]]` 用法，无需
  迁移。

## 第一阶段：服务端原子替换

一个 commit 完成：kernel 模块与测试、`Ankole.Brain.Markdoc` 内部替换、
调用方测试更新、本文与 `BrainV3.md` 引用状态更新。

| 保证 | 证据 |
| --- | --- |
| P0 关闭 | 本文样例在 create、update、chunk、get_page 四条路径被拒绝或投影为空；kernel corpus 测试含该样例 |
| 代码即文本 | fenced（``` 与 ~~~、含 info string）、indented、list 内缩进 fence、inline code 中的标签文本与 `[[...]]` 都不产生标签或链接 |
| 越位即拒绝 | 行中间、heading、blockquote、多行段落、HTML block 中的标签文本全部返回 `misplaced_audience_tag` |
| 配对语义 | 嵌套、未开、未闭、非法 scope 的错误码与现实现一致 |
| 行为保持 | `app/control_plane` 的 markdoc、objects、get_page、forget、dreaming 相关测试通过（fixture 空白差异允许） |

命令：`app/kernel` 下 `cargo test`（feature 方式照抄 `program_runner` 的
测试）与 `mix test`；`app/control_plane` 下
`mix test test/ankole/brain/markdoc_test.exs` 及其余受影响测试文件。

## 第二阶段：Console 创建与编辑

一个 commit 完成。开始前先读 `app/webapps/AGENTS.md`。

### 投影所有权

`managed_by_source_id` 的含义推广为"正文由一个 Brain Source 拥有"。
SourceLearning 写 media Object 时必须设置它，并使用受 Source 身份约束的
内部 upsert 路径；普通 Object 更新继续拒绝所有 managed Object。不加第二个
owner 字段。

### 可编辑状态

服务端返回可编辑状态，Console 不根据 badge 或 type 自行猜测：

| 状态 | 正文操作 | 引导 |
| --- | --- | --- |
| 实例自有且未删除 | 创建、编辑、保存 | `Objects.create_object/3` 或 `Objects.update_object/4` |
| 已删除 | 只读 | 先恢复，再编辑 |
| 普通 Library 投影 | 只读 | 可 Fork；Fork 后成为实例正文且不再接收投影更新（现状） |
| SourceLearning media 投影 | 只读 | 打开 Source 重新学习或归档；不提供 Fork |
| `agent-skills` 投影 | 只读 | 打开 Agent Library；不提供 Fork |

### Console API

Object slug 包含 `/`，创建和更新沿用集合路径并在 body 中携带 slug：

| 方法与路径 | 用途 | 关键输入或输出 |
| --- | --- | --- |
| `GET /brain/objects/show?slug=...` | 加载详情和编辑基线 | 增加 raw `body`、`content_hash`、`editable`、`edit_block_reason` |
| `POST /brain/objects` | 创建实例 Object | slug、type、subtype、title、body、meta、effective_date |
| `PUT /brain/objects` | 更新实例 Object | slug、可变字段、`expected_content_hash` |

创建和更新要求 `brain:update`；raw body 只在 `brain:read` 管理边界返回。
422 返回结构化诊断（`code`、`line`），409 专用于 content hash 冲突。控制面
schema 完成后按仓库规定重新生成 OpenAPI 和 Web client，不手改生成文件。

没有"以 Principal 预览"端点。完整预览的 scope badge 已让保密边界可见；
要验证真实披露，用目标 Principal 读一次页面。

### 编辑器

专用全页路由 `/brain/objects/new` 和 `/brain/objects/:slug/edit`。第一版
刻意最小：

- 源码用普通 textarea，不引入 CodeMirror。
- 预览列：一个 preview-only 的本地分段函数（fence 状态机加标签行正则，
  约 60 行，放在 console state 层），每个 segment 用现有 `MarkdownBody`
  渲染并加 scope badge。`[[slug]]` 在预览中显示为字面文本，可接受。
- 本地分段只服务预览。服务端保存时无条件重新分析；422 诊断显示在
  Problems 区。奇异输入下本地预览与服务端可以不一致，以服务端为准。
- 保存带页面加载时的 `expected_content_hash`。409 时保留本地草稿，让
  操作员重新加载对比，不自动覆盖。离开有未保存修改的页面前提示。
- 创建时可填 slug、type、subtype、title、effective_date、meta。编辑时
  slug 和 type 只读：领域更新契约不支持 rename 或 type change，不借编辑器
  发明第二条路。

验收：E2E 从 Console 创建和编辑带 `audience` 的 Object，分别用有权和无权
Principal 读取，检查版本与 chunk scope；管理员能打开一个存量坏正文的编辑页，
看到诊断并修复保存。

## 明确不做

以下每一项都被考虑过并被否决。不要加回来：

- 不引入 `@markdoc/markdoc`、任何 JS 共享包、Bun 编译产物、独立进程、Port、
  进程池、deno_core isolate。解析就是一个 NIF 函数。
- 不实现完整 Markdoc：没有 `if`/`else`、变量、函数、partial、annotation、
  inline tag、嵌套标签。出现第二个标签需求时重新评估整体迁移到完整
  Markdoc，而不是往薄层里加特性。
- 不用 markdown-it-rs、tree-sitter，也不手写 CommonMark。块结构事实只来自
  comrak。
- 不持久化 AST、segment 或诊断，不加解析结果缓存。原生解析在微秒级，读
  路径直接调用。
- kernel 只暴露这一个 NIF。不加 format、transform、render 函数。
- 不做格式化功能。源码逐字保存，没有 formatter。
- 第一版不做 WYSIWYG、CodeMirror 和语法高亮。
- 不加"以 Principal 预览"端点。
- `GetPage` 的 `rendered` 字段名与拼接投影保持现状，不改名不重构。
- 不为违反新语法的存量正文写迁移或运行时兼容分支。

## 参考

- comrak：<https://docs.rs/comrak>。使用
  `Options.extension.wikilinks_title_after_pipe`、`NodeValue::CodeBlock`、
  `NodeValue::Code`、`NodeValue::WikiLink` 和节点 sourcepos。
- Markdoc 标签语法形状（未来迁移目标）：<https://markdoc.dev/docs/tags>。
