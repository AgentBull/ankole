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
  postgres: NodeCopy
  home: NodeCopy
  caption: string
}

/** The diagram text for each locale. The SVG, the narrow-screen layout, and the Markdown share it. */
export const ARCHITECTURE_DIAGRAM_COPY: Record<Locale, ArchitectureDiagramCopy> = {
  'en-US': {
    title: 'Ankole system architecture',
    description:
      'Enterprise channels, external events, identity providers, the Console, and AI providers connect to the control plane. The control plane uses configured Worker pools to create a separate computer for each Agent on demand. Phoenix Channels carry live control; PostgreSQL and the file service keep durable state.',
    external: 'Enterprise and external systems',
    control: 'Control plane · one logical management boundary',
    execution: 'Execution · one Worker per Agent',
    data: 'Durability boundary',
    channels: ['Channels and external events', 'Messages · webhooks · schedules'],
    operators: ['Console and APIs', 'Operators · enterprise apps'],
    idp: ['Identity Providers', 'SSO · directory · organization'],
    providers: ['AI Providers', 'Models · vectors · images · web'],
    signals: ['Conversations / Signals', 'Messages · admission · Delivery'],
    identity: ['Principal and AuthZ', 'Identity · access · config · plugins'],
    ai: ['AIGateway', 'Model state · tools · credentials'],
    sessions: ['Sessions', 'Main Agent loop · tools · recovery'],
    brain: ['Brain', 'World model · recall · Dreaming'],
    jobs: ['Background Agent Jobs', 'Non-blocking · resumable · interactive'],
    fabric: 'RuntimeFabric · Phoenix Channels',
    workers: [
      'Agent Computer Workers · one per Agent',
      'Environment tools · Codex Jobs · Automation Jobs · Skills · cache disk'
    ],
    postgres: ['PostgreSQL', 'Identity · sessions · memory · Jobs · audit'],
    home: ['Persistent files', 'Agent Home · control-plane drives'],
    caption:
      'The control plane stores state and manages Worker pools. Agents in one pool keep separate computers and Home. An idle instance can be released or paused; Home survives replacement and the cache can be rebuilt.'
  },
  'zh-Hans-CN': {
    title: 'Ankole 系统架构',
    description:
      '企业聊天、外部事件、身份源、Console 和 AI Provider 连接到控制面。控制面通过配置的 WorkerPool 为 Agent 按需创建独立电脑。Phoenix Channel 传递实时控制，PostgreSQL 和文件服务保存持久状态。',
    external: '企业与外部系统',
    control: '控制面 · 一个逻辑管理边界',
    execution: '执行层 · 每个 Agent 一个 Worker',
    data: '持久化边界',
    channels: ['聊天渠道与外部事件', '消息 · Webhook · 计划任务'],
    operators: ['Console 与 API', '管理员 · 企业应用'],
    idp: ['身份源提供商', 'SSO · 通讯录 · 组织架构'],
    providers: ['AI Provider', '模型 · 向量 · 图像 · Web'],
    signals: ['Conversations / Signals', '发言 · 接纳 · 投递'],
    identity: ['主体与 AuthZ', '身份 · 权限 · 配置 · 插件'],
    ai: ['AIGateway', '模型状态 · 工具 · 凭证'],
    sessions: ['Sessions', '主 Agent 循环 · 工具 · 恢复'],
    brain: ['Brain', '世界模型 · 召回 · Dreaming'],
    jobs: ['后台 Agent 任务', '非阻塞 · 可恢复 · 可通信'],
    fabric: 'RuntimeFabric · Phoenix Channels',
    workers: ['Agent Computer Worker · 每个 Agent 一个', '环境工具 · Codex Job · Automation Job · Skills · 缓存盘'],
    postgres: ['PostgreSQL', '身份 · 会话 · 记忆 · 任务 · 审计'],
    home: ['持久文件', 'Agent Home · 控制面云盘'],
    caption:
      '控制面保存状态并管理 WorkerPool。同池 Agent 使用独立电脑与 Home。空闲实例可以回收或暂停，替换后 Home 保留，缓存可以重建。'
  },
  'ja-JP': {
    title: 'Ankole システムアーキテクチャ',
    description:
      '企業チャット、外部イベント、アイデンティティプロバイダー、Console、AI Provider がコントロールプレーンに接続します。設定した Worker pool から Agent ごとの専用コンピュータを必要時に作成します。Phoenix Channel はライブ制御を運び、PostgreSQL とファイルサービスは永続状態を保持します。',
    external: '企業と外部システム',
    control: 'コントロールプレーン · 1 つの論理管理境界',
    execution: '実行層 · Agent ごとに 1 つの Worker',
    data: '永続化境界',
    channels: ['チャットチャネルと外部イベント', 'メッセージ · Webhook · 計画タスク'],
    operators: ['Console と API', 'オペレーター · 企業アプリ'],
    idp: ['アイデンティティプロバイダー', 'SSO · ディレクトリ · 組織'],
    providers: ['AI Provider', 'モデル · ベクトル · 画像 · Web'],
    signals: ['Conversations / Signals', '発言 · 受付 · 配送'],
    identity: ['主体と AuthZ', 'アイデンティティ · 権限 · 設定 · プラグイン'],
    ai: ['AIGateway', 'モデル状態 · ツール · 認証情報'],
    sessions: ['Sessions', 'メイン Agent ループ · ツール · 復旧'],
    brain: ['Brain', 'ワールドモデル · 想起 · Dreaming'],
    jobs: ['バックグラウンド Agent タスク', 'ノンブロッキング · 再開可能 · 通信可能'],
    fabric: 'RuntimeFabric · Phoenix Channels',
    workers: [
      'Agent Computer Worker · Agent ごとに 1 つ',
      '環境ツール · Codex Job · Automation Job · Skills · キャッシュディスク'
    ],
    postgres: ['PostgreSQL', 'アイデンティティ · セッション · メモリ · タスク · 監査'],
    home: ['永続ファイル', 'Agent Home · コントロールプレーンのドライブ'],
    caption:
      'コントロールプレーンは状態を保存し、Worker pool を管理します。同じ pool の Agent もコンピュータと Home は専用です。アイドル時は解放または休止できます。置換後も Home は残り、キャッシュは再構築できます。'
  },
  'ko-KR': {
    title: 'Ankole 시스템 아키텍처',
    description:
      '엔터프라이즈 채널, 외부 이벤트, identity provider, Console, AI Provider가 control plane에 연결됩니다. 설정한 Worker pool에서 Agent마다 전용 컴퓨터를 필요할 때 만듭니다. Phoenix Channel은 실시간 제어를 전달하고 PostgreSQL과 파일 서비스는 영구 상태를 보관합니다.',
    external: '엔터프라이즈 및 외부 시스템',
    control: 'Control plane · 하나의 논리적 관리 경계',
    execution: '실행 계층 · Agent마다 하나의 Worker',
    data: '영속화 경계',
    channels: ['채팅 채널 및 외부 이벤트', '메시지 · Webhook · 일정 작업'],
    operators: ['Console 및 API', '운영자 · 엔터프라이즈 앱'],
    idp: ['Identity Provider', 'SSO · 디렉터리 · 조직'],
    providers: ['AI Provider', '모델 · 벡터 · 이미지 · Web'],
    signals: ['Conversations / Signals', '발언 · 접수 · 전달'],
    identity: ['Principal 및 AuthZ', '아이덴티티 · 권한 · 설정 · 플러그인'],
    ai: ['AIGateway', '모델 상태 · 도구 · 자격 증명'],
    sessions: ['Sessions', '주 Agent 루프 · 도구 · 복구'],
    brain: ['Brain', '월드 모델 · 회상 · Dreaming'],
    jobs: ['백그라운드 Agent 작업', '비차단 · 재개 가능 · 상호작용 가능'],
    fabric: 'RuntimeFabric · Phoenix Channels',
    workers: [
      'Agent Computer Worker · Agent마다 하나',
      '환경 도구 · Codex Job · Automation Job · Skills · 캐시 디스크'
    ],
    postgres: ['PostgreSQL', '아이덴티티 · 세션 · 메모리 · 작업 · 감사'],
    home: ['영속 파일', 'Agent Home · control plane 드라이브'],
    caption:
      'control plane은 상태를 저장하고 Worker pool을 관리합니다. 같은 pool의 Agent도 전용 컴퓨터와 Home을 가집니다. 유휴 시 해제하거나 일시 중지할 수 있습니다. 교체 후에도 Home은 유지되며 캐시는 재구축할 수 있습니다.'
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
      layer(copy.execution, [node(copy.workers, ARCHITECTURE_WORKER_SLUG)]),
      layer(copy.data, [node(copy.postgres), node(copy.home)])
    ]),
    copy.caption
  )
}
