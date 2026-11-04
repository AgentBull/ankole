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
      'Pod workspaces, Unified Connectors, enterprise channels, passwordless authentication, the Console, and AI providers connect to the control plane. The control plane manages one Worker per Agent via WorkerProviders and runs Applet backends, published Applet Actions, host MCP calls, and PTC/Workflow isolates on Function Runtime. Phoenix Channels carry live control; PostgreSQL 18+ (including physical Base shards) and Unified Drive + Agent Home keep durable state.',
    external: 'Workspaces and external systems',
    control: 'Control plane · one logical management boundary',
    execution: 'Execution · per-Agent Workers and Function Runtime',
    data: 'Durability boundary',
    channels: ['Channels & Connector events', 'IMs · webhooks · triggers · cron'],
    operators: ['Pod, Console, and APIs', 'Docs · Base · Applets · Console'],
    idp: ['Authentication and IdPs', 'Email OTP · SSO · directory'],
    providers: ['AI Providers', 'Models · vectors · images · web'],
    signals: ['Pod and Signals', 'Docs · Base · Applets · Chat'],
    identity: ['Principal and AuthZ', 'Passwordless · IAM · Drive ACLs'],
    ai: ['AIGateway & Connectors', 'Model profiles · MCP · credentials'],
    sessions: ['Sessions', 'Agent loop · Peer A2A · recovery'],
    brain: ['Meta Ankole & Brain', 'Ontology · Skills · Dreaming'],
    jobs: ['Jobs & Automations', 'Background Jobs · Applet Actions'],
    fabric: 'RuntimeFabric · Phoenix Channels & HTTP',
    workers: [
      'Agent Computer Workers · one per Agent',
      'Env tools · Codex · /drive FUSE · Skills · Browser · MCP · Git'
    ],
    functionRuntime: ['Function Runtime · stateless isolates', 'Applet backends & Actions · host MCP · PTC & Workflow'],
    postgres: ['PostgreSQL 18+', 'Control plane · Meta Ankole · physical Base shards'],
    home: ['Unified Drive & Agent Home', 'Drive file objects · Applets · /workspace Home'],
    caption:
      'The control plane owns durable state, supervises WorkerProviders, serves the Unified Connectors MCP gateway, and invokes stateless Function Runtime isolates for Applet Actions and programs. Agents keep dedicated computers, /drive FUSE views, and persistent /workspace Home across replacements while caches rebuild.'
  },
  'zh-Hans-CN': {
    title: 'Ankole 系统架构',
    description:
      'Pod 数字总部、统一连接器（Connectors）、企业聊天渠道、无密码认证、Console 与 AI Provider 接入控制面。控制面通过 WorkerProviders 为每个 Agent 按需分配独立 Worker，并在无状态 Function Runtime 中运行小应用后端、已发布小应用 Action、宿主 MCP 桥接与 PTC/Workflow 程序。Phoenix Channel 传递实时控制，PostgreSQL 18+（含物理 Base 分片库）与统一云盘及 Agent Home 保存持久状态。',
    external: '工作空间与外部系统',
    control: '控制面 · 一个逻辑管理边界',
    execution: '执行层 · 单 Agent Worker 与 Function Runtime',
    data: '持久化边界',
    channels: ['聊天渠道与连接器事件', 'IM 消息 · Webhook · 订阅 · 定时'],
    operators: ['Pod、Console 与 API', '文档 · 多维表 · 小应用 · 管理'],
    idp: ['认证与身份源', '邮箱验证码 · SSO · 组织目录'],
    providers: ['AI Provider', '模型 · 向量 · 图像 · Web'],
    signals: ['Pod 与 Signals', '文档 · 多维表 · 小应用 · Chat'],
    identity: ['主体与 AuthZ', '无密码认证 · IAM · 云盘 ACL'],
    ai: ['AIGateway 与连接器', '模型配置 · MCP 网关 · 凭证'],
    sessions: ['Sessions', 'Agent 循环 · Peer A2A · 恢复'],
    brain: ['Meta Ankole 与 Brain', '本体图谱 · Skills · Dreaming'],
    jobs: ['后台与自动化任务', '后台 Codex 任务 · 小应用 Action'],
    fabric: 'RuntimeFabric · Phoenix Channels 与 HTTP',
    workers: [
      'Agent Computer Worker · 每个 Agent 一个',
      '环境工具 · Codex · /drive FUSE · Skills · 浏览器 · MCP · Git'
    ],
    functionRuntime: ['Function Runtime · 无状态隔离运行时', '小应用后端与 Action · 宿主 MCP · PTC 与 Workflow'],
    postgres: ['PostgreSQL 18+', '控制面库 · Meta Ankole · 物理 Base 分片库'],
    home: ['统一云盘与 Agent Home', '云盘文件对象 · 小应用包 · /workspace Home'],
    caption:
      '控制面持有持久状态，管理 WorkerProviders，提供统一连接器 MCP 网关，并调用无状态 Function Runtime 运行小应用 Action 与脚本。各 Agent 独享独立电脑、/drive FUSE 挂载与持久 /workspace Home；实例替换后 Home 保留，缓存可随时重建。'
  },
  'ja-JP': {
    title: 'Ankole システムアーキテクチャ',
    description:
      'Pod ワークスペース、統合 Connectors、企業チャット、パスワードレス認証、Console、AI Provider がコントロールプレーンに接続します。コントロールプレーンは WorkerProviders を通じて Agent ごとの専用 Worker を管理し、ステートレスな Function Runtime 上で Applet バックエンド、公開済み Applet Action、ホスト MCP ブリッジ、PTC/Workflow を実行します。Phoenix Channel がライブ制御を運び、PostgreSQL 18+（物理 Base シャードを含む）と統合 Drive および Agent Home が永続状態を保持します。',
    external: 'ワークスペースと外部システム',
    control: 'コントロールプレーン · 1 つの論理管理境界',
    execution: '実行層 · Agent 専用 Worker と Function Runtime',
    data: '永続化境界',
    channels: ['チャネルと Connector イベント', 'IM · Webhook · トリガー · 定期実行'],
    operators: ['Pod・Console と API', 'Docs · Base · Applet · 管理'],
    idp: ['認証と IdP', 'メール OTP · SSO · ディレクトリ'],
    providers: ['AI Provider', 'モデル · ベクトル · 画像 · Web'],
    signals: ['Pod と Signals', 'Docs · Base · Applet · Chat'],
    identity: ['主体と AuthZ', 'パスワードレス · IAM · Drive ACL'],
    ai: ['AIGateway と Connectors', 'モデル設定 · MCP · 認証情報'],
    sessions: ['Sessions', 'Agent ループ · Peer A2A · 復旧'],
    brain: ['Meta Ankole と Brain', 'オントロジー · Skills · Dreaming'],
    jobs: ['ジョブと自動化', 'バックグラウンド Job · Applet Action'],
    fabric: 'RuntimeFabric · Phoenix Channels & HTTP',
    workers: [
      'Agent Computer Worker · Agent ごとに 1 つ',
      '環境ツール · Codex · /drive FUSE · Skills · ブラウザ · MCP · Git'
    ],
    functionRuntime: [
      'Function Runtime · ステートレス分離実行',
      'Applet バックエンド / Action · ホスト MCP · PTC / Workflow'
    ],
    postgres: ['PostgreSQL 18+', '制御プレーン · Meta Ankole · 物理 Base シャード'],
    home: ['統合 Drive と Agent Home', 'Drive ファイル · Applet · /workspace Home'],
    caption:
      'コントロールプレーンは永続状態を保持し、WorkerProviders と統合 Connectors MCP ゲートウェイを管理しつつ、Applet Action やプログラム向けにステートレスな Function Runtime を呼び出します。各 Agent は専用のコンピュータ・/drive FUSE・永続 /workspace Home を持ち、置換後も Home は維持されキャッシュは再構築できます。'
  },
  'ko-KR': {
    title: 'Ankole 시스템 아키텍처',
    description:
      'Pod 워크스페이스, 통합 Connectors, 엔터프라이즈 채널, 패스워드리스 인증, Console, AI Provider가 컨트롤 플레인에 연결됩니다. 컨트롤 플레인은 WorkerProviders로 Agent마다 전용 Worker를 관리하고, 무상태 Function Runtime에서 Applet 백엔드, 게시된 Applet Action, 호스트 MCP 브리지, PTC/Workflow 프로그램을 실행합니다. Phoenix Channel이 실시간 제어를 전달하며 PostgreSQL 18+(물리 Base 샤드 포함)와 통합 Drive 및 Agent Home이 영구 상태를 보관합니다.',
    external: '워크스페이스 및 외부 시스템',
    control: '컨트롤 플레인 · 하나의 논리적 관리 경계',
    execution: '실행 계층 · Agent 전용 Worker 및 Function Runtime',
    data: '영속화 경계',
    channels: ['채널 및 Connector 이벤트', 'IM · Webhook · 트리거 · 일정'],
    operators: ['Pod, Console 및 API', 'Docs · Base · Applet · 관리'],
    idp: ['인증 및 IdP', '이메일 OTP · SSO · 디렉터리'],
    providers: ['AI Provider', '모델 · 벡터 · 이미지 · Web'],
    signals: ['Pod 및 Signals', 'Docs · Base · Applet · Chat'],
    identity: ['Principal 및 AuthZ', '패스워드리스 · IAM · Drive ACL'],
    ai: ['AIGateway 및 Connectors', '모델 프로필 · MCP · 자격 증명'],
    sessions: ['Sessions', 'Agent 루프 · Peer A2A · 복구'],
    brain: ['Meta Ankole 및 Brain', '온톨로지 · Skills · Dreaming'],
    jobs: ['백그라운드 및 자동화 작업', '백그라운드 Job · Applet Action'],
    fabric: 'RuntimeFabric · Phoenix Channels & HTTP',
    workers: [
      'Agent Computer Worker · Agent마다 하나',
      '환경 도구 · Codex · /drive FUSE · Skills · 브라우저 · MCP · Git'
    ],
    functionRuntime: [
      'Function Runtime · 무상태 격리 런타임',
      'Applet 백엔드 및 Action · 호스트 MCP · PTC 및 Workflow'
    ],
    postgres: ['PostgreSQL 18+', '컨트롤 플레인 · Meta Ankole · 물리 Base 샤드'],
    home: ['통합 Drive 및 Agent Home', 'Drive 파일 객체 · Applet · /workspace Home'],
    caption:
      '컨트롤 플레인은 영구 상태를 보유하며 WorkerProviders와 통합 Connectors MCP 게이트웨이를 관리하고, Applet Action과 프로그램 실행을 위해 무상태 Function Runtime을 호출합니다. 각 Agent는 전용 컴퓨터, /drive FUSE 마운트, 영속 /workspace Home을 유지하며 인스턴스 교체 후에도 Home은 보존되고 캐시는 재구축할 수 있습니다.'
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
