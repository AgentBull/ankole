import { mkdir, readdir, writeFile } from 'node:fs/promises'
import { join, relative } from 'node:path'
import { chromium, expect } from '@playwright/test'
import { buildApplet, initializeApplet } from '../../../agent_computer/src/cli/pod/pod-applet'

const [mode, target, tableID] = process.argv.slice(2)
if (!target) throw new Error('Expected build directory or diagnostic URL')
if (mode === 'build') {
  const app = join(target, 'app')
  await initializeApplet(app)
  await mkdir(join(app, 'src/server'), { recursive: true })
  await writeFile(join(app, 'src/server/main.ts'), `export default {'GET /ready':()=>({ready:true})}`)
  await writeFile(
    join(app, 'src/main.tsx'),
    `import {useEffect,useState} from 'react';
import {defineApplet,usePod,useRecords,useAggregate,useRoute} from '@ankole/applet-sdk';
import {AddRegular} from '@ankole/uikit/icons';
function App(){
  const runtime=usePod();const [denied,setDenied]=useState(false);
  const records=useRecords(${JSON.stringify(tableID)});
  const total=useAggregate(${JSON.stringify(tableID)},{metrics:[{operation:'count',alias:'count'}]});
  const route=useRoute('GET /ready');
  useEffect(()=>{runtime.base.write(${JSON.stringify(tableID)},{creates:[]}).catch(()=>setDenied(true))},[]);
  return <main><AddRegular/><h1>Diagnostic orders</h1><p>{runtime.embedProps.region}</p>
    <p data-testid="records">{records.data?.records.length ?? 'pending'}</p>
    <p data-testid="aggregate">{total.data?.groups.length ?? 'pending'}</p>
    <p data-testid="route">{route.data?.ready ? 'ready' : 'pending'}</p>
    <p data-testid="write">{denied ? 'denied' : 'pending'}</p></main>
}
export const provider=defineApplet(App);`
  )
  const built = await buildApplet(app)
  const sources = (await readdir(join(app, 'src'), { recursive: true, withFileTypes: true }))
    .filter(entry => entry.isFile())
    .map(entry => relative(app, join(entry.parentPath, entry.name)))
  const files = [...sources, ...built.files]
  // The publication manifest paths are relative to the Applet root.
  await writeFile(join(target, 'manifest.json'), JSON.stringify(files))
} else if (mode === 'render') {
  const browser = await chromium.launch({
    executablePath:
      process.env.ANKOLE_BROWSER_TEST_CHROMIUM ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
  })
  try {
    const context = await browser.newContext()
    context.setDefaultTimeout(15_000)
    const page = await context.newPage()
    const errors: string[] = []
    const consoleErrors: string[] = []
    const failed: { url: string; status: number }[] = []
    page.on('pageerror', error => errors.push(error.message))
    page.on('console', message => {
      if (message.type() === 'error') consoleErrors.push(message.text())
    })
    page.on('requestfailed', request =>
      errors.push(`${new URL(request.url()).pathname.split('/').pop()}: ${request.failure()?.errorText}`)
    )
    page.on('response', response => {
      if (response.status() >= 400) failed.push({ url: response.url(), status: response.status() })
    })
    await page.goto(target)
    await page
      .waitForFunction(() => (window as any).__ANKOLE_APPLET_DIAGNOSTIC__?.mounted === true)
      .catch(async error => {
        const state = await page.evaluate(() => ({
          diagnostic: (window as any).__ANKOLE_APPLET_DIAGNOSTIC__,
          body: document.body.innerText.slice(0, 1000),
          scripts: [...document.scripts].map(script => script.src),
          frame: document.querySelector('iframe')?.contentDocument?.body?.innerText.slice(0, 1000)
        }))
        throw new Error(
          `${String(error)}; state: ${JSON.stringify(state)}; runtime errors: ${JSON.stringify(errors)}; console errors: ${JSON.stringify(consoleErrors)}; failed requests: ${JSON.stringify(failed)}`
        )
      })
    const frame = page.frameLocator('iframe')
    await expect(frame.getByRole('heading', { name: 'Diagnostic orders' })).toBeVisible()
    await expect(frame.locator('main > svg')).toBeVisible()
    await expect(frame.getByRole('heading', { name: 'Diagnostic orders' })).toHaveAttribute(
      'data-ankole-src',
      /^src\/main\.tsx:\d+$/
    )
    await expect(frame.getByText('华东', { exact: true })).toBeVisible()
    await expect(frame.getByTestId('records')).toHaveText('1')
    await expect(frame.getByTestId('aggregate')).toHaveText('1')
    await expect(frame.getByTestId('route')).toHaveText('ready')
    await expect(frame.getByTestId('write')).toHaveText('denied')
    expect(failed).toContainEqual(expect.objectContaining({ status: 403 }))
    expect(failed.filter(item => item.status !== 403)).toEqual([])
    expect(errors).toEqual([])
    expect(consoleErrors.filter(message => !message.includes('403'))).toEqual([])
    process.stdout.write('diagnostic browser passed\n')
  } finally {
    await browser.close()
  }
} else throw new Error('Expected build or render')
