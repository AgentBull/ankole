import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { chromium, expect } from '@playwright/test'
import { podLocation } from './common/browser-context'
import { uuidShorten } from './common/uuid-url'

const state = JSON.parse(readFileSync(process.argv[1], 'utf8'))
const browser = await chromium.launch()
const context = await browser.newContext({ locale: 'en-US' })
await context.addCookies(state.cookies)
const page = await context.newPage()
const errors = []
const consoleErrors = []
const failedRequests = []
const screenshots = []
page.on('pageerror', error => errors.push(error.message))
page.on('console', message => {
  if (['error', 'warning'].includes(message.type())) consoleErrors.push(message.text().slice(0, 12_000))
})
page.on('requestfailed', request => {
  const address = new URL(request.url())
  failedRequests.push({ path: address.pathname, failure: request.failure()?.errorText })
})
const path = value => podLocation(value).pathname
const url = value => `${state.base_url}${path(value)}`

async function capture(name) {
  const directory = process.env.POD_REAL_LLM_ARTIFACT_DIR ?? join(tmpdir(), 'ankole-pod-real-llm-artifacts')
  mkdirSync(directory, { recursive: true })
  const path = join(directory, `${name}-${state.report_id ?? state.applet_id ?? state.child_id ?? state.page_id}.png`)
  // Preserve contenteditable styles while capturing live embeds.
  await page.screenshot({ path, fullPage: true, caret: 'initial' })
  screenshots.push(path)
}

async function openDeliveredPage(conversationID, pageID) {
  await page.goto(url(`/conversations/${conversationID}`))
  const link = page.locator(`a.link[href*="${path(`/pages/${pageID}`)}"]`).last()
  await expect(link).toBeVisible({ timeout: 30_000 })
  const href = await link.getAttribute('href')
  await link.click()
  await expect.poll(() => new URL(page.url()).pathname).toBe(path(`/pages/${pageID}`))
  return { href, opened_url: page.url() }
}

async function sendMessage() {
  let composer = page
  if (state.page_id) {
    await page.goto(url(`/pages/${state.page_id}`))
    await page.getByRole('button', { name: 'Page chat', exact: true }).click()
    composer = page.getByRole('complementary', { name: 'Page chat', exact: true })
    await expect(composer).toBeVisible()
    await expect(composer.getByText('Current page:', { exact: false })).toBeVisible()
  } else {
    await page.goto(url(state.conversation_id ? `/conversations/${state.conversation_id}` : '/'))
  }
  const input = composer.getByRole('textbox', { name: 'Message', exact: true })
  await expect(input).toBeEnabled({ timeout: 30_000 })
  await input.fill(state.text)
  const responsePromise = page.waitForResponse(
    response =>
      response.request().method() === 'POST' &&
      /\/api\/v2\/pod\/conversations(?:\/[^/]+\/messages)?$/.test(new URL(response.url()).pathname)
  )
  await composer.getByRole('button', { name: 'Send message', exact: true }).click()
  const response = await responsePromise
  expect(response.status()).toBe(201)
  const submitted = response.request().postDataJSON().data
  const detail = await response.json()
  await expect(input).toHaveValue('')
  const submittedBubble = composer.locator('div.whitespace-pre-wrap').filter({ hasText: state.text })
  await expect(submittedBubble).toHaveCount(1)
  await expect(submittedBubble).toBeVisible()
  if (state.page_id) {
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).toBe(uuidShorten(detail.conversation.id))
    expect(detail.conversation.pageID).toBe(state.page_id)
    await page.reload()
    await expect(page.getByRole('complementary', { name: 'Page chat', exact: true })).toContainText(state.text)
  } else {
    await expect.poll(() => new URL(page.url()).pathname).toBe(path(`/conversations/${detail.conversation.id}`))
  }
  return {
    conversation_id: detail.conversation.id,
    message_id: submitted.messageID,
    page_id: submitted.pageID ?? null,
    text: submitted.text
  }
}

