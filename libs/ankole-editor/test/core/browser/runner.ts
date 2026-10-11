// Test registry for the core browser tests. The test page (index.html) imports the test modules, runs the
// registered tests in order and publishes the results for e2e/core.spec.ts.

export type TestResult = { scope: readonly string[]; name: string; error?: string }

const tests: { scope: readonly string[]; name: string; run: () => void }[] = []
const scope: string[] = []

export function describe(name: string, body: () => void) {
  scope.push(name)
  try {
    body()
  } finally {
    scope.pop()
  }
}

export function it(name: string, run: () => void) {
  tests.push({ scope: [...scope], name, run })
}

export function runTests(): TestResult[] {
  return tests.map(({ scope, name, run }) => {
    try {
      run()
      return { scope, name }
    } catch (error) {
      return { scope, name, error: error instanceof Error ? `${error.message}\n${error.stack ?? ''}` : String(error) }
    }
  })
}
