import { mkdir, readdir, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { buildApplet, initializeApplet } from '../../../agent_computer/src/cli/pod/pod-cli'

const [tableID, amountFieldID, statusFieldID, output] = process.argv.slice(2)
if (!tableID || !amountFieldID || !statusFieldID || !output) {
  throw new Error('Expected table ID, amount field ID, status field ID, and an absolute output directory')
}
await mkdir(output, { recursive: true })
const manifests: Record<string, { path: string; local_path: string; content_type: string }[]> = {}
for (const revision of ['v1', 'v2']) {
  const directory = path.join(output, revision)
  await rm(directory, { recursive: true, force: true })
  await mkdir(directory, { recursive: true })
  await initializeApplet(directory)
  const source = `import {defineApplet,useRecords,useChannel} from '@ankole/applet-sdk';
import {Button,Input,Dialog,DialogContent,DialogTitle,DialogTrigger} from '@ankole/uikit';
import {lazy,Suspense,useState} from 'react';
import logoURL from './logo.svg';
import wasmURL from './add.wasm';
const LazyDetails=lazy(()=>import('./lazy-details'));
function App(){
  const rows=useRecords(${JSON.stringify(tableID)});
  const room=useChannel('browser-room');
  const [count,setCount]=useState(0);
  const [draft,setDraft]=useState('');
  const [loaded,setLoaded]=useState('');
  const [worker,setWorker]=useState('');
  const [wasm,setWasm]=useState('');
  const [viewport,setViewport]=useState(false);
  const [lazyLoaded,setLazyLoaded]=useState(false);
  const [failed,setFailed]=useState(false);
  if(failed) throw new Error('Fixture rendering failed');
  if(viewport) return <section className="viewport-workspace" style={{height:'100vh',padding:16,boxSizing:'content-box'}}>
    <h2>Viewport dashboard</h2>
    <Dialog><DialogTrigger render={<Button/>}>Open portal</DialogTrigger>
      <DialogContent closeLabel="Close portal"><DialogTitle>Frame portal</DialogTitle><p>Portal stays inside this applet viewport.</p></DialogContent>
    </Dialog>
    <Button onClick={()=>setViewport(false)}>Back to records</Button>
  </section>;
  return <section className="applet-shell"><h2 className="applet-heading">Tracker ${revision}</h2>
  <p className="applet-record-count">{rows.data?.records.length??0} records</p>
  <img src={logoURL} alt="Applet logo" width="16" height="16"/>
  <p className="applet-presence">{room.presence.length} online</p>
  <label>Draft evaluation<Input value={draft} onChange={event=>setDraft(event.target.value)}/></label>
  <div className="applet-actions">
  <Button onClick={()=>setCount(n=>n+1)}>Local counter {count}</Button>
  <Button disabled={rows.write.isPending} onClick={()=>{void rows.create({[${JSON.stringify(amountFieldID)}]:11,[${JSON.stringify(statusFieldID)}]:'new'}).catch(()=>{})}}>Add sample</Button>
  <Button disabled={rows.write.isPending} onClick={async()=>{await rows.create({[${JSON.stringify(amountFieldID)}]:11,[${JSON.stringify(statusFieldID)}]:'new'})}}>Submit sample</Button>
  <Button onClick={()=>{void import('./details').then(module=>setLoaded(module.label))}}>Load details</Button>
  <Button onClick={()=>{void import('./charts/calculation').then(module=>{const job=module.start();job.onmessage=event=>{setWorker(event.data);job.terminate()}})}}>Run worker</Button>
  <Button onClick={()=>{void fetch(wasmURL).then(response=>response.arrayBuffer()).then(bytes=>WebAssembly.instantiate(bytes)).then(module=>setWasm(String(module.instance.exports.add(2,3))))}}>Run WASM</Button>
  </div>
  <Button onClick={()=>setViewport(true)}>Viewport dashboard</Button>
  <Button onClick={()=>setLazyLoaded(true)}>Load lazy details</Button>
  <Button onClick={()=>setFailed(true)}>Render error</Button>
  {lazyLoaded?<Suspense fallback={<p>Loading lazy details</p>}><LazyDetails/></Suspense>:null}
  <output className="applet-wasm">{wasm}</output>
  <output className="applet-details">{loaded}</output><output className="applet-worker">{worker}</output>
  {rows.write.error?<p role="alert">Write rejected</p>:null}
  <div className="applet-records">{rows.data?.records.map(record=><p key={record.id}>{String(record.data[${JSON.stringify(amountFieldID)}]??'')}</p>)}</div>
  </section>
}
export const provider=defineApplet(App);`
  const entry = path.join(directory, 'src/main.tsx')
  await writeFile(entry, source)
  await writeFile(path.join(directory, 'src/details.ts'), "export const label = 'Details module loaded'")
  await writeFile(
    path.join(directory, 'src/lazy-details.tsx'),
    'export default function Details(){return <p className="applet-lazy-details">Lazy details loaded</p>}'
  )
  await writeFile(
    path.join(directory, 'src/logo.svg'),
    '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="teal"/></svg>'
  )
  await writeFile(
    path.join(directory, 'src/add.wasm'),
    Buffer.from('0061736d0100000001070160027f7f017f030201000707010361646400000a09010700200020016a0b', 'hex')
  )
  await mkdir(path.join(directory, 'src/charts'))
  await writeFile(
    path.join(directory, 'src/charts/calculation.ts'),
    `import workerURL from './calculation.worker.ts?url';
export const start=()=>new Worker(new URL(workerURL,import.meta.url),{type:'module'});`
  )
  await writeFile(
    path.join(directory, 'src/charts/calculation.worker.ts'),
    `import wasmURL from '../add.wasm';
const module=await WebAssembly.instantiate(await(await fetch(wasmURL)).arrayBuffer());
postMessage(location.pathname+':'+(module.instance.exports.add as (a:number,b:number)=>number)(2,3));`
  )
  await writeFile(
    path.join(directory, 'src/style.css'),
    `.ankole-applet .applet-shell{display:grid;gap:8px;padding:16px;border:1px solid var(--color-border)}.ankole-applet .applet-actions{display:flex;gap:12px}.ankole-applet .applet-heading{color:${revision === 'v1' ? 'teal' : 'purple'}}`
  )
  const result = await buildApplet(directory)
  manifests[revision] = [
    ...(await readdir(path.join(directory, 'src'), { recursive: true, withFileTypes: true }))
      .filter(entry => entry.isFile())
      .map(entry => path.relative(directory, path.join(entry.parentPath, entry.name))),
    ...result.files
  ].map(name => ({
    path: name,
    local_path: path.join(directory, name),
    content_type: Bun.file(path.join(directory, name)).type || 'text/plain'
  }))
}
await writeFile(path.join(output, 'manifests.json'), JSON.stringify(manifests, null, 2))
process.stdout.write(`${path.join(output, 'manifests.json')}\n`)
