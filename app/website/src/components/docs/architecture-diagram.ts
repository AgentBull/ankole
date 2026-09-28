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
  actor: NodeCopy
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
      'Enterprise channels, external events, identity providers, the Console, and AI providers connect to the control plane. The control plane schedules one or more Agent Computer Workers through RuntimeFabric and stores durable state in PostgreSQL and Agent Home.',
    external: 'Enterprise and external systems',
    control: 'Control plane · one logical management boundary',
    execution: 'Execution · one or more Workers',
    data: 'Durability boundary',
    channels: ['Channels and external events', 'Messages · webhooks · schedules'],
    operators: ['Console and APIs', 'Operators · enterprise apps'],
    idp: ['Identity Providers', 'SSO · directory · organization'],
    providers: ['AI Providers', 'Models · vectors · images · web'],
    signals: ['SignalsGateway', 'Signal routing · message delivery'],
    identity: ['Principal and AuthZ', 'Identity · access · config · plugins'],
    ai: ['AIGateway', 'Model selection · sessions · credentials'],
    actor: ['Actor Runtime', 'Long sessions · wake · recovery'],
    brain: ['Brain', 'World model · recall · Dreaming'],
    jobs: ['Background Agent Jobs', 'Non-blocking · resumable · interactive'],
    fabric: 'RuntimeFabric · live control, no durable facts',
    workers: ['Agent Computer Worker pool · 1…N', 'Main Agents · Jobs · Automation Jobs · tools · Skills · sandboxes'],
    postgres: ['PostgreSQL', 'Identity · sessions · memory · Jobs · audit'],
    home: ['Agent Home', 'Files · workspaces · deliverables'],
    caption:
      'The control plane stores state and decides how work must run. Workers provide the compute environment. This split keeps Agent work independent of one process or machine.'
  },
  'zh-Hans-CN': {
    title: 'Ankole 系统架构',
    description:
      '企业聊天、外部事件、身份源、Console 和 AI Provider 连接到控制面。控制面通过 RuntimeFabric 调度一个或多个 Agent Computer Worker，并把持久状态写入 PostgreSQL 和 Agent Home。',
    external: '企业与外部系统',
    control: '控制面 · 一个逻辑管理边界',
    execution: '执行层 · 一台或多台 Worker',
    data: '持久化边界',
    channels: ['聊天渠道与外部事件', '消息 · Webhook · 计划任务'],
    operators: ['Console 与 API', '管理员 · 企业应用'],
    idp: ['身份源提供商', 'SSO · 通讯录 · 组织架构'],
    providers: ['AI Provider', '模型 · 向量 · 图像 · Web'],
    signals: ['SignalsGateway', '信号路由 · 消息收发'],
    identity: ['主体与 AuthZ', '身份 · 权限 · 配置 · 插件'],
    ai: ['AIGateway', '模型选择 · 会话 · 凭证'],
    actor: ['Actor Runtime', '长时会话 · 唤醒 · 恢复'],
    brain: ['Brain', '世界模型 · 召回 · Dreaming'],
    jobs: ['后台 Agent 任务', '非阻塞 · 可恢复 · 可通信'],
    fabric: 'RuntimeFabric · 实时控制，不保存事实',
    workers: ['Agent Computer Worker 池 · 1…N', '主 Agent · 后台任务 · Automation Job · 工具 · Skills · 沙盒'],
    postgres: ['PostgreSQL', '身份 · 会话 · 记忆 · 任务 · 审计'],
    home: ['Agent Home', '文件 · 工作区 · 交付物'],
    caption:
      '控制面保存状态并决定工作应当怎样运行；Worker 提供实际计算环境。两者分开后，Agent 的工作不会和某个进程或某台机器绑定。'
  },
  'ja-JP': {
    title: 'Ankole システムアーキテクチャ',
    description:
      '企業チャット、外部イベント、アイデンティティプロバイダー、Console、AI Provider がコントロールプレーンに接続します。コントロールプレーンは RuntimeFabric を通じて 1 台以上の Agent Computer Worker をスケジュールし、永続状態を PostgreSQL と Agent Home に保存します。',
    external: '企業と外部システム',
    control: 'コントロールプレーン · 1 つの論理管理境界',
    execution: '実行層 · 1 台以上の Worker',
    data: '永続化境界',
    channels: ['チャットチャネルと外部イベント', 'メッセージ · Webhook · 計画タスク'],
    operators: ['Console と API', 'オペレーター · 企業アプリ'],
    idp: ['アイデンティティプロバイダー', 'SSO · ディレクトリ · 組織'],
    providers: ['AI Provider', 'モデル · ベクトル · 画像 · Web'],
    signals: ['SignalsGateway', 'シグナルルーティング · メッセージ送受信'],
    identity: ['主体と AuthZ', 'アイデンティティ · 権限 · 設定 · プラグイン'],
    ai: ['AIGateway', 'モデル選択 · セッション · 認証情報'],
    actor: ['Actor Runtime', '長時間セッション · 起床 · 復旧'],
    brain: ['Brain', 'ワールドモデル · 想起 · Dreaming'],
    jobs: ['バックグラウンド Agent タスク', 'ノンブロッキング · 再開可能 · 通信可能'],
    fabric: 'RuntimeFabric · リアルタイム制御、事実は保存しない',
    workers: [
      'Agent Computer Worker プール · 1…N',
      'メイン Agent · バックグラウンドタスク · Automation Job · ツール · Skills · サンドボックス'
    ],
    postgres: ['PostgreSQL', 'アイデンティティ · セッション · メモリ · タスク · 監査'],
    home: ['Agent Home', 'ファイル · ワークスペース · 納品物'],
    caption:
      'コントロールプレーンは状態を保存し、作業の進め方を決定します。Worker は実際の計算環境を提供します。両者を分離することで、Agent の作業は特定のプロセスやマシンに依存しなくなります。'
  },
  'ko-KR': {
    title: 'Ankole 시스템 아키텍처',
    description:
      '엔터프라이즈 채널, 외부 이벤트, identity provider, Console, AI Provider가 control plane에 연결됩니다. control plane은 RuntimeFabric을 통해 하나 이상의 Agent Computer Worker를 스케줄링하고, durable 상태를 PostgreSQL과 Agent Home에 저장합니다.',
    external: '엔터프라이즈 및 외부 시스템',
    control: 'Control plane · 하나의 논리적 관리 경계',
    execution: '실행 계층 · 하나 이상의 Worker',
    data: '영속화 경계',
    channels: ['채팅 채널 및 외부 이벤트', '메시지 · Webhook · 일정 작업'],
    operators: ['Console 및 API', '운영자 · 엔터프라이즈 앱'],
    idp: ['Identity Provider', 'SSO · 디렉터리 · 조직'],
    providers: ['AI Provider', '모델 · 벡터 · 이미지 · Web'],
    signals: ['SignalsGateway', '시그널 라우팅 · 메시지 송수신'],
    identity: ['Principal 및 AuthZ', '아이덴티티 · 권한 · 설정 · 플러그인'],
    ai: ['AIGateway', '모델 선택 · 세션 · 자격 증명'],
    actor: ['Actor Runtime', '장기 세션 · 기상 · 복구'],
    brain: ['Brain', '월드 모델 · 회상 · Dreaming'],
    jobs: ['백그라운드 Agent 작업', '비차단 · 재개 가능 · 상호작용 가능'],
    fabric: 'RuntimeFabric · 실시간 제어, 사실은 저장하지 않음',
    workers: [
      'Agent Computer Worker 풀 · 1…N',
      '메인 Agent · 백그라운드 작업 · Automation Job · 툴 · Skills · 샌드박스'
    ],
    postgres: ['PostgreSQL', '아이덴티티 · 세션 · 메모리 · 작업 · 감사'],
    home: ['Agent Home', '파일 · 워크스페이스 · 산출물'],
    caption:
      'control plane은 상태를 저장하고 작업이 실행되는 방식을 결정합니다. Worker는 실제 컴퓨팅 환경을 제공합니다. 이 둘을 분리함으로써 Agent의 작업은 특정 프로세스나 머신에 의존하지 않게 됩니다.'
  }
}

type ControlNodeKey = 'signals' | 'identity' | 'ai' | 'actor' | 'brain' | 'jobs'

/** Control-plane nodes in diagram order, with the docs page that each one links to. */
export const ARCHITECTURE_CONTROL_NODES: readonly { key: ControlNodeKey; slug: string }[] = [
  { key: 'signals', slug: 'signals-gateway' },
  { key: 'identity', slug: 'principal-authz' },
  { key: 'ai', slug: 'ai-gateway' },
  { key: 'actor', slug: 'actor-runtime' },
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
