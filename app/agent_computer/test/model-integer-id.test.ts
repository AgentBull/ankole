import { expect, test } from 'bun:test'
import vectors from '../../kernel/proto/ankole/runtime_fabric/v1/model_integer_id_vectors.json'
import { ModelIntegerID, modelIntegerIDFromWire, modelIntegerIDToWire } from '../src/core/model-integer-id'

test('matches the control-plane canonical integer ID contract', () => {
  for (const value of vectors.valid) {
    expect(ModelIntegerID.parse(value)).toBe(value)
    expect(modelIntegerIDToWire(value)).toBe(String(value))
  }
  for (const value of vectors.invalid) expect(ModelIntegerID.safeParse(value).success).toBe(false)
  for (const value of vectors.valid_wire) expect(modelIntegerIDFromWire(value, 'id')).toBe(Number(value))
  for (const value of vectors.invalid_wire) expect(() => modelIntegerIDFromWire(value, 'id')).toThrow()
})
