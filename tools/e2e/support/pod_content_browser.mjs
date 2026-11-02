import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { chromium, expect } from '@playwright/test'
import anyAscii from 'any-ascii'
import { installPageTransliteration, podLocation, podPagePath, podPageRouteID } from './common/pod-url'
import { uuidShorten } from './common/uuid-url'

installPageTransliteration(anyAscii)

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

async function capture(
  name,
  id = state.report_id ?? state.applet_id ?? state.child_id ?? state.page_id ?? state.conversation_id
) {
  const directory = process.env.POD_REAL_LLM_ARTIFACT_DIR ?? join(tmpdir(), 'ankole-pod-real-llm-artifacts')
  mkdirSync(directory, { recursive: true })
  const path = join(directory, `${name}-${id}.png`)
  // Preserve contenteditable styles while capturing live embeds.
  await page.screenshot({ path, fullPage: true, caret: 'initial' })
  screenshots.push(path)
}

async function openDeliveredPage(conversationID, pageID) {
  await page.goto(url(`/conversations/${conversationID}`))
  const link = page.locator(`.pod-chat-agent-message a[href*="${uuidShorten(pageID)}"]`).last()
  await expect(link).toBeVisible({ timeout: 30_000 })
  const href = await link.getAttribute('href')
  await link.click()
  await expect.poll(() => podPageRouteID(new URL(page.url()).pathname.replace(/^\/pages\//, ''))).toBe(pageID)
  return { href, opened_url: page.url() }
}

async function sendMessage() {
  let composer = page
  if (state.page_id) {
    await page.goto(url(`/pages/${state.page_id}`))
    await page.getByRole('button', { name: 'Assistant', exact: true }).click()
    composer = page.getByRole('complementary', { name: 'Assistant', exact: true })
    await expect(composer).toBeVisible()
    await expect(composer.locator('.pod-page-chat-header')).toBeVisible()
  } else if (state.peer_origin_id) {
    await page.goto(url(`/conversations/${state.peer_origin_id}`))
    const href = path(`/dm/${state.colleague_uid}`)
    const card = page
      .locator('[data-peer-exchange]')
      .filter({ has: page.locator(`a[href="${href}"]`) })
      .last()
    const disclosure = card.locator('details')
    await expect(card).toBeVisible({ timeout: 30_000 })
    await expect(disclosure).not.toHaveAttribute('open')
    await capture('peer-card', state.peer_origin_id)
    await card.locator('summary').click()
    await expect(disclosure).toHaveAttribute('open', '')
    await capture('peer-card-expanded', state.peer_origin_id)
    await card.locator('summary').click()
    await card.getByRole('link', { name: `← @${state.colleague_uid}`, exact: true }).focus()
    await page.keyboard.press('Enter')
    await expect.poll(() => new URL(page.url()).pathname).toBe(href)
    await page.reload()
    await expect.poll(() => new URL(page.url()).pathname).toBe(href)
  } else {
    await page.goto(
      url(
        state.conversation_id
          ? `/conversations/${state.conversation_id}`
          : state.colleague_uid
            ? `/dm/${state.colleague_uid}`
            : '/'
      )
    )
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
  const submittedBubble = composer.locator(`[data-chat-message-id="${submitted.messageID}"]`)
  await expect(submittedBubble).toHaveCount(1)
  await expect(submittedBubble).toBeVisible()
  await expect(submittedBubble).toContainText(state.text)
  if (state.page_id) {
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).toBe(uuidShorten(detail.conversation.id))
    expect(detail.conversation.pageID).toBe(state.page_id)
    await page.reload()
    await expect(page.getByRole('complementary', { name: 'Assistant', exact: true })).toContainText(state.text)
  } else {
    await expect
      .poll(() => new URL(page.url()).pathname)
      .toBe(path(state.colleague_uid ? `/dm/${state.colleague_uid}` : `/conversations/${detail.conversation.id}`))
  }
  if (state.facts) {
    const reply = composer
      .locator('.pod-chat-agent-message > div > .pod-chat-markdown')
      .filter({ hasText: state.facts[0] })
      .last()
    for (const fact of state.facts) await expect(reply).toContainText(fact, { timeout: 300_000 })
    await expect(reply).toBeVisible()
    await capture(state.colleague_uid ? 'peer-dm-followup' : 'assistant-followup', detail.conversation.id)
  }
  return {
    conversation_id: detail.conversation.id,
    message_id: submitted.messageID,
    page_id: submitted.pageID ?? null,
    text: submitted.text
  }
}

async function editKnowledge() {
  await page.goto(url(`/pages/${state.page_id}`))
  const knowledge = page.locator('[data-knowledge-page]')
  await knowledge.getByRole('button', { name: 'Edit', exact: true }).click()
  await knowledge.locator('.editor-content').fill(state.text)
  const saved = page.waitForResponse(
    response =>
      response.request().method() === 'PUT' &&
      new URL(response.url()).pathname.endsWith(`/pages/${state.page_id}/content`)
  )
  await knowledge.getByRole('button', { name: 'Save', exact: true }).click()
  expect((await saved).status()).toBe(200)
  await knowledge.getByRole('button', { name: 'Edit', exact: true }).waitFor()
  await page.reload()
  await expect(knowledge.locator('.editor-content')).toContainText(state.text)
  await capture('team-knowledge-edit')
  return { page_id: state.page_id, text: await knowledge.locator('.editor-content').innerText() }
}

async function knowledge() {
  const delivery = await openDeliveredPage(state.conversation_id, state.page_id)
  await expect(page.getByRole('textbox', { name: 'Page title', exact: true })).toHaveValue(state.title)
  const content = page.locator('[data-knowledge-page] .editor-content')
  await expect(content).toHaveAttribute('contenteditable', 'false')
  for (const fact of state.facts) await expect(content).toContainText(fact)
  await page.reload()
  for (const fact of state.facts) await expect(content).toContainText(fact)
  await capture('saved-pilot-proposal')
  return { action: 'knowledge', page_id: state.page_id, ...delivery }
}

async function answerPeer() {
  await page.goto(url('/'))
  await page.getByRole('tab', { name: 'Home', exact: true }).click()
  const chatBadge = page
    .getByRole('tab', { name: 'Chat', exact: true })
    .getByLabel('1 conversations need attention', { exact: true })
  await expect(chatBadge).toHaveText('1')
  await expect.poll(async () => (await chatBadge.boundingBox())?.width ?? 0).toBeGreaterThan(5)
  await expect(chatBadge).toBeInViewport()
  const recent = page.locator('.pod-navigation').locator(`a[href="${path(`/conversations/${state.conversation_id}`)}"]`)
  await expect(recent).toBeVisible()
  await expect(recent.getByRole('img', { name: 'Waiting for a decision', exact: true })).toBeVisible()
  await capture('peer-attention-home')
  await page.getByRole('tab', { name: 'Chat', exact: true }).click()
  const sidebar = page.locator('.pod-chat-sidebar')
  await expect(sidebar.getByRole('button', { name: 'Personal assistant', exact: true })).toHaveAttribute(
    'aria-expanded',
    'false'
  )
  const task = sidebar.locator(`a[href="${path(`/conversations/${state.conversation_id}`)}"]`)
  await expect(task).toBeVisible()
  await expect(task.locator('..').getByRole('img', { name: 'Waiting for a decision', exact: true })).toBeVisible()
  await task.click()
  const card = page.locator('.pod-chat-choice-card[data-state="pending"]')
  await expect(card).toBeVisible({ timeout: 30_000 })
  await expect(card.locator('..')).toContainText('Legal colleague')
  const exchange = page.locator('[data-peer-exchange]').first()
  await exchange.getByRole('button', { name: 'View details', exact: true }).click()
  const drawer = page.getByRole('dialog')
  await expect(drawer).toContainText(state.colleague_uid)
  await expect(drawer).toContainText('contract')
  await drawer.getByRole('button', { name: 'Close', exact: true }).click()
  await card.getByRole('textbox', { name: 'Your answer', exact: true }).fill(state.answer)
  const response = page.waitForResponse(
    response =>
      response.request().method() === 'POST' && /\/interactions\/[^/]+\/answer$/.test(new URL(response.url()).pathname)
  )
  await card.getByRole('button', { name: 'Answer', exact: true }).click()
  expect((await response).status()).toBe(201)
  await expect(page.locator('.pod-chat-choice-card[data-state="answered"]')).toBeVisible()
  const reply = page
    .locator('.pod-chat-agent-message > div > .pod-chat-markdown')
    .filter({ hasText: state.facts[0] })
    .last()
  for (const fact of state.facts) await expect(reply).toContainText(fact, { timeout: 300_000 })
  const latest = page.getByRole('button', { name: 'Scroll to latest message', exact: true })
  if (await latest.isVisible()) await latest.click()
  await expect(reply).toBeInViewport()
  await expect(reply).toBeVisible()
  await expect(page.locator('.pod-chat-choice-card[data-state="pending"]')).toHaveCount(0)
  await expect(task).toHaveCount(0, { timeout: 30_000 })
  const exchanges = page.locator('[data-peer-exchange]')
  await expect(exchanges.getByRole('status').filter({ hasText: 'Decision needed' })).toHaveCount(0)
  await expect(exchanges.getByRole('button', { name: 'Stop response', exact: true })).toHaveCount(0)
  await capture('peer-answer')
  return { answered: true }
}

async function comment() {
  await page.goto(url(`/pages/${state.page_id}`))
  await page.locator('.pod-page-header').getByRole('button', { name: 'Comments', exact: true }).click()
  const panel = page.getByRole('complementary', { name: 'Comments', exact: true })
  const input = panel.getByRole('textbox', { name: 'Add a comment…', exact: true })
  await input.fill(`@${state.colleague_uid}`)
  await expect(panel.getByRole('option')).toHaveCount(1)
  await panel.getByRole('option').click()
  await input.press('End')
  await input.pressSequentially(state.text)
  await expect(input).toHaveValue(`@Legal colleague ${state.text}`)
  const response = page.waitForResponse(
    response =>
      response.request().method() === 'POST' &&
      new URL(response.url()).pathname.endsWith(`/pages/${state.page_id}/comments`)
  )
  await panel.getByRole('button', { name: 'Send', exact: true }).click()
  const result = await response
  expect(result.status()).toBe(201)
  const detail = await result.json()
  const reply = panel
    .locator(`[data-thread-id="${detail.comment.id}"] .pod-comment-entry`)
    .filter({ hasText: state.facts[0] })
    .last()
  for (const fact of state.facts) await expect(reply).toContainText(fact, { timeout: 300_000 })
  await expect(reply).toBeVisible()
  await capture('peer-comment-followup')
  return { comment_id: detail.comment.id }
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
    const toggle = page.getByRole('button', { name: 'Assistant', exact: true })
    const expandedBefore = await toggle.getAttribute('aria-expanded')
    if (expandedBefore !== 'true') await toggle.click()
    await expect(toggle).toHaveAttribute('aria-expanded', 'true')
    await expect.poll(() => new URL(page.url()).searchParams.get('chat')).toBe(uuidShorten(state.conversation_id))
    const panel = page.getByRole('complementary', { name: 'Assistant', exact: true })
    const title = await page.getByRole('textbox', { name: 'Page title', exact: true }).inputValue()
    await expect(panel.locator('.pod-page-chat-header')).toHaveAttribute('title', title)
    await expect(panel.getByRole('region', { name: 'Conversation messages', exact: true })).toContainText('Cedar')
    navigation.page_chat_expanded_before = expandedBefore
    navigation.page_chat_conversation_id = new URL(page.url()).searchParams.get('chat')
    await capture('report-updated-page-chat')
    await page.getByRole('button', { name: 'Close assistant', exact: true }).click()
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
    const chat = page.getByRole('dialog', { name: 'Assistant', exact: true })
    await expect(chat).toBeVisible()
    await chat.getByRole('button', { name: 'Close assistant', exact: true }).click()
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
  await expect(child).toHaveAttribute('href', podPagePath(state.child_id, state.child_title))
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
    edit_knowledge: editKnowledge,
    knowledge,
    answer_peer: answerPeer,
    comment,
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
