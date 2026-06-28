import {
  UnsupportedFunctionalityError,
  type LanguageModelCallOptions,
  type LanguageModelFunctionTool,
  type SharedWarning
} from '@/ai-gateway-client/provider'
import type { ToolNameMapping } from '@/ai-gateway-client/provider-utils'
import type { OpenResponsesFunctionTool, OpenResponsesTool } from './open-responses-api'

type OpenResponsesToolOptions = {
  deferLoading?: boolean
  namespace?: {
    name: string
    description: string
  }
}

export async function prepareResponsesTools({
  tools,
  toolChoice,
  allowedTools,
  toolNameMapping
}: {
  tools: LanguageModelCallOptions['tools']
  toolChoice: LanguageModelCallOptions['toolChoice'] | undefined
  allowedTools?: {
    toolNames: string[]
    mode?: 'auto' | 'required'
  }
  toolNameMapping?: ToolNameMapping
}): Promise<{
  tools?: Array<OpenResponsesTool>
  toolChoice?:
    | 'auto'
    | 'none'
    | 'required'
    | { type: 'function'; name: string }
    | {
        type: 'allowed_tools'
        mode: 'auto' | 'required'
        tools: Array<{ type: 'function'; name: string }>
      }
  toolWarnings: SharedWarning[]
}> {
  // when the tools array is empty, change it to undefined to prevent errors:
  tools = tools?.length ? tools : undefined

  const toolWarnings: SharedWarning[] = []

  if (tools == null) {
    return { tools: undefined, toolChoice: undefined, toolWarnings }
  }

  const responsesTools: Array<OpenResponsesTool> = []
  const namespaceTools = new Map<string, Extract<OpenResponsesTool, { type: 'namespace' }>>()

  for (const tool of tools) {
    switch (tool.type) {
      case 'function': {
        const openResponsesOptions = tool.providerOptions?.openai as OpenResponsesToolOptions | undefined
        const openResponsesFunctionTool = prepareFunctionTool({
          tool,
          options: openResponsesOptions
        })
        const namespace = openResponsesOptions?.namespace

        if (namespace == null) {
          responsesTools.push(openResponsesFunctionTool)
        } else {
          let namespaceTool = namespaceTools.get(namespace.name)

          if (namespaceTool == null) {
            namespaceTool = {
              type: 'namespace',
              name: namespace.name,
              description: namespace.description,
              tools: []
            }
            namespaceTools.set(namespace.name, namespaceTool)
            responsesTools.push(namespaceTool)
          } else if (namespaceTool.description !== namespace.description) {
            throw new UnsupportedFunctionalityError({
              functionality: `conflicting descriptions for OpenResponses tool namespace "${namespace.name}"`
            })
          }

          namespaceTool.tools.push(openResponsesFunctionTool)
        }
        break
      }
      case 'provider': {
        toolWarnings.push({
          type: 'unsupported',
          feature: `provider tool ${tool.id}`
        })
        break
      }
      default:
        toolWarnings.push({
          type: 'unsupported',
          feature: `function tool ${tool}`
        })
        break
    }
  }

  if (allowedTools != null) {
    return {
      tools: responsesTools,
      toolChoice: {
        type: 'allowed_tools',
        mode: allowedTools.mode ?? 'auto',
        tools: allowedTools.toolNames.map(name => ({
          type: 'function',
          name: toolNameMapping?.toProviderToolName(name) ?? name
        }))
      },
      toolWarnings
    }
  }

  if (toolChoice == null) {
    return { tools: responsesTools, toolChoice: undefined, toolWarnings }
  }

  const type = toolChoice.type

  switch (type) {
    case 'auto':
    case 'none':
    case 'required':
      return { tools: responsesTools, toolChoice: type, toolWarnings }
    case 'tool': {
      const resolvedToolName = toolNameMapping?.toProviderToolName(toolChoice.toolName) ?? toolChoice.toolName

      return {
        tools: responsesTools,
        toolChoice: { type: 'function', name: resolvedToolName },
        toolWarnings
      }
    }
    default: {
      const _exhaustiveCheck: never = type
      throw new UnsupportedFunctionalityError({
        functionality: `tool choice type: ${_exhaustiveCheck}`
      })
    }
  }
}

function prepareFunctionTool({
  tool,
  options
}: {
  tool: LanguageModelFunctionTool
  options: OpenResponsesToolOptions | undefined
}): OpenResponsesFunctionTool {
  const deferLoading = options?.deferLoading

  return {
    type: 'function',
    name: tool.name,
    description: tool.description,
    parameters: tool.inputSchema,
    ...(tool.strict != null ? { strict: tool.strict } : {}),
    ...(deferLoading != null ? { defer_loading: deferLoading } : {})
  }
}
