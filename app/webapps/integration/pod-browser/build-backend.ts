import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

const [tableID, stockFieldID, recordID, output] = process.argv.slice(2)
if (!tableID || !stockFieldID || !recordID || !output) {
  throw new Error('Expected table ID, stock field ID, record ID, and output directory')
}

const manifests: Record<string, { path: string; local_path: string; content_type: string }[]> = {}
for (const version of ['v1', 'v2']) {
  const directory = path.join(output, version)
  await mkdir(directory, { recursive: true })
  const server = `
const TABLE = ${JSON.stringify(tableID)};
const STOCK = ${JSON.stringify(stockFieldID)};
const RECORD = ${JSON.stringify(recordID)};
export default {
  'GET /stock': async () => {
    const result = await AnkoleRuntime.db.query(TABLE, {ids: [RECORD]});
    return {available: result.records[0].data[STOCK], version: ${JSON.stringify(version)}};
  },
  'POST /reserve': async ({body, principal}) => {
    const quantity = body?.quantity;
    if (!Number.isSafeInteger(quantity) || quantity < 1) {
      throw new AnkoleRuntime.HttpError(422, 'invalid_quantity', 'Enter a whole number greater than zero.');
    }
    for (let attempt = 0; attempt < 8; attempt++) {
      const result = await AnkoleRuntime.db.query(TABLE, {ids: [RECORD]});
      const record = result.records[0];
      const available = record.data[STOCK];
      if (quantity > available) {
        throw new AnkoleRuntime.HttpError(409, 'insufficient_stock', 'There are not enough samples available.', {available});
      }
      try {
        await AnkoleRuntime.db.write(TABLE, {updates: [{id: RECORD,
          data: {[STOCK]: available - quantity}, expected_versions: {[STOCK]: record.versions[STOCK]}}]});
        console.info('Reserved', quantity, 'samples for', principal.uid);
        return {reserved: quantity, available: available - quantity, version: ${JSON.stringify(version)}};
      } catch (error) {
        if (error.code !== 'field_conflict' || attempt === 7) throw error;
      }
    }
  }
};`
  const source = `
import {defineApplet,useRoute,useRouteMutation,usePod} from '@ankole/applet-sdk';
import {Button,Input,Label} from '@ankole/uikit';
import {useState} from 'react';
function App() {
  const runtime = usePod();
  const stock = useRoute('GET /stock');
  const [quantity,setQuantity] = useState('2');
  const [notice,setNotice] = useState('');
  const reserve = useRouteMutation('POST /reserve', {
    onSuccess(result) {
      setNotice('Reserved ' + result.reserved + ' samples.');
    },
    onSettled() {
      void runtime.queryClient.invalidateQueries({queryKey: runtime.routes.key()});
    }
  });
  const error = reserve.error;
  const code = error?.code ?? error?.payload?.error?.code;
  const errorText = code === 'insufficient_stock'
    ? 'Not enough samples. Choose a smaller quantity.'
    : code === 'forbidden' ? 'You can view this inventory. Ask an editor to reserve samples.'
    : error ? 'Could not reserve samples. Your quantity is still here; please try again.' : '';
  return <section className="sample-workspace" aria-label="Sample reservations">
    <header><p className="sample-eyebrow">SAMPLE INVENTORY</p>
      <h2>Reserve a sample</h2><p>Set aside samples for your next supplier review.</p></header>
    {stock.isPending ? <p role="status">Reading inventory…</p>
      : stock.isError ? <p role="alert">Could not read inventory. <Button variant="outline" onClick={()=>stock.refetch()}>Try again</Button></p>
      : <div className="sample-availability"><span>Cedar sample kit</span>
          <output aria-label="Available samples">{stock.data.available}</output><span>available</span></div>}
    <form onSubmit={event=>{event.preventDefault();if(reserve.isPending)return;setNotice('');reserve.mutate({body:{quantity:Number(quantity)}})}}>
      <div className="sample-field"><Label htmlFor="sample-quantity">Quantity</Label>
        <Input id="sample-quantity" type="number" min="1" step="1" required value={quantity}
          readOnly={reserve.isPending} onChange={event=>{setQuantity(event.target.value);reserve.reset();setNotice('')}}
          aria-describedby="sample-help" /></div>
      <p id="sample-help">Reservations update the shared inventory immediately.</p>
      <Button type="submit" variant="outline" disabled={reserve.isPending || !stock.data}>
        {reserve.isPending ? 'Reserving…' : 'Reserve samples'}</Button>
      {reserve.isPending && <p role="status">Saving your reservation…</p>}
      {notice && <p role="status">{notice}</p>}
      {errorText && <p role="alert">{errorText}</p>}
    </form>
    <footer>Shared inventory · ${version === 'v1' ? 'Sample reservations' : 'Updated sample reservations'}</footer>
  </section>
}
export const provider = defineApplet(App);`
  const frontendPath = path.join(directory, 'main.tsx')
  const serverPath = path.join(directory, 'server.ts')
  await writeFile(frontendPath, source)
  await writeFile(serverPath, server)
  const frontend = await Bun.build({
    entrypoints: [frontendPath],
    outdir: directory,
    target: 'browser',
    format: 'cjs',
    jsx: { runtime: 'automatic', development: false },
    define: { 'process.env.NODE_ENV': '"production"' },
    naming: 'app.js',
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
  const backend = await Bun.build({
    entrypoints: [serverPath],
    outdir: path.join(directory, 'server'),
    target: 'browser',
    format: 'esm',
    naming: 'main.js'
  })
  if (!frontend.success || !backend.success) {
    throw new AggregateError([...frontend.logs, ...backend.logs], 'Could not build the backend browser Applet')
  }
  await writeFile(
    path.join(directory, 'app.css'),
    `
.sample-workspace{display:grid;gap:24px;max-width:620px;padding:8px 0;color:var(--foreground)}
.sample-workspace header{display:grid;gap:8px}.sample-workspace h2{font-size:24px;font-weight:600;line-height:1.3}
.sample-workspace header p:not(.sample-eyebrow),.sample-workspace #sample-help,.sample-workspace footer{color:var(--muted-foreground);font-size:13px;line-height:1.5}
.sample-workspace .sample-eyebrow{font-size:11px;font-weight:500;letter-spacing:.08em;color:var(--muted-foreground)}
.sample-workspace .sample-availability{display:flex;align-items:baseline;gap:8px;padding-block:16px;border-block:1px solid var(--border);font-size:13px}
.sample-workspace .sample-availability>span:first-child{margin-right:auto;font-size:14px}
.sample-workspace output{font-size:28px;line-height:1.2;font-variant-numeric:tabular-nums;font-weight:600}
.sample-workspace form{display:grid;gap:12px;justify-items:start}.sample-workspace .sample-field{display:grid;gap:8px;width:160px}
.sample-workspace [role=alert]{font-size:13px;color:var(--destructive)}.sample-workspace [role=status]{font-size:13px}
.sample-workspace footer{padding-top:8px;border-top:1px solid var(--border)}
@media(max-width:480px){.sample-workspace{gap:20px}.sample-workspace .sample-availability{flex-wrap:wrap}}
`
  )
  await writeFile(
    path.join(directory, 'index.html'),
    '<!doctype html><html><head><link rel="stylesheet" href="./app.css"><script src="./app.js"></script></head><body></body></html>'
  )
  manifests[version] = [
    { path: 'src/main.tsx', local_path: frontendPath, content_type: 'text/plain' },
    { path: 'src/server/main.ts', local_path: serverPath, content_type: 'text/plain' },
    { path: 'server/main.js', local_path: path.join(directory, 'server/main.js'), content_type: 'text/javascript' },
    ...['app.js', 'app.css', 'index.html'].map(name => ({
      path: `dist/${name}`,
      local_path: path.join(directory, name),
      content_type: name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html'
    }))
  ]
}
await writeFile(path.join(output, 'manifests.json'), JSON.stringify(manifests, null, 2))
