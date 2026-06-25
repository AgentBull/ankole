// @ts-nocheck
export function getModelPath(modelId: string): string {
  return modelId.includes('/') ? modelId : `models/${modelId}`
}
