import './clipboard'
import './commands'
import './composition'
import './content'
import './coords'
import './dom-changes'
import './editor'
import './input-events'
import './resolve-dom'
import './serialize'
import { runTests, type TestResult } from './runner'

declare global {
  interface Window {
    coreTestResults?: TestResult[]
  }
}

const results = runTests()
const failures = results.filter(result => result.error)
document.getElementById('results')!.textContent = [
  `${results.length - failures.length} passed, ${failures.length} failed`,
  ...failures.map(({ scope, name, error }) => `\n${[...scope, name].join(' > ')}\n${error}`)
].join('\n')
window.coreTestResults = results
