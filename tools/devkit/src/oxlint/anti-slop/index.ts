import { eslintCompatPlugin } from '@oxlint/plugins'
import { globalDataRule } from './rules/global-data.ts'
import { maxTernaryDepthRule } from './rules/max-ternary-depth.ts'
import { noChainedTypeAssertionsRule } from './rules/no-chained-type-assertions.ts'
import { noDisabledTypeAssertionRulesRule } from './rules/no-disabled-type-assertion-rules.ts'
import { noModuleMockingRule } from './rules/no-module-mocking.ts'
import { noReduceAccumulatorCopyRule } from './rules/no-reduce-accumulator-copy.ts'
import { noReflectApplyRule } from './rules/no-reflect-apply.ts'
import { noReflectGetRule } from './rules/no-reflect-get.ts'
import { noTestCodeInSrcRule } from './rules/no-test-code-in-src.ts'
import { noUnknownTypeAliasesRule } from './rules/no-unknown-type-aliases.ts'
import { noWidenThenAssertRule } from './rules/no-widen-then-assert.ts'

/** Ankole's Oxlint rules rejecting low-evidence TypeScript and boundary-bypass patterns. */
const antiSlopPlugin = eslintCompatPlugin({
  meta: { name: 'anti-slop' },
  rules: {
    'global-data': globalDataRule,
    'max-ternary-depth': maxTernaryDepthRule,
    'no-chained-type-assertions': noChainedTypeAssertionsRule,
    'no-disabled-type-assertion-rules': noDisabledTypeAssertionRulesRule,
    'no-module-mocking': noModuleMockingRule,
    'no-reduce-accumulator-copy': noReduceAccumulatorCopyRule,
    'no-reflect-apply': noReflectApplyRule,
    'no-reflect-get': noReflectGetRule,
    'no-test-code-in-src': noTestCodeInSrcRule,
    'no-unknown-type-aliases': noUnknownTypeAliasesRule,
    'no-widen-then-assert': noWidenThenAssertRule
  }
})

export default antiSlopPlugin
