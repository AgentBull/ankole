import 'reflect-metadata'
import { startBullXAgent, startWebServer } from '@/core'

await startBullXAgent()
await startWebServer()