async function report() {
  const socketErrors = []
  let joinedTables = 0
  page.on('websocket', socket => {
    if (!socket.url().includes('/pod/socket/')) return
    socket.on('socketerror', error => socketErrors.push(String(error)))
    socket.on('framereceived', frame => {
      try {
        const [joinRef, ref, topic, event, payload] = JSON.parse(String(frame.payload))
        if (joinRef === ref && topic.startsWith('table:') && event === 'phx_reply' && payload.status === 'ok') {
          joinedTables++
        }
      } catch {}
    })
  })
  const navigation = await openDeliveredPage(state.conversation_id, state.report_id)
  const embedded = page.locator('.editor-content .embed').filter({
    has: page.getByRole('button', { name: 'Add Cedar sale', exact: true })
  })
  await expect(embedded).toHaveCount(1, { timeout: 30_000 })
  await expect(embedded.getByText('Oak', { exact: true })).toBeVisible()
  await expect(embedded.getByText('Pine', { exact: true })).toBeVisible()
  const pageTitle = await page.getByRole('textbox', { name: 'Page title', exact: true }).inputValue()
  const repeatedTitle = page.locator('.editor-content').getByRole('heading', { name: pageTitle, exact: true })
  await expect(repeatedTitle).toHaveCount(0)
  const total = embedded.getByRole('status', { name: 'Total sales', exact: true })
  await expect(total).toContainText(state.add_sale ? '465' : '485')
  await expect.poll(() => joinedTables).toBeGreaterThan(0)
  if (state.add_sale) await capture('report-created')
  if (state.add_sale) await embedded.getByRole('button', { name: 'Add Cedar sale', exact: true }).click()
  await expect(embedded.getByText('Cedar', { exact: true })).toBeVisible()
  await expect(total).toContainText('485')
  const joinsBeforeReload = joinedTables
  await page.reload()
  await expect(embedded.getByText('Cedar', { exact: true })).toBeVisible({ timeout: 30_000 })
  await expect(embedded.getByRole('status', { name: 'Total sales', exact: true })).toContainText('485')
  await expect(repeatedTitle).toHaveCount(0)
  await expect.poll(() => joinedTables).toBeGreaterThan(joinsBeforeReload)
  expect(socketErrors).toEqual([])
  if (!state.add_sale) {
    const toggle = page.getByRole('button', { name: 'Page chat', exact: true })
    const expandedBefore = await toggle.getAttribute('aria-expanded')
    if (expandedBefore !== 'true') await toggle.click()
    await expect(toggle).toHaveAttribute('aria-expanded', 'true')
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).toBe(uuidShorten(state.conversation_id))
    const panel = page.getByRole('complementary', { name: 'Page chat', exact: true })
    const title = await page.getByRole('textbox', { name: 'Page title', exact: true }).inputValue()
    await expect(panel.getByText(`Current page: ${title}`, { exact: true })).toBeVisible()
    await expect(panel.getByRole('region', { name: 'Conversation messages', exact: true })).toContainText('Cedar')
    navigation.page_chat_expanded_before = expandedBefore
    navigation.page_chat_conversation_id = new URL(page.url()).searchParams.get('chat')
    await capture('report-updated-page-chat')
    await page.getByRole('button', { name: 'Close page chat', exact: true }).click()
    await page.getByRole('textbox', { name: 'Page title', exact: true }).scrollIntoViewIfNeeded()
    await capture('final-sales-report')
    await total.scrollIntoViewIfNeeded()
    await expect(total).toBeInViewport({ ratio: 1 })
    await capture('final-sales-applet')
  }
  return { action: 'report', added_sale: state.add_sale, total: 485, retained_after_reload: true, navigation }
}

async function counter() {
  await openDeliveredPage(state.conversation_id, state.applet_id)
  const count = page.getByRole('status', { name: 'Focus points', exact: true })
  await expect(count).toHaveText('0', { timeout: 30_000 })
  await page.getByRole('button', { name: 'Add focus point', exact: true }).click()
  await expect(count).toHaveText('1')
  await capture('pure-spa')
  await page.getByRole('button', { name: 'Reset', exact: true }).click()
  await expect(count).toHaveText('0')
  await page.reload()
  await expect(count).toHaveText('0', { timeout: 30_000 })
  await page.getByRole('button', { name: 'Add focus point', exact: true }).click()
  await expect(count).toHaveText('1')
  return { action: 'counter', interactive_after_reload: true }
}

