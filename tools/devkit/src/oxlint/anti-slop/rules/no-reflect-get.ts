import { defineRule } from '@oxlint/plugins'
import type { ESTree, SourceCode } from '@oxlint/plugins'
import { isGlobalReflectMethodCall } from '../shared/reflect-method.ts'
import { resolveVariable } from '../shared/scope.ts'

function isGlobalProxy(sourceCode: SourceCode, expression: ESTree.Expression): boolean {
  if (expression.type !== 'Identifier' || expression.name !== 'Proxy') return false
  if (sourceCode.isGlobalReference(expression)) return true
  const variable = resolveVariable(sourceCode, expression)
  return variable === null || variable.defs.length === 0
}

function isProxyConstructorOrRevocable(sourceCode: SourceCode, node: ESTree.Node, handler: ESTree.Node): boolean {
  if (node.type === 'NewExpression') {
    return isGlobalProxy(sourceCode, node.callee) && node.arguments[1] === handler
  }
  if (node.type !== 'CallExpression') return false
  const { callee } = node
  if (callee.type !== 'MemberExpression' || !isGlobalProxy(sourceCode, callee.object)) return false
  const isRevocable = callee.computed
    ? callee.property.type === 'Literal' && callee.property.value === 'revocable'
    : callee.property.type === 'Identifier' && callee.property.name === 'revocable'
  return isRevocable && node.arguments[1] === handler
}

function hasProxyHandlerAnnotation(annotation: ESTree.TSTypeAnnotation | null | undefined): boolean {
  const type = annotation?.typeAnnotation
  return (
    type?.type === 'TSTypeReference' && type.typeName.type === 'Identifier' && type.typeName.name === 'ProxyHandler'
  )
}

function isProxyHandlerObject(sourceCode: SourceCode, objectExpr: ESTree.ObjectExpression): boolean {
  let current: ESTree.Node = objectExpr
  let { parent } = current
  while (
    parent.type === 'ParenthesizedExpression' ||
    parent.type === 'TSSatisfiesExpression' ||
    parent.type === 'TSAsExpression'
  ) {
    if (parent.type === 'TSSatisfiesExpression' || parent.type === 'TSAsExpression') {
      if (
        parent.typeAnnotation.type === 'TSTypeReference' &&
        parent.typeAnnotation.typeName.type === 'Identifier' &&
        parent.typeAnnotation.typeName.name === 'ProxyHandler'
      ) {
        return true
      }
    }
    current = parent
    parent = current.parent
  }
  if (isProxyConstructorOrRevocable(sourceCode, parent, current)) return true
  if (parent.type === 'VariableDeclarator' && parent.init === current && parent.id.type === 'Identifier') {
    if (hasProxyHandlerAnnotation(parent.id.typeAnnotation)) return true
    const variable = sourceCode.getDeclaredVariables(parent)[0]
    if (variable !== undefined) {
      return variable.references.some(
        ref => !ref.init && isProxyConstructorOrRevocable(sourceCode, ref.identifier.parent, ref.identifier)
      )
    }
  }
  return false
}

function isInsideProxyGetTrap(sourceCode: SourceCode, node: ESTree.Node): boolean {
  let current: ESTree.Node | null = node.parent
  while (current !== null && current.type !== 'Program') {
    if (current.type === 'FunctionExpression' || current.type === 'ArrowFunctionExpression') {
      const prop = current.parent
      if (
        prop.type === 'Property' &&
        prop.value === current &&
        !prop.computed &&
        ((prop.key.type === 'Identifier' && prop.key.name === 'get') ||
          (prop.key.type === 'Literal' && prop.key.value === 'get')) &&
        prop.parent.type === 'ObjectExpression' &&
        isProxyHandlerObject(sourceCode, prop.parent)
      ) {
        return true
      }
    }
    current = current.parent
  }
  return false
}

/** Ban Reflect.get outside Proxy `get` traps, where receiver-preserving forwarding is required. */
export const noReflectGetRule = defineRule({
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow Reflect.get outside Proxy `get` handler traps; use typed property access or parse dynamic input into a domain type.'
    },
    messages: {
      reflectGet:
        'Replace `Reflect.get` with typed property access. Parse dynamic input into a named domain type before reading it (`Reflect.get` is permitted only inside `Proxy` `get` traps).'
    }
  },
  createOnce(context) {
    return {
      CallExpression(node) {
        if (node.callee.type === 'Super' || node.callee.type === 'V8IntrinsicExpression') return
        if (!isGlobalReflectMethodCall(context.sourceCode, node.callee, 'get')) return
        if (isInsideProxyGetTrap(context.sourceCode, node)) return
        context.report({ node, messageId: 'reflectGet' })
      }
    }
  }
})
