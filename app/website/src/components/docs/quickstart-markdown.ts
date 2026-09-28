import {
  blockquote,
  blocks,
  bulletList,
  type ComponentMarkdownContext,
  type ComponentMarkdownRenderer,
  fence,
  heading,
  inlineCode,
  requiredProp
} from '../../lib/markdown-text'
import type { QuickstartLabels, QuickstartSection, QuickstartStep, QuickstartTab } from './QuickstartTabs'

/*
 * The page shows one tab and keeps advanced sections closed. The Markdown writes every tab and
 * every section in order, because an agent cannot click a tab and needs each option to choose one.
 */

export const renderQuickstartAgentPrompt: ComponentMarkdownRenderer = props =>
  fence(requiredProp<string>(props, 'prompt'), 'text')

export const renderQuickstartTabs: ComponentMarkdownRenderer = (props, context) => {
  const tabs = requiredProp<QuickstartTab[]>(props, 'tabs')
  const labels = requiredProp<QuickstartLabels>(props, 'labels')

  return blocks(
    `**${requiredProp<string>(props, 'ariaLabel')}**`,
    bulletList(tabs.map(tabLabel)),
    ...tabs.map(tab => renderTab(tab, labels, context.depth + 1, context))
  )
}

export const renderQuickstartDisclosure: ComponentMarkdownRenderer = (props, context) =>
  renderSection(
    requiredProp<QuickstartSection>(props, 'section'),
    requiredProp<QuickstartLabels>(props, 'labels').advancedSettings,
    context.depth + 1,
    context
  )

function renderTab(tab: QuickstartTab, labels: QuickstartLabels, depth: number, context: ComponentMarkdownContext) {
  return blocks(
    heading(depth, tabLabel(tab)),
    tab.summary,
    tab.alert && blockquote(blocks(`**${tab.alert.title}**`, ...tab.alert.body)),
    tab.prerequisites?.length ? blocks(`**${labels.prerequisites}**`, bulletList(tab.prerequisites)) : undefined,
    renderSection(tab.basic, labels.basicSettings, depth + 1, context),
    tab.advanced && renderSection(tab.advanced, labels.advancedSettings, depth + 1, context)
  )
}

function renderSection(section: QuickstartSection, kind: string, depth: number, context: ComponentMarkdownContext) {
  return blocks(
    heading(depth, `${kind} · ${section.title}`),
    section.summary,
    section.intro,
    ...section.steps.map((step, index) => renderStep(step, index + 1, depth + 1, context))
  )
}

function renderStep(step: QuickstartStep, number: number, depth: number, context: ComponentMarkdownContext) {
  return blocks(
    heading(depth, `${number}. ${step.title}`),
    ...(step.body ?? []),
    bulletList(step.bullets),
    step.batchImport && blocks(`**${step.batchImport.label}**`, fence(step.batchImport.content, 'text')),
    bulletList(
      step.copyItems?.map(item =>
        item.description ? `${inlineCode(item.value)} — ${item.description}` : inlineCode(item.value)
      )
    ),
    bulletList(
      step.fields?.map(
        field => `${inlineCode(field.name)}${field.value ? `: ${inlineCode(field.value)}` : ''} — ${field.description}`
      )
    ),
    ...(step.code ?? []).map(block => fence(block.code, block.language)),
    step.caution && blockquote(step.caution),
    bulletList(step.links?.map(link => `[${link.label}](${context.link(link.href)})`))
  )
}

function tabLabel(tab: QuickstartTab) {
  return tab.badge ? `${tab.label} · ${tab.badge}` : tab.label
}
