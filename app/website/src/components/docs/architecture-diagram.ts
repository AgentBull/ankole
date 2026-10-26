import type { Locale } from '../../i18n/config'
import { blocks, bulletList, type ComponentMarkdownRenderer, requiredProp } from '../../lib/markdown-text'

/** A diagram node: its name, then a short list of what it covers. */
type NodeCopy = readonly [name: string, detail: string]

export interface ArchitectureDiagramCopy {
  title: string
  description: string
  external: string
  control: string
  execution: string
  data: string
  channels: NodeCopy
  operators: NodeCopy
  idp: NodeCopy
  providers: NodeCopy
  signals: NodeCopy
  identity: NodeCopy
  ai: NodeCopy
  sessions: NodeCopy
  brain: NodeCopy
  jobs: NodeCopy
  fabric: string
  workers: NodeCopy
  functionRuntime: NodeCopy
  postgres: NodeCopy
  home: NodeCopy
  caption: string
}

/** The diagram text for each locale. The SVG, the narrow-screen layout, and the Markdown share it. */
export const ARCHITECTURE_DIAGRAM_COPY: Record<Locale, ArchitectureDiagramCopy> = {
  'en-US': {
    title: 'Ankole system architecture',
    description:
      'Pod workspaces, enterprise channels, passwordless authentication, the Console, and AI providers connect to the control plane. The control plane manages one Worker per Agent and dispatches stateless isolates on Function Runtime. Phoenix Channels carry live control; PostgreSQL 18+ (including physical Base shards) and the file store keep durable state.',
    external: 'Workspaces and external systems',
    control: 'Control plane · one logical management boundary',
    execution: 'Execution · per-Agent Workers and Function Runtime',
    data: 'Durability boundary',
    channels: ['Channels and external events', 'Messages · webhooks · schedules'],
    operators: ['Pod, Console, and APIs', 'Workspace · admin · external apps'],
    idp: ['Authentication and IdPs', 'Email OTP · SSO · directory'],
    providers: ['AI Providers', 'Models · vectors · images · web'],
    signals: ['Pod and Signals', 'Pages · Base · Chat · Delivery'],
    identity: ['Principal and AuthZ', 'Passwordless · IAM · Pod ACLs'],
    ai: ['AIGateway', 'Model state · tools · credentials'],
    sessions: ['Sessions', 'Main Agent loop · tools · recovery'],
    brain: ['Brain', 'World model · recall · Dreaming'],
    jobs: ['Background Agent Jobs', 'Non-blocking · resumable · interactive'],
    fabric: 'RuntimeFabric · Phoenix Channels & HTTP',
    workers: ['Agent Computer Workers · one per Agent', 'Env tools · Codex & Automation · Skills'],
    functionRuntime: ['Function Runtime · stateless isolates', 'Pod Applet backends · PTC & Workflow programs'],
    postgres: ['PostgreSQL 18+', 'Control plane · physical Base shards'],
    home: ['Persistent files', 'Agent Home · drives · Pod files & Applets'],
    caption:
      'The control plane owns durable state, supervises Worker pools, and invokes stateless Function Runtime isolates. Agents in one pool keep separate computers and Home; Home survives replacement and caches can be rebuilt.'
  },
  'zh-Hans-CN': {
    title: 'Ankole 系统架构',
    description:
      'Pod 工作空间、企业聊天渠道、无密码认证、Console 和 AI Provider 连接到控制面。控制面为每个 Agent 按需创建独立 Worker，并在无状态 Function Runtime 中运行隔离函数。Phoenix Channel 传递实时控制，PostgreSQL 18+（含物理 Base 分片库）与文件存储保存持久状态。',
    external: '工作空间与外部系统',
    control: '控制面 · 一个逻辑管理边界',
    execution: '执行层 · 单 Agent Worker 与 Function Runtime',
    data: '持久化边界',
    channels: ['聊天渠道与外部事件', '消息 · Webhook · 计划任务'],
    operators: ['Pod、Console 与 API', '工作空间 · 管理 · 企业应用'],
    idp: ['认证与身份源', '邮箱验证码 · SSO · 组织目录'],
    providers: ['AI Provider', '模型 · 向量 · 图像 · Web'],
    signals: ['Pod 与 Signals', '页面 · 多维表 · 小应用 · Chat'],
    identity: ['主体与 AuthZ', '无密码认证 · IAM · Pod 权限'],
    ai: ['AIGateway', '模型状态 · 工具 · 凭证'],
    sessions: ['Sessions', '主 Agent 循环 · 工具 · 恢复'],
    brain: ['Brain', '世界模型 · 召回 · Dreaming'],
    jobs: ['后台 Agent 任务', '非阻塞 · 可恢复 · 可通信'],
    fabric: 'RuntimeFabric · Phoenix Channels 与 HTTP',
    workers: ['Agent Computer Worker · 每个 Agent 一个', '环境工具 · Codex 与 Automation · Skills'],
    functionRuntime: ['Function Runtime · 无状态隔离运行时', 'Pod 小应用后端 · PTC 与 Workflow 脚本'],
    postgres: ['PostgreSQL 18+', '控制面库 · 物理 Base 分片库'],
    home: ['持久文件', 'Agent Home · 云盘 · Pod 文件与小应用'],
    caption:
      '控制面持有持久状态，管理 WorkerPool 并调用无状态 Function Runtime。同池 Agent 使用独立电脑与 Home；实例替换后 Home 保留，缓存可以重建。'
  },
  'ja-JP': {
    title: 'Ankole システムアーキテクチャ',
    description:
      'Pod ワークスペース、企業チャット、パスワードレス認証、Console、AI Provider がコントロールプレーンに接続します。Agent ごとの専用 Worker とステートレスな Function Runtime を組み合わせ、Phoenix Channel がライブ制御を運び、PostgreSQL 18+（物理 Base シャードを含む）とファイルサービスが永続状態を保持します。',
    external: 'ワークスペースと外部システム',
    control: 'コントロールプレーン · 1 つの論理管理境界',
    execution: '実行層 · Agent 専用 Worker と Function Runtime',
    data: '永続化境界',
    channels: ['チャットチャネルと外部イベント', 'メッセージ · Webhook · 計画タスク'],
    operators: ['Pod・Console と API', 'ワークスペース · 管理 · 企業アプリ'],
    idp: ['認証と IdP', 'メール OTP · SSO · ディレクトリ'],
    providers: ['AI Provider', 'モデル · ベクトル · 画像 · Web'],
    signals: ['Pod と Signals', 'ページ · Base · Chat · 配送'],
    identity: ['主体と AuthZ', 'パスワードレス · IAM · Pod ACL'],
    ai: ['AIGateway', 'モデル状態 · ツール · 認証情報'],
    sessions: ['Sessions', 'メイン Agent ループ · ツール · 復旧'],
    brain: ['Brain', 'ワールドモデル · 想起 · Dreaming'],
    jobs: ['バックグラウンド Agent タスク', 'ノンブロッキング · 再開可能 · 通信可能'],
    fabric: 'RuntimeFabric · Phoenix Channels & HTTP',
    workers: ['Agent Computer Worker · Agent ごとに 1 つ', '環境ツール · Codex / Automation · Skills'],
    functionRuntime: ['Function Runtime · ステートレス分離実行', 'Pod Applet バックエンド · PTC / Workflow'],
    postgres: ['PostgreSQL 18+', '制御プレーン · 物理 Base シャード'],
    home: ['永続ファイル', 'Agent Home · ドライブ · Pod ファイル'],
    caption:
      'コントロールプレーンは永続状態を保持し、Worker pool とステートレスな Function Runtime を管理します。同じ pool の Agent もコンピュータと Home は専用で、置換後も Home は残りキャッシュは再構築できます。'
  },
  'ko-KR': {
    title: 'Ankole 시스템 아키텍처',
    description:
      'Pod 워크스페이스, 엔터프라이즈 채널, 패스워드리스 인증, Console, AI Provider가 control plane에 연결됩니다. Agent마다 전용 Worker를 만들고 무상태 Function Runtime 격리 인스턴스를 실행합니다. Phoenix Channel은 실시간 제어를 전달하고 PostgreSQL 18+(물리 Base 샤드 포함)와 파일 서비스는 영구 상태를 보관합니다.',
    external: '워크스페이스 및 외부 시스템',
    control: 'Control plane · 하나의 논리적 관리 경계',
    execution: '실행 계층 · Agent 전용 Worker 및 Function Runtime',
    data: '영속화 경계',
    channels: ['채팅 채널 및 외부 이벤트', '메시지 · Webhook · 일정 작업'],
    operators: ['Pod, Console 및 API', '워크스페이스 · 관리 · 엔터프라이즈 앱'],
    idp: ['인증 및 IdP', '이메일 OTP · SSO · 디렉터리'],
    providers: ['AI Provider', '모델 · 벡터 · 이미지 · Web'],
    signals: ['Pod 및 Signals', '페이지 · Base · Chat · 전달'],
    identity: ['Principal 및 AuthZ', '패스워드리스 · IAM · Pod ACL'],
    ai: ['AIGateway', '모델 상태 · 도구 · 자격 증명'],
    sessions: ['Sessions', '주 Agent 루프 · 도구 · 복구'],
    brain: ['Brain', '월드 모델 · 회상 · Dreaming'],
    jobs: ['백그라운드 Agent 작업', '비차단 · 재개 가능 · 상호작용 가능'],
    fabric: 'RuntimeFabric · Phoenix Channels & HTTP',
    workers: ['Agent Computer Worker · Agent마다 하나', '환경 도구 · Codex / Automation · Skills'],
    functionRuntime: ['Function Runtime · 무상태 격리 런타임', 'Pod Applet 백엔드 · PTC 및 Workflow 스크립트'],
    postgres: ['PostgreSQL 18+', 'control plane · 물리 Base 샤드'],
    home: ['영속 파일', 'Agent Home · 드라이브 · Pod 파일'],
    caption:
      'control plane은 영구 상태를 보유하며 Worker pool과 무상태 Function Runtime을 관리합니다. 같은 pool의 Agent도 전용 컴퓨터와 Home을 가지며 교체 후에도 Home은 유지되고 캐시는 재구축할 수 있습니다.'
  }
}

