import { describe, expect, it } from 'bun:test'
import { anyAscii } from '../../../index.js'

describe('anyAscii', () => {
  it('should convert any unicode string to ascii', () => {
    const ascii = anyAscii('吾心光明，亦复何言 Bazinga! 😄 화성시 Blöße')
    expect(ascii).toBe('WuXinGuangMing,YiFuHeYan Bazinga! :smile: HwaSeongSi Blosse')
  })
})
