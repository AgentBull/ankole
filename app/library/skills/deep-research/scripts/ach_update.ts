import { computeACH, type ACHInput } from './ach'

const inputPath = Bun.argv[2]
if (!inputPath) throw new Error('usage: bun ach_update.ts <ach-input.json>')
const input = (await Bun.file(inputPath).json()) as ACHInput
process.stdout.write(`${JSON.stringify(computeACH(input), null, 2)}\n`)
