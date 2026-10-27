import { describe, expect, test } from 'bun:test'

import { ankolePrettyLogOptions, formatPrettyLogMessage, isRoutineOTPApplicationStop } from './logs'

describe('pretty logs', () => {
  test('formats a supplied stream and drains its final line', async () => {
    const source = `
      import { Readable } from 'node:stream'
      import { runPrettyLogs } from ${JSON.stringify(new URL('./logs.ts', import.meta.url).href)}
      await runPrettyLogs(Readable.from([
        JSON.stringify({ severity: 'INFO', message: 'Phoenix started' }) + '\\n',
        'Vite ready\\n',
        JSON.stringify({ severity: 'ERROR', message: 'Final diagnostic' })
      ]))
    `
    const child = Bun.spawn([process.execPath, '-e', source], {
      stdin: 'ignore',
      stdout: 'pipe',
      stderr: 'pipe'
    })
    const [output, errors, status] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited
    ])

    expect(status).toBe(0)
    expect(errors).toBe('')
    expect(output).toContain('Phoenix started')
    expect(output).toContain('Vite ready')
    expect(output).toContain('Final diagnostic')
  })

  test('suppresses routine OTP application stops without suppressing failures', () => {
    const routineStop = {
      severity: 'NOTICE',
      event: 'logger.message',
      message: 'Application ankole exited: :stopped',
      error_logger: {
        report_cb: '&:application_controller.format_log/1',
        tag: 'info_report',
        type: 'std_info'
      }
    }

    expect(isRoutineOTPApplicationStop(routineStop)).toBe(true)
    expect(isRoutineOTPApplicationStop({ ...routineStop, message: 'Application ankole exited: eaddrinuse' })).toBe(
      false
    )
  })

  test('hides redundant Erlang formatter metadata from local output', () => {
    expect(ankolePrettyLogOptions().ignore?.split(',')).toContain('error_logger')
  })

  test('uses the control-plane message for activation code events', () => {
    const message = 'Control-plane activation code text'
    const formatted = formatPrettyLogMessage(
      {
        event: 'setup.bootstrap.activation_code_printed',
        message,
        activation_code: 'ABCDEFGH'
      },
      'message'
    )

    expect(formatted).toContain(message)
    expect(formatted).not.toContain('ABCDEFGH')
  })
})
