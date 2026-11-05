import { beforeAll, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { I18nextProvider } from 'react-i18next'
import i18n, { loadLocale } from '../../common/i18n'
import { ChoiceCard } from './choice-card'
import { ClarifyForm, collect } from './clarify-form'
import type { ChatInteraction, ClarifyField, ClarifyPrompt } from './types'

beforeAll(() => loadLocale('en-US'))

const prompt: ClarifyPrompt = {
  state: 'pending',
  tool_call_id: 'call',
  interaction_id: 'source:clarify:call',
  question: 'How should the order ship?',
  choices: [],
  allow_free_text: true,
  fields: [
    { id: 'quantity', label: 'Quantity', type: 'number', required: true, integer: true, min: 1, max: 500, unit: 'kg' },
    { id: 'ship_date', label: 'Ship date', type: 'date', required: true, min: '2026-11-05' },
    {
      id: 'warehouses',
      label: 'Warehouses',
      type: 'multi_select',
      required: true,
      max_items: 2,
      options: [
        { value: 'us_west', label: 'US West' },
        { value: 'us_east', label: 'US East' }
      ]
    },
    {
      id: 'note',
      label: 'Note',
      type: 'text',
      required: false,
      max_length: 200,
      multiline: true,
      help: 'Anything else'
    },
    { id: 'rush', label: 'Rush', type: 'boolean', required: true }
  ]
}

function render(interaction: ChatInteraction, compose = true) {
  const client = new QueryClient()
  try {
    return renderToStaticMarkup(
      <I18nextProvider i18n={i18n}>
        <QueryClientProvider client={client}>
          <ChoiceCard
            prompt={prompt}
            interaction={interaction}
            onAnswer={async () => undefined}
            onComposeAnswer={compose ? () => undefined : undefined}
          />
        </QueryClientProvider>
      </I18nextProvider>
    ).replace(/[\u2066-\u2069]/g, '')
  } finally {
    client.clear()
  }
}

test('a pending form renders typed, labelled inputs and keeps the own-words escape', () => {
  const html = render(prompt)
  expect(html).toContain('class="pod-chat-choice-form"')
  expect(html).toContain('type="number"')
  expect(html).toContain('min="1"')
  expect(html).toContain('max="500"')
  expect(html).toContain('kg')
  expect(html).toContain('type="date"')
  expect(html).toContain('min="2026-11-05"')
  expect(html).toContain('US West')
  expect(html).toContain('role="checkbox"')
  expect(html).not.toContain('role="switch"')
  expect(html).toContain(i18n.t('pod.chat_form.choose'))
  expect(html).toContain('<textarea')
  expect(html).toContain('Anything else')
  expect(html).toContain(i18n.t('pod.chat_form.optional'))
  expect(html).toContain('aria-required="true"')
  expect(html).toContain(i18n.t('pod.chat_form.submit'))
  expect(html).toContain(i18n.t('pod.chat_timeline.compose_answer'))
  expect(html).not.toContain('pod-chat-choice-custom')
})

test('an answered form shows who answered and the readable summary instead of inputs', () => {
  const html = render({
    state: 'answered',
    answered_by_name: 'Dana',
    answer_text: 'Quantity: 300 kg · Warehouses: US West'
  })
  expect(html).toContain('Answered by Dana')
  expect(html).toContain('Quantity: 300 kg · Warehouses: US West')
  expect(html).not.toContain('pod-chat-choice-form')
  expect(html).not.toContain(i18n.t('pod.chat_timeline.compose_answer'))
})

test('every form error code a submission can return has a message', () => {
  for (const code of [
    'required',
    'too_long',
    'out_of_range',
    'invalid_date',
    'not_an_option',
    'too_few',
    'too_many',
    'not_an_integer',
    'invalid'
  ]) {
    expect(i18n.exists(`pod.chat_form.errors.${code}`)).toBe(true)
  }
})

test('a submission converts typed values and flags empty required fields before sending', () => {
  const fields = prompt.fields as ClarifyField[]
  expect(
    collect(fields, {
      quantity: ' 300 ',
      ship_date: '2026-11-20',
      warehouses: ['us_west'],
      note: '  fragile  ',
      rush: 'false'
    })
  ).toEqual({
    values: { quantity: 300, ship_date: '2026-11-20', warehouses: ['us_west'], note: 'fragile', rush: false },
    errors: {}
  })

  expect(collect(fields, { quantity: 'abc', ship_date: '', warehouses: [], note: '', rush: '' })).toEqual({
    values: {},
    errors: { quantity: 'invalid', ship_date: 'required', warehouses: 'required', rush: 'required' }
  })
})

test('server field errors render inline as alerts tied to their fields, with selection limits as hints', () => {
  const html = renderToStaticMarkup(
    <I18nextProvider i18n={i18n}>
      <ClarifyForm
        fields={prompt.fields as ClarifyField[]}
        disabled={false}
        errors={{ quantity: 'not_an_integer', warehouses: 'too_many' }}
        onSubmit={() => undefined}
      />
    </I18nextProvider>
  ).replace(/[\u2066-\u2069]/g, '')
  expect(html).toContain(i18n.t('pod.chat_form.errors.not_an_integer'))
  expect(html).toContain(i18n.t('pod.chat_form.errors.too_many'))
  expect(html.match(/role="alert"/g)?.length).toBe(2)
  expect(html.match(/aria-invalid="true"/g)?.length).toBeGreaterThanOrEqual(2)
  expect(html).toContain(i18n.t('pod.chat_form.items_max', { max: 2 }))
  expect(html).toMatch(/aria-describedby="[^"]*-quantity-error"/)
})
