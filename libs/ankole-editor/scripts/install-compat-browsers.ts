import { mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import versions from '../compat/browsers.json'

const directory = resolve('output/browsers')
await mkdir(directory, { recursive: true })
const platform = process.platform
const arch = process.arch
if (!['darwin', 'linux'].includes(platform)) {
  throw new Error('Set CHROMIUM_126_BINARY, FIREFOX_BINARY and GECKODRIVER to local installations on this OS.')
}
async function run(args: string[]) {
  const process = Bun.spawn(args, { stdout: 'inherit', stderr: 'inherit' })
  if (await process.exited) throw new Error(`Failed: ${args.join(' ')}`)
}
async function download(url: string, name: string) {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`)
  const path = `${directory}/${name}`
  await Bun.write(path, response)
  return path
}
const targets = Bun.argv.slice(2)
if (!targets.length) throw new Error('Specify chromium126, firefox-esr, or both.')
for (const target of targets) {
  if (target === 'chromium126') {
    if (platform === 'linux' && arch !== 'x64') {
      throw new Error('Chrome for Testing 126 has no Linux ARM build. Set CHROMIUM_126_BINARY explicitly.')
    }
    const build = platform === 'darwin' ? `mac-${arch === 'arm64' ? 'arm64' : 'x64'}` : 'linux64'
    const archive = await download(
      `https://storage.googleapis.com/chrome-for-testing-public/${versions.chromium}/${build}/chrome-headless-shell-${build}.zip`,
      `chrome-${versions.chromium}.zip`
    )
    await run(['unzip', '-q', '-o', archive, '-d', directory])
  } else if (target === 'firefox-esr') {
    if (platform === 'darwin') {
      const archive = await download(
        `https://archive.mozilla.org/pub/firefox/releases/${versions.firefox}/mac/en-US/Firefox%20${versions.firefox}.dmg`,
        'firefox-esr.dmg'
      )
      const mount = `${directory}/firefox-mount`
      await run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, archive])
      try {
        await run(['ditto', `${mount}/Firefox.app`, `${directory}/FirefoxESR.app`])
      } finally {
        await run(['hdiutil', 'detach', mount])
      }
    } else {
      const build = arch === 'arm64' ? 'linux-aarch64' : 'linux-x86_64'
      const archive = await download(
        `https://archive.mozilla.org/pub/firefox/releases/${versions.firefox}/${build}/en-US/firefox-${versions.firefox}.tar.xz`,
        'firefox-esr.tar.xz'
      )
      await run(['tar', '-xf', archive, '-C', directory])
    }
    const build =
      platform === 'darwin'
        ? `macos${arch === 'arm64' ? '-aarch64' : ''}`
        : `linux${arch === 'arm64' ? '-aarch64' : '64'}`
    const archive = await download(
      `https://github.com/mozilla/geckodriver/releases/download/v${versions.geckodriver}/geckodriver-v${versions.geckodriver}-${build}.tar.gz`,
      'geckodriver.tar.gz'
    )
    await run(['tar', '-xzf', archive, '-C', directory])
  } else throw new Error(`Unknown browser: ${target}`)
}