async function inventory() {
  const directRecordWrites = []
  page.on('request', request => {
    const pathname = new URL(request.url()).pathname
    if (request.method() === 'POST' && /^\/api\/v2\/pod\/tables\/[^/]+\/records$/.test(pathname)) {
      directRecordWrites.push(pathname)
    }
  })
  await openDeliveredPage(state.conversation_id, state.report_id)
  const embedded = page.locator('.editor-content .embed').filter({
    has: page.getByRole('button', { name: 'Reserve samples', exact: true })
  })
  await expect(embedded).toHaveCount(1, { timeout: 30_000 })
  await embedded.scrollIntoViewIfNeeded()
  // Probe the visible quantity without requiring a particular ARIA/DOM shape.
  // The real route responses and saved record are checked independently.
  await expect(embedded.getByText('Available samples', { exact: true })).toBeVisible()
  const available = embedded.getByText(/^(?:Available samples\s*)?\d+$/)
  await expect(available).toBeVisible()
  const stockText = count => new RegExp(`^(?:Available samples\\s*)?${count}$`)
  await expect(available).toHaveText(stockText(state.reserve ? 5 : 3))
  const quantity = embedded.getByRole('spinbutton', { name: 'Quantity', exact: true })
  await expect(quantity).toBeVisible()
  let insufficientQuantityHandled
  if (state.reserve) {
    await quantity.fill('2')
    const saved = page.waitForResponse(
      response =>
        response.request().method() === 'POST' &&
        new URL(response.url()).pathname.includes(`/pages/${state.applet_id}/routes/`)
    )
    await embedded.getByRole('button', { name: 'Reserve samples', exact: true }).click()
    expect((await saved).status()).toBe(200)
    await expect(available).toHaveText(stockText(3))
    await quantity.fill('9')
    const submit = embedded.getByRole('button', { name: 'Reserve samples', exact: true })
    if (await submit.isEnabled()) {
      const refused = page.waitForResponse(
        response =>
          response.request().method() === 'POST' &&
          new URL(response.url()).pathname.includes(`/pages/${state.applet_id}/routes/`)
      )
      await submit.click()
      const refusal = await refused
      expect(refusal.status()).toBeGreaterThanOrEqual(400)
      expect(refusal.status()).toBeLessThan(500)
      const failure = await refusal.json()
      expect(typeof failure.error?.message).toBe('string')
      expect(failure.error.message.length).toBeGreaterThan(0)
      await expect(embedded.getByText(failure.error.message, { exact: false })).toBeVisible()
      insufficientQuantityHandled = 'server'
    } else {
      // Local prevention is valid. Its feedback is reviewed in the screenshot;
      // independent runtime cases test backend rejection and concurrent writes.
      await expect(submit).toBeDisabled()
      insufficientQuantityHandled = 'client'
    }
    await expect(quantity).toHaveValue('9')
    await expect(available).toHaveText(stockText(3))
    await capture('backend-applet-insufficient-stock')
  } else {
    await expect(embedded).toContainText('Shared inventory')
  }
  await page.reload()
  await expect(available).toHaveText(stockText(3), { timeout: 30_000 })
  await available.scrollIntoViewIfNeeded()
  await capture(state.reserve ? 'backend-applet-created' : 'backend-applet-updated')
  await page.setViewportSize({ width: 390, height: 844 })
  if (new URL(page.url()).searchParams.has('chat')) {
    const chat = page.getByRole('dialog', { name: 'Page chat', exact: true })
    await expect(chat).toBeVisible()
    await chat.getByRole('button', { name: 'Close page chat', exact: true }).click()
    await expect(chat).toBeHidden()
    await expect.poll(() => new URL(page.url()).searchParams.has('chat')).toBe(false)
  }
  await available.scrollIntoViewIfNeeded()
  await expect(available).toHaveText(stockText(3))
  await expect(available).toBeInViewport()
  await expect(embedded.getByRole('button', { name: 'Reserve samples', exact: true })).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  await capture(state.reserve ? 'backend-applet-mobile' : 'backend-applet-updated-mobile')
  expect(directRecordWrites, 'Inventory changes must use the Applet backend').toEqual([])
  return {
    action: 'inventory',
    backend_post_observed: !!state.reserve,
    available: 3,
    retained_after_reload: true,
    retained_quantity_on_error: !!state.reserve,
    insufficient_quantity_handled: insufficientQuantityHandled
  }
}

