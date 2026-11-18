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
    title: 'OpenAnkole system architecture',
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
