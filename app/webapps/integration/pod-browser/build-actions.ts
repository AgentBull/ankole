import { mkdir, readdir, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { buildApplet, initializeApplet } from '../../../agent_computer/src/cli/pod/pod-cli'

const [targetID, output] = process.argv.slice(2)
if (!targetID || !output) throw new Error('Expected target table ID and output directory')
const manifests: Record<string, { path: string; local_path: string; content_type: string }[]> = {}
for (const version of ['complete', 'missing']) {
  const directory = path.join(output, version)
  await rm(directory, { recursive: true, force: true })
  await mkdir(directory, { recursive: true })
  await initializeApplet(directory)
  await mkdir(path.join(directory, 'src/server'), { recursive: true })
  const source = `
import {defineApplet, usePod, useRouteMutation, useActionRun, useRecords} from '@ankole/applet-sdk';
import {Button} from '@ankole/uikit';
import {useState} from 'react';
function App() {
  const runtime = usePod();
  const [starting, setStarting] = useState(false);
  const [startError, setStartError] = useState(false);
  const [id, setId] = useState(() => Number(sessionStorage.getItem('sync-run')) || null);
  const run = useActionRun(id);
  const rows = useRecords(${JSON.stringify(targetID)});
  const start = useRouteMutation('POST /sync', {onSuccess(result) {
    sessionStorage.setItem('sync-run', String(result.runId)); setId(result.runId);
  }});
  const busy = starting || start.isPending || (id && (!run.data || ['queued','running'].includes(run.data.status)));
  async function begin() {
    setStarting(true); setStartError(false);
    try {
      const {jobs} = await runtime.queryClient.fetchQuery({queryKey:[runtime.pageID,'jobs'], queryFn:()=>runtime.pod.request('/pages/' + runtime.pageID + '/jobs')});
      await start.mutateAsync({body:{jobId:jobs[0].id}});
    } catch { setStartError(true); }
    finally { setStarting(false); }
  }
  return <section className="grid gap-4 p-4" aria-label="Record import">
    <h2 className="text-xl font-semibold">Import 100 records</h2>
    <p>Import continues in the background. A retry resumes from the saved position.</p>
    <Button disabled={busy} onClick={begin}>
      {run.data?.status === 'failed' ? 'Retry import' : 'Start import'}
    </Button>
    {startError && <p role="alert">Could not start the import.</p>}
    {run.data?.status === 'failed' ? <p role="alert">Import stopped: {run.data.error}. Your saved position is available.</p>
      : run.data?.status === 'succeeded' ? <p role="status" aria-label="Import status">Imported {run.data.result.count} records.</p>
      : id ? <p role="status" aria-label="Import status">Importing: {run.data?.progress?.count ?? 0} of 100</p> : null}
    <p>Imported rows: <output aria-label="Imported row count">{rows.data?.records.length ?? 0}</output></p>
    <p>Run: <output aria-label="Run ID">{id ?? ''}</output></p>
    <p>Published version: <output aria-label="Published revision">{runtime.revision}</output></p>
  </section>
}
export const provider = defineApplet(App);
`
  const handler = `async ctx => {
    const state = ctx.state.scope('import'); const c = ctx.job.config;
    const cursor = await state.get('cursor'); let count = cursor?.count || 0;
    const page = await AnkoleRuntime.admin.base.query(c.source, {page_token:cursor?.token, page_size:10});
    await AnkoleRuntime.admin.base.write(c.target, {upserts:page.records.map(r => ({data:{[c.target_key]:r.data[c.source_key]}}))});
    count += page.records.length;
    if (page.complete) { await state.delete('cursor'); return {count}; }
    await state.set('cursor', {token:page.page_token, count});
    return ctx.continueSlice({delaySeconds:2, progress:{count}});
  }`
  await writeFile(path.join(directory, 'src/main.tsx'), source)
  await writeFile(
    path.join(directory, 'src/server/main.ts'),
    `export default {
    routes: {'POST /sync': ({body}) => AnkoleRuntime.signals.emit({targetJobId:body.jobId, type:'import.requested', responseMode:'wait_accepted'})},
    actions: ${version === 'missing' ? '{}' : `{sync:{idempotent:true, concurrency:'serial_coalesce', maxSlices:100, handler:${handler}}}`}
  }`
  )
  const built = await buildApplet(directory)
  manifests[version] = [
    ...(await readdir(path.join(directory, 'src'), { recursive: true, withFileTypes: true }))
      .filter(entry => entry.isFile())
      .map(entry => path.relative(directory, path.join(entry.parentPath, entry.name))),
    ...built.files
  ].map(name => ({
    path: name,
    local_path: path.join(directory, name),
    content_type: Bun.file(path.join(directory, name)).type || 'text/plain'
  }))
}
await writeFile(path.join(output, 'manifests.json'), JSON.stringify(manifests))
