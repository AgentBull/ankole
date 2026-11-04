import { expect, test } from 'bun:test'
import currentDateTime from './fixtures/current_date_time_metadata.json'
import { toolContract, toolSchemas } from './sync-catalog'

test('formal metadata preserves output references and optional fields', () => {
  const schemas = toolSchemas({
    input_parameters: { type: 'object', properties: {} },
    output_parameters: currentDateTime.output_parameters
  })
  const result = schemas.output_schema.$defs.GetCurrentDateTimeResponse
  expect(result.type).toBe('object')
  expect(result.required).toEqual(['current_datetime', 'yyyymmdd_datetime'])
  expect(result.properties.current_datetime.type).toBe('string')
  expect(result.properties.display_url.type).toBe('string')
  expect(schemas.output_schema.properties.result.$ref).toBe('#/$defs/GetCurrentDateTimeResponse')
})

test('input unions, required fields and shared definitions remain executable schemas', () => {
  const { input_schema } = toolSchemas({
    input_parameters: {
      type: 'object',
      $defs: { Choice: { anyOf: [{ type: 'string' }, { type: 'number' }] } },
      properties: {
        timezone: { $ref: '#/$defs/Choice', default: 0 },
        explicit_null: { anyOf: [{ type: 'string' }, { type: 'null' }] }
      },
      required: ['timezone']
    },
    output_parameters: currentDateTime.output_parameters
  })
  expect(input_schema.required).toEqual(['timezone'])
  expect(input_schema.$defs.Choice.anyOf).toEqual([{ type: 'string' }, { type: 'number' }])
  expect(input_schema.properties.timezone.default).toBe(0)
  expect(input_schema.properties.explicit_null.anyOf[1]).toEqual({ type: 'null' })
})

test('presentation-only metadata cannot silently replace a full contract', () => {
  expect(() => toolSchemas({ input_parameters: {}, output_parameters: { data: { description: 'Data' } } })).toThrow(
    'full input and output JSON Schemas'
  )
})

test('recursive provider definitions remain named references', () => {
  const recursive = {
    type: 'object',
    $defs: {
      Attachment: {
        type: 'object',
        properties: { thumbnails: { type: 'array', items: { $ref: '#/$defs/Attachment' } } }
      }
    },
    properties: { data: { $ref: '#/$defs/Attachment' } }
  }
  const { output_schema } = toolSchemas({
    input_parameters: { type: 'object', properties: {} },
    output_parameters: recursive
  })
  expect(output_schema.$defs.Attachment.properties.thumbnails.items.$ref).toBe('#/$defs/Attachment')
  expect(output_schema.properties.result.$ref).toBe('#/$defs/Attachment')
})

test('bulk-operation guidance points to the selected ticket job-status tool', () => {
  const contract = toolContract('zendesk', '20261101_00', {
    slug: 'ZENDESK_BULK_CREATE_TICKETS',
    version: '20261101_00',
    is_deprecated: false,
    tags: ['idempotentHint'],
    description: 'Use ZENDESK_GET_APPS_JOB_STATUS to check completion.',
    input_parameters: {
      type: 'object',
      description: 'Use ZENDESK_GET_APPS_JOB_STATUS to check completion.'
    },
    output_parameters: currentDateTime.output_parameters
  })
  expect(contract.description).toBe('Use zendesk.get_job_statuses2 to check completion.')
  expect(contract.input_schema.description).toBe(contract.description)
  expect(contract.name).toBe('bulk_create_tickets')
  expect(contract.scopes).toEqual([])
  expect(contract.annotations.idempotentHint).toBe(true)
})
