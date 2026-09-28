import {
  blocks,
  bulletList,
  type ComponentMarkdownContext,
  type ComponentMarkdownRenderer,
  heading,
  orderedList,
  requiredProp
} from '../../lib/markdown-text'
import type { FaqIssue, FaqLabels, FaqProviderTab } from './FaqProviderTabs'

export const renderFaqIssueList: ComponentMarkdownRenderer = (props, context) => {
  const labels = requiredProp<FaqLabels>(props, 'labels')
  return blocks(
    ...requiredProp<FaqIssue[]>(props, 'issues').map(issue => renderIssue(issue, labels, context.depth + 1, context))
  )
}

/** Writes every provider tab, because an agent cannot select one. */
export const renderFaqProviderTabs: ComponentMarkdownRenderer = (props, context) => {
  const tabs = requiredProp<FaqProviderTab[]>(props, 'tabs')
  const labels = requiredProp<FaqLabels>(props, 'labels')

  return blocks(
    `**${requiredProp<string>(props, 'ariaLabel')}**`,
    bulletList(tabs.map(tab => tab.label)),
    ...tabs.map(tab =>
      blocks(
        heading(context.depth + 1, tab.label),
        ...tab.issues.map(issue => renderIssue(issue, labels, context.depth + 2, context))
      )
    )
  )
}

function renderIssue(issue: FaqIssue, labels: FaqLabels, depth: number, context: ComponentMarkdownContext) {
  return blocks(
    heading(depth, issue.question),
    `**${labels.symptom}**`,
    issue.symptom,
    `**${labels.cause}**`,
    issue.cause,
    `**${labels.resolution}**`,
    orderedList(issue.resolution),
    bulletList(issue.links?.map(link => `[${link.label}](${context.link(link.href)})`))
  )
}
