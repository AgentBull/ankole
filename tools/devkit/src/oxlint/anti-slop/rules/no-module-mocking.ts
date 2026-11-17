import { defineRule } from '@oxlint/plugins'
import type { ESTree, SourceCode } from '@oxlint/plugins'
import { resolveVariable } from '../shared/scope.ts'

const jestVitestMockMethods = new Set(['doMock', 'mock', 'unstable_mockModule'])

function importedName(node: ESTree.Node): string | null {
  if (node.type !== 'ImportSpecifier') return null
  return node.imported.type === 'Identifier' ? node.imported.name : node.imported.value
}

function memberMethodName(callee: ESTree.Expression): { object: ESTree.Expression; method: string } | null {
  if (!('property' in callee) || !('object' in callee) || !('computed' in callee)) return null
  const { property } = callee
  if (callee.computed) {
    return property.type === 'Literal' && typeof property.value === 'string'
      ? { object: callee.object, method: property.value }
      : null
  }
  return property.type === 'Identifier' ? { object: callee.object, method: property.name } : null
}

function isVitestOrJestObject(sourceCode: SourceCode, expression: ESTree.Expression): boolean {
  if (expression.type !== 'Identifier') return false
  if ((expression.name === 'vi' || expression.name === 'jest') && sourceCode.isGlobalReference(expression)) {
    return true
  }

  const variable = resolveVariable(sourceCode, expression)
  if (variable === null || variable.defs.length === 0) {
    return expression.name === 'vi' || expression.name === 'jest'
  }
  return variable.defs.some(definition => {
    if (definition.type !== 'ImportBinding' || definition.parent?.type !== 'ImportDeclaration') {
      return false
    }
    const source = definition.parent.source.value
    const name = importedName(definition.node)
    return (
      (source === 'vitest' && name === 'vi') ||
      ((source === '@jest/globals' || source === 'bun:test') && name === 'jest')
    )
  })
}

function isBunMockObject(sourceCode: SourceCode, expression: ESTree.Expression): boolean {
  if (expression.type === 'Identifier') {
    const variable = resolveVariable(sourceCode, expression)
    if (variable === null) return false
    return variable.defs.some(definition => {
      if (definition.type !== 'ImportBinding' || definition.parent?.type !== 'ImportDeclaration') {
        return false
      }
      return definition.parent.source.value === 'bun:test' && importedName(definition.node) === 'mock'
    })
  }
  const outer = memberMethodName(expression)
  if (outer === null || outer.method !== 'mock' || outer.object.type !== 'Identifier') return false
  const variable = resolveVariable(sourceCode, outer.object)
  if (variable === null) return false
  return variable.defs.some(
    definition =>
      definition.type === 'ImportBinding' &&
      definition.parent?.type === 'ImportDeclaration' &&
      definition.parent.source.value === 'bun:test' &&
      definition.node.type === 'ImportNamespaceSpecifier'
  )
}

function isModuleMockCall(sourceCode: SourceCode, callee: ESTree.Expression): boolean {
  const target = memberMethodName(callee)
  if (target === null) return false
  if (jestVitestMockMethods.has(target.method) && isVitestOrJestObject(sourceCode, target.object)) {
    return true
  }
  return target.method === 'module' && isBunMockObject(sourceCode, target.object)
}

function compiledSpecifierPatterns(option: unknown): readonly RegExp[] {
  if (typeof option !== 'object' || option === null || !('allowSpecifierPatterns' in option)) return []
  const { allowSpecifierPatterns } = option
  if (!Array.isArray(allowSpecifierPatterns)) return []
  return allowSpecifierPatterns
    .filter((item): item is string => typeof item === 'string' && item.length > 0)
    .map(pattern => new RegExp(pattern, 'u'))
}

function hasAllowedSpecifier(node: ESTree.CallExpression, patterns: readonly RegExp[]): boolean {
  if (patterns.length === 0) return false
  const firstArg = node.arguments[0]
  if (firstArg?.type !== 'Literal' || typeof firstArg.value !== 'string') return false
  return patterns.some(pattern => pattern.test(firstArg.value))
}

/** Ban Bun, Vitest, and Jest module mocking in favor of real dependency seams. */
export const noModuleMockingRule = defineRule({
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow Bun, Vitest, and Jest module mocking; tests must replace dependencies through real interfaces.'
    },
    messages: {
      moduleMock:
        'Replace module mocking (`mock.module` / `vi.mock` / `jest.mock`) with dependency injection through a real domain interface or faithful adapter fake; `mock.module` also mutates Bun’s process-global module cache.'
    },
    schema: [
      {
        type: 'object',
        properties: {
          allowSpecifierPatterns: {
            type: 'array',
            items: { type: 'string', minLength: 1 },
            uniqueItems: true
          }
        },
        additionalProperties: false
      }
    ],
    defaultOptions: [{ allowSpecifierPatterns: [] }]
  },
  createOnce(context) {
    return {
      CallExpression(node) {
        if (node.callee.type === 'Super' || node.callee.type === 'V8IntrinsicExpression') return
        if (!isModuleMockCall(context.sourceCode, node.callee)) return
        const patterns = compiledSpecifierPatterns(context.options?.[0])
        if (hasAllowedSpecifier(node, patterns)) return
        context.report({ node, messageId: 'moduleMock' })
      }
    }
  }
})