async function movedPage() {
  await page.goto(url(`/pages/${state.child_id}`))
  await page.reload()
  const tree = page.getByRole('region', { name: 'Space', exact: true })
  const parent = tree
    .locator('li')
    .filter({ has: page.getByRole('link', { name: state.parent_title, exact: true }) })
    .first()
  const child = parent.getByRole('link', { name: state.child_title, exact: true })
  await expect(child).toHaveCount(1)
  await expect(child).toHaveAttribute('href', path(`/pages/${state.child_id}`))
  await expect(page.locator('.editor-content')).toContainText(state.marker)
  await capture('agent-moved-page')
  await expect(page.locator('main').last().getByRole('link', { name: state.parent_title, exact: true })).toBeVisible()
  await child.click()
  await expect(page.locator('.editor-content')).toContainText(state.marker)
  return { action: 'moved_page', parent_id: state.parent_id, child_id: state.child_id, content_retained: true }
}

async function document() {
  await openDeliveredPage(state.conversation_id, state.report_id)
  const title = page.getByRole('textbox', { name: 'Page title', exact: true })
  await expect(title).toHaveValue(state.title)
  const pageTitle = await title.inputValue()
  const repeatedTitle = page.locator('.editor-content').getByRole('heading', { name: pageTitle, exact: true })
  await expect(page.locator('.editor-content')).toHaveAttribute('contenteditable', 'true')
  for (const fact of state.facts) await expect(page.locator('.editor-content')).toContainText(fact)
  await expect(repeatedTitle).toHaveCount(0)
  await capture('research-default-page')
  const editor = page.locator('.editor-content')
  await editor.click()
  await page.keyboard.press('ControlOrMeta+End')
  await page.keyboard.press('Enter')
  await page.keyboard.insertText(state.edit_marker)
  await expect(editor).toContainText(state.edit_marker)
  await expect
    .poll(async () => {
      const response = await page.request.get(`${state.base_url}/api/v2/pod/pages/${state.report_id}`)
      expect(response.ok()).toBe(true)
      return (await response.json()).content.plain_text
    })
    .toContain(state.edit_marker)
  await page.reload()
  await expect(editor).toHaveAttribute('contenteditable', 'true')
  await expect(editor).toContainText(state.edit_marker)
  for (const fact of state.facts) await expect(page.locator('.editor-content')).toContainText(fact)
  await expect(repeatedTitle).toHaveCount(0)
  await capture('research-human-edit-saved')
  return { action: 'document', report_id: state.report_id, saved_marker: state.edit_marker }
}

try {
  const actions = {
    send_message: sendMessage,
    report,
    counter,
    inventory,
    moved_page: movedPage,
    document
  }
  const result = await actions[state.action]()
  expect(errors).toEqual([])
  process.stdout.write(`Pod browser result: ${JSON.stringify({ ...result, screenshots })}\n`)
} catch (error) {
  try {
    await capture(`${state.action}-failure`)
    const directory = join(
      process.env.POD_REAL_LLM_ARTIFACT_DIR ?? join(tmpdir(), 'ankole-pod-real-llm-artifacts'),
      'private'
    )
    mkdirSync(directory, { recursive: true, mode: 0o700 })
    const name = `${state.action}-failure-${state.report_id ?? state.applet_id ?? state.page_id}.json`
    writeFileSync(join(directory, name), JSON.stringify({ errors, consoleErrors, failedRequests, screenshots }), {
      mode: 0o600
    })
  } catch (captureError) {
    console.error('Pod browser failure capture:', String(captureError))
  }
  console.error('Pod browser failure:', page.url(), (await page.locator('body').innerText()).slice(0, 12_000))
  throw error
} finally {
  await browser.close()
}
