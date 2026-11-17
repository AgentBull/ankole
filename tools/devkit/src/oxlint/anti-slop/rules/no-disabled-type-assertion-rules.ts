import { defineRule } from '@oxlint/plugins'

/** The rules that prevent type laundering and test-boundary bypasses. */
const defaultProtectedRules = [
  'anti-slop/no-chained-type-assertions',
  'anti-slop/no-module-mocking',
  'anti-slop/no-reflect-apply',
  'anti-slop/no-reflect-get',
  'anti-slop/no-unknown-type-aliases',
  'anti-slop/no-widen-then-assert',
  'typescript/consistent-type-assertions',
  'typescript/no-unsafe-type-assertion'
]

const directivePattern = /^\s*(?:oxlint|eslint)-disable(?:-next-line|-line)?(?=\s|$)(.*)$/su

/** Rule names are compared with `@typescript-eslint/` read as `typescript/`. */
function normalizeRuleName(rule: string): string {
  return rule.trim().replace(/^@?typescript-eslint\//u, 'typescript/')
}

/** The rule names a disable directive lists, or null when the comment is not a disable directive. */
function directiveRules(value: string): readonly string[] | null {
  const match = directivePattern.exec(value)
  if (match === null) return null
  const list = (match[1] ?? '').split(/\s--\s|\s--$/u)[0] ?? ''
  return list
    .split(',')
    .map(normalizeRuleName)
    .filter(rule => rule.length > 0)
}

function configuredAdditionalRules(option: unknown): readonly string[] {
  if (typeof option !== 'object' || option === null || !('additionalRules' in option)) return []
  const { additionalRules } = option
  if (!Array.isArray(additionalRules)) return []
  return additionalRules.filter((rule): rule is string => typeof rule === 'string').map(normalizeRuleName)
}

/** Disallow inline disables of protected anti-slop rules, and disables that name no rule at all. */
export const noDisabledTypeAssertionRulesRule = defineRule({
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow inline disable comments for protected anti-slop rules, and disable comments that name no rule.'
    },
    messages: {
      disabledRule:
        "Don't disable `{{rule}}` inline. Fix the boundary contract, or declare an explicit file override in `.oxlintrc.json`.",
      disabledEverything:
        'This disable comment names no rule, so it turns off protected type-safety rules too. Name the specific rules it disables.'
    },
    schema: [
      {
        type: 'object',
        properties: {
          additionalRules: { type: 'array', items: { type: 'string', minLength: 1 }, uniqueItems: true }
        },
        additionalProperties: false
      }
    ],
    defaultOptions: [{ additionalRules: [] }]
  },
  createOnce(context) {
    return {
      Program() {
        const protectedRules = new Set([...defaultProtectedRules, ...configuredAdditionalRules(context.options?.[0])])
        for (const comment of context.sourceCode.getAllComments()) {
          const rules = directiveRules(comment.value)
          if (rules === null) continue
          if (rules.length === 0) {
            context.report({ node: comment, messageId: 'disabledEverything' })
            continue
          }
          for (const rule of rules) {
            if (!protectedRules.has(rule)) continue
            context.report({ node: comment, messageId: 'disabledRule', data: { rule } })
          }
        }
      }
    }
  }
})