type ControlNodeKey = 'signals' | 'identity' | 'ai' | 'sessions' | 'brain' | 'jobs'

/** Control-plane nodes in diagram order, with the docs page that each one links to. */
export const ARCHITECTURE_CONTROL_NODES: readonly { key: ControlNodeKey; slug: string }[] = [
  { key: 'signals', slug: 'conversations-signals-sessions' },
  { key: 'identity', slug: 'principal-authz' },
  { key: 'ai', slug: 'ai-gateway' },
  { key: 'sessions', slug: 'sessions' },
  { key: 'brain', slug: 'brain' },
  { key: 'jobs', slug: 'background-jobs' }
]

export const ARCHITECTURE_WORKER_SLUG = 'agent-computer-worker'
export const ARCHITECTURE_FUNCTION_RUNTIME_SLUG = 'workflows'

/** Writes the diagram as a nested list: each layer, then its nodes. */
export const renderArchitectureDiagram: ComponentMarkdownRenderer = (props, context) => {
  const locale = requiredProp<Locale>(props, 'lang')
  const copy = ARCHITECTURE_DIAGRAM_COPY[locale]
  if (!copy) throw new Error(`the lang prop ${JSON.stringify(locale)} is not a site locale`)

  const node = ([name, detail]: NodeCopy, slug?: string) =>
    `${slug ? `[${name}](${context.docMarkdownUrl(locale, slug)})` : name} — ${detail}`
  const layer = (name: string, nodes: string[]) => `${name}\n${bulletList(nodes)}`

  return blocks(
    `**${copy.title}**`,
    copy.description,
    bulletList([
      layer(
        copy.external,
        [copy.channels, copy.operators, copy.idp, copy.providers].map(item => node(item))
      ),
      layer(
        copy.control,
        ARCHITECTURE_CONTROL_NODES.map(item => node(copy[item.key], item.slug))
      ),
      copy.fabric,
      layer(copy.execution, [
        node(copy.workers, ARCHITECTURE_WORKER_SLUG),
        node(copy.functionRuntime, ARCHITECTURE_FUNCTION_RUNTIME_SLUG)
      ]),
      layer(copy.data, [node(copy.postgres), node(copy.home)])
    ]),
    copy.caption
  )
}
