import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { metaKeys } from '../meta-api'
import { selectedCompletionIndex } from './composer-completion'
import { SlashCommandPicker } from './slash-command-picker'

beforeAll(() => loadLocale('en-US'))

const skill = (slug: string, name: string, description = '') => ({
  slug,
  name,
  description,
  agent_uid: null,
  runtime_agent_uids: ['researcher'],
  runtime_assistant_enabled: false
})

/** Renders the picker right after `/`, before the Skills answer arrives or after it is already cached. */
function render(skills?: ReturnType<typeof skill>[], query = '') {
  const client = new QueryClient()
  if (skills) client.setQueryData(metaKeys.skills(), { skills })
  try {
    return renderToStaticMarkup(
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={client}>
          <SlashCommandPicker
            existing
            working={false}
            targetAgentUID="researcher"
            query={query}
            id="slash"
            input={{ current: null }}
            handle={{ current: null }}
            onChoose={() => {}}
            onChooseSkill={() => {}}
            onClose={() => {}}
          />
        </QueryClientProvider>
      </I18nextProvider>
    )
  } finally {
    client.clear()
  }
}

const selected = (html: string) => /aria-selected="true"[^>]*>(.*?)<\/button>/.exec(html)?.[1]

test('the slash menu selects the same first command on a slow and on a fast Skills load', () => {
  const slow = render()
  const fast = render([
    skill('ankole-ops', 'ankole-ops', 'Operate the Ankole deployment'),
    skill('brief', 'Daily brief')
  ])
  expect(selected(slow)).toContain('/new')
  expect(selected(fast)).toBe(selected(slow))
  // Commands stay first; Skills follow under their own heading.
  expect(fast.indexOf('/rename')).toBeLessThan(fast.indexOf(`>${i18n.t('pod.meta.skills')}</div>`))
  // A Skill shows its title with the slug beside it, and a Skill without a separate title shows its slug once.
  expect(fast).toContain('Daily brief</span><span class="shrink-0 font-mono text-xs text-fg-tertiary">/brief</span>')
  expect(fast.match(/ankole-ops/g)).toHaveLength(1)
})

test('typing filters both groups', () => {
  const html = render([skill('brief', 'Daily brief'), skill('rename-files', 'Rename files')], 'ren')
  expect(html).toContain('/rename')
  expect(html).toContain('Rename files')
  expect(html).not.toContain('Daily brief')
  expect(html).not.toContain('/new')
})

test('a selection follows its option when results arrive or reorder, and falls back to the first option', () => {
  const commands = [{ id: 'cmd:new' }, { id: 'cmd:learn' }, { id: 'cmd:invite' }]
  const chosen = { query: '', id: 'cmd:learn', armed: true }
  expect(selectedCompletionIndex(commands, chosen, '')).toBe(1)
  expect(selectedCompletionIndex([{ id: 'agent:a' }, ...commands], chosen, '')).toBe(2)
  expect(selectedCompletionIndex([{ id: 'cmd:new' }], chosen, '')).toBe(0)
  expect(selectedCompletionIndex(commands, chosen, 'in')).toBe(0)
  expect(selectedCompletionIndex(commands, { query: '', armed: false }, '')).toBe(0)
})
