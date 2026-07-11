import { describe, expect, it } from 'bun:test'
import { rpcContractEntries, rpcContractPath } from '../scripts/gen-rpc-contract'

describe('RuntimeFabric RPC contract parity', () => {
  it('matches the committed rpc_methods.json; regenerate with `bun run gen:rpc-contract`', async () => {
    const committed = await Bun.file(rpcContractPath).json()
    expect(committed).toEqual(rpcContractEntries())
  })
})
