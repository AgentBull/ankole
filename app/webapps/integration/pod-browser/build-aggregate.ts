import { mkdir, readdir, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { buildApplet, initializeApplet } from '../../../agent_computer/src/cli/pod/pod-cli'

// An Applet whose aggregate follows a link into another table, so a change to
// that table alone must refresh it.
const [ordersTableID, itemsLinkID, itemAmountID, output] = process.argv.slice(2)
if (!ordersTableID || !itemsLinkID || !itemAmountID || !output) {
  throw new Error('Expected the orders table ID, items link field ID, item amount field ID, and an output directory')
}
await rm(output, { recursive: true, force: true })
await mkdir(output, { recursive: true })
await initializeApplet(output)
await writeFile(
  path.join(output, 'src/main.tsx'),
  `import {defineApplet,useAggregate} from '@ankole/applet-sdk';
function App(){
  const totals=useAggregate(${JSON.stringify(ordersTableID)},{metrics:[{operation:'sum',field_id:${JSON.stringify(itemAmountID)},path:[${JSON.stringify(itemsLinkID)}],alias:'items_total'}]});
  const value=totals.data?.groups[0]?.metrics_text?.items_total;
  return <section><h2>Order totals</h2><p className="aggregate-items-total">{value==null?'Loading':'Items total '+value}</p></section>
}
export const provider=defineApplet(App);`
)
const result = await buildApplet(output)
const files = [
  ...(await readdir(path.join(output, 'src'), { recursive: true, withFileTypes: true }))
    .filter(entry => entry.isFile())
    .map(entry => path.relative(output, path.join(entry.parentPath, entry.name))),
  ...result.files
].map(name => ({
  path: name,
  local_path: path.join(output, name),
  content_type: Bun.file(path.join(output, name)).type || 'text/plain'
}))
await writeFile(path.join(output, 'manifest.json'), JSON.stringify(files, null, 2))
process.stdout.write(`${path.join(output, 'manifest.json')}\n`)
