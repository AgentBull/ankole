/**
 * Deploys the adapter with the Worker images it may start.
 *
 *   bun run deploy <name>=registry.cloudflare.com/<account>/<repository>@sha256:<digest> ...
 *
 * Each name becomes a key of `containers[0].images`, and the control plane
 * sends that name as `ANKOLE_AGENT_COMPUTER_IMAGE`. Keep the names of older
 * images while their Workers may still start from an image.
 */
const usage = 'usage: bun run deploy <name>=registry.cloudflare.com/<account>/<repository>@sha256:<digest> ...'
const imagePattern = /^registry\.cloudflare\.com\/[^@\s]+@sha256:[0-9a-f]{64}$/

const images: Record<string, { image: string }> = {}
for (const argument of process.argv.slice(2)) {
  const separator = argument.indexOf('=')
  const name = argument.slice(0, separator)
  const image = argument.slice(separator + 1)
  if (separator < 1 || name.length > 128 || !imagePattern.test(image)) {
    console.error(`invalid image argument: ${argument}\n${usage}`)
    process.exit(64)
  }
  images[name] = { image }
}
if (Object.keys(images).length === 0) {
  console.error(usage)
  process.exit(64)
}

const config = JSON.parse(await Bun.file(new URL('../wrangler.json', import.meta.url)).text())
config.containers[0].images = images
const deployConfig = new URL('../wrangler.deploy.json', import.meta.url)
await Bun.write(deployConfig, `${JSON.stringify(config, null, 2)}\n`)

const deploy = Bun.spawn(['bunx', 'wrangler', 'deploy', '--config', deployConfig.pathname], {
  stdio: ['inherit', 'inherit', 'inherit']
})
process.exit(await deploy.exited)
