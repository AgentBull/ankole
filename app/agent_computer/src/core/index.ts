// Tool-authoring surface for the Agent Computer core: the types needed to
// build tools plus `defineWorkerTool`. Keep this import-light — authoring a
// tool must not pull in the runtime that runs it, so `runTurnHandlers`
// (`./turns`) and the provider loop (`./agent-loop`) are imported from their
// own modules by the worker entrypoint only.

export * from './types'
export { defineWorkerTool, type DefineWorkerToolSpec } from './worker-tool'
