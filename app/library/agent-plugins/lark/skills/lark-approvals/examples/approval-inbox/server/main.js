/** Publish this Applet and create one human-authorized `inbox` Job per subscriber.
 * Job config: { connection: "the-auth-config-slug" }. */
const tool = (ctx, server, name, args) =>
  AnkoleRuntime.mcp.call(name, args, { server, connection: ctx.job.config.connection })

function card(task, jobId, outcome, notice, submitting) {
  return {
    config: { wide_screen_mode: true },
    header: { title: { tag: 'plain_text', content: task.title || 'Approval' } },
    elements: [
      { tag: 'div', text: { tag: 'plain_text', content: outcome || notice || 'Your approval is required.' } },
      ...(outcome || submitting
        ? []
        : [
            {
              tag: 'action',
              actions: ['approve', 'reject'].map(decision => ({
                tag: 'button',
                text: { tag: 'plain_text', content: decision === 'approve' ? 'Approve' : 'Reject' },
                type: decision === 'approve' ? 'primary' : 'danger',
                value: { jobId, taskId: task.task_id, decision }
              }))
            }
          ])
    ]
  }
}

async function writeback(ctx, entry) {
  await tool(ctx, 'lark_im', 'im_update_message', {
    message_id: entry.messageId,
    msg_type: 'interactive',
    content: card(entry.task, ctx.job.id, entry.outcome, entry.notice, entry.submitting)
  })
}

async function decide(ctx) {
  const data = ctx.signal.data
  const value = typeof data.action?.value === 'string' ? JSON.parse(data.action.value) : data.action?.value
  if (value?.jobId !== ctx.job.id) return { ignored: 'another_job' }
  if (data.operator_principal_uid !== ctx.principal.uid) return { ignored: 'another_operator' }
  if (!['approve', 'reject'].includes(value.decision)) throw new Error('Unknown decision')
  const key = `task:${value.taskId}`
  const entry = await ctx.state.get(key)
  if (!entry || entry.messageId !== data.context?.open_message_id) return { ignored: 'unknown_card' }
  if (entry.outcome) {
    await writeback(ctx, entry)
    return { taskId: value.taskId, outcome: entry.outcome }
  }
  // A lost response needs manual verification. A second click must not repeat the approval.
  if (entry.submitting) {
    entry.notice = 'The decision status is uncertain. Check this task in Lark before taking another action.'
    await writeback(ctx, entry)
    throw new Error('Verify this task in Lark before retrying an uncertain decision')
  }
  await ctx.state.set(key, { ...entry, submitting: true })
  try {
    await tool(ctx, 'lark_approvals', `approvals_${value.decision}`, {
      approval_code: entry.task.definition_code,
      instance_code: entry.task.process_code,
      task_id: entry.task.task_id
    })
  } catch (error) {
    const rejected = ['oauth_consent_required', 'upstream_rejected', 'upstream_rate_limited'].includes(error.code)
    if (rejected || error.request_sent === false) {
      entry.submitting = false
      entry.notice =
        error.code === 'upstream_rate_limited'
          ? 'Lark is busy. Your decision was not submitted; please try again shortly.'
          : 'Your decision was not submitted. Please resolve the connection error and try again.'
    } else {
      entry.submitting = true
      entry.notice = 'The decision status is uncertain. Check this task in Lark before taking another action.'
    }
    await ctx.state.set(key, entry)
    await writeback(ctx, entry)
    throw error
  }
  entry.outcome = value.decision === 'approve' ? 'Approved' : 'Rejected'
  await ctx.state.set(key, entry)
  await writeback(ctx, entry)
  return { taskId: value.taskId, outcome: entry.outcome }
}

async function poll(ctx) {
  let pageToken = ctx.run.progress.pageToken
  do {
    const page = await tool(ctx, 'lark_approvals', 'approvals_list_tasks', {
      topic: '1',
      page_size: 100,
      ...(pageToken ? { page_token: pageToken } : {})
    })
    for (const task of page.tasks || []) {
      const key = `task:${task.task_id}`
      let entry = await ctx.state.get(key)
      if (entry?.messageId) continue
      if (!entry) {
        entry = { task, uuid: crypto.randomUUID() }
        await ctx.state.set(key, entry)
      }
      const sent = await tool(ctx, 'lark_im', 'im_send_message', {
        principal_uid: ctx.principal.uid,
        msg_type: 'interactive',
        content: card(task, ctx.job.id),
        uuid: entry.uuid
      })
      await ctx.state.set(key, { ...entry, messageId: sent.message_id })
    }
    pageToken = page.has_more ? page.page_token : null
    if (pageToken && ctx.remainingMs() < 10000) return ctx.continueSlice({ progress: { pageToken } })
  } while (pageToken)
  return { refreshed: true }
}

export default {
  actions: {
    inbox: {
      idempotent: false,
      concurrency: 'serial_fifo',
      maxSlices: 100,
      handler: async ctx => {
        if (ctx.principal?.kind !== 'human') throw new Error('Create a personal Job for this inbox')
        return ctx.signal.type === 'card.action.trigger' ? decide(ctx) : poll(ctx)
      }
    }
  }
}
