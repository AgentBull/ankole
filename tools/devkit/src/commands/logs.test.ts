import { describe, expect, test } from 'bun:test'

import { ankolePrettyLogOptions, formatPrettyLogMessage, isRoutineOTPApplicationStop } from './logs'

describe('pretty logs', () => {
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
