import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

const [tableID, amountFieldID, statusFieldID, output] = process.argv.slice(2)
if (!tableID || !amountFieldID || !statusFieldID || !output) {
  throw new Error('Expected table ID, amount field ID, status field ID, and an absolute output directory')
}
await mkdir(output, { recursive: true })
const manifests: Record<string, { path: string; local_path: string; content_type: string }[]> = {}
for (const revision of ['v1', 'v2']) {
  const directory = path.join(output, revision)
  await mkdir(directory, { recursive: true })
  const source = `import {defineApplet,useRecords,useChannel} from '@ankole/applet-sdk';
import {Button} from '@ankole/uikit';
import {useState} from 'react';
function App(){
  const rows=useRecords(${JSON.stringify(tableID)});
  const room=useChannel('browser-room');
  const [count,setCount]=useState(0);
  return <section className="applet-shell"><h2 className="applet-heading">Tracker ${revision}</h2>
  <p className="applet-record-count">{rows.data?.records.length??0} records</p>
  <p className="applet-presence">{room.presence.length} online</p>
  <div className="applet-actions">
  <Button onClick={()=>setCount(n=>n+1)}>Local counter {count}</Button>
  <Button disabled={rows.write.isPending} onClick={()=>{void rows.create({[${JSON.stringify(amountFieldID)}]:11,[${JSON.stringify(statusFieldID)}]:'new'}).catch(()=>{})}}>Add sample</Button>
  </div>
  {rows.write.error?<p role="alert">Write rejected</p>:null}
  <div className="applet-records">{rows.data?.records.map(record=><p key={record.id}>{String(record.data[${JSON.stringify(amountFieldID)}]??'')}</p>)}</div>
  </section>
}
export const provider=defineApplet(App);`
  const entry = path.join(directory, 'applet.tsx')
  await writeFile(entry, source)
  const result = await Bun.build({
    entrypoints: [entry],
    outdir: directory,
    target: 'browser',
    format: 'cjs',
    jsx: { runtime: 'automatic', development: false },
    define: { 'process.env.NODE_ENV': '"production"' },
    naming: 'applet.js',
    external: [
      'react',
      'react/jsx-runtime',
      'react/jsx-dev-runtime',
      'react-dom',
      'react-dom/client',
      '@ankole/uikit',
      '@ankole/applet-sdk'
    ]
  })
  if (!result.success) throw new AggregateError(result.logs, 'Could not build the real SDK browser applet')
  await writeFile(
    path.join(directory, 'applet.css'),
    `.ankole-applet .applet-shell{display:grid;gap:8px;padding:16px;border:1px solid var(--color-border)}.ankole-applet .applet-actions{display:flex;gap:12px}.ankole-applet .applet-heading{color:${revision === 'v1' ? 'teal' : 'purple'}}`
  )
  await writeFile(
    path.join(directory, 'index.html'),
    '<!doctype html><html><head><link rel="stylesheet" href="./applet.css"><script src="./applet.js"></script></head><body></body></html>'
  )
  manifests[revision] = [
    { path: 'src/applet.tsx', local_path: entry, content_type: 'text/plain' },
    ...['index.html', 'applet.js', 'applet.css'].map(name => ({
      path: `dist/${name}`,
      local_path: path.join(directory, name),
      content_type: name.endsWith('.html') ? 'text/html' : name.endsWith('.js') ? 'text/javascript' : 'text/css'
    }))
  ]
}
await writeFile(path.join(output, 'manifests.json'), JSON.stringify(manifests, null, 2))
process.stdout.write(`${path.join(output, 'manifests.json')}\n`)
