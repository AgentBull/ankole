import { beforeEach, describe, expect, test } from "@rstest/core"
import { clearMf2CacheForTest, formatMf2ForTest, mf2CacheSizeForTest } from "./mf2"

describe("MF2 post-processor", () => {
  beforeEach(() => {
    clearMf2CacheForTest()
  })

  test("renders MF2 match messages with safe markup", () => {
    const source = `
.input {$count :number}
.match $count
  1 {{{#strong}1{/strong} item}}
  * {{{#strong}{$count}{/strong} items}}
`

    expect(formatMf2ForTest(source, { count: 2 })).toBe("<strong>2</strong> items")
  })

  test("normalizes supported curly tag aliases on fallback", () => {
    expect(formatMf2ForTest("{#bold}broken{/bold}", {})).toBe("<strong>broken</strong>")
  })

  test("caches compiled messages by locale and source", () => {
    formatMf2ForTest("Hello {$name}", { name: "Ada" }, "en-US")
    formatMf2ForTest("Hello {$name}", { name: "Grace" }, "en-US")
    formatMf2ForTest("Hello {$name}", { name: "Ada" }, "zh-Hans-CN")

    expect(mf2CacheSizeForTest()).toBe(2)
  })

  test("falls back to visible source on format failure", () => {
    expect(formatMf2ForTest("Hello {$name}", {})).toBe("Hello {$name}")
  })
})
