import { expect, test } from 'bun:test'
import { automationJobDetailParams } from './automation-jobs'

test('Job details identify the global Job without an Agent scope', () => {
  const selected = automationJobDetailParams(new URLSearchParams('agent=retired&include_finished=true'), { id: '1000' })
  expect(selected.get('job')).toBe('1000')
  expect(selected.has('agent')).toBe(false)
  expect(selected.get('include_finished')).toBe('true')
})
