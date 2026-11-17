import { recordValue } from '@agentbull/active-support'
import { computed, createModel } from '@preact/signals-react'
import { assign, fromPromise, setup } from 'xstate'
import { requestErrorCode } from '../../common/request-errors'
import { createActorSignal } from '../../common/xstate-signals'
import { completeChatgptBrowserLogin, pollChatgptLogin, startChatgptLogin } from '../api/v2-site/generated/sdk.gen'

type ChatGPTLoginPayload = Record<string, unknown>

type ChatGPTLoginServices = {
  startLogin(input: {
    providerID: string
    id?: string
    label?: string
    priority: number
    signal: AbortSignal
  }): Promise<ChatGPTLoginPayload>
  pollLogin(input: {
    providerID: string
    loginContext: Record<string, unknown>
    signal: AbortSignal
  }): Promise<ChatGPTLoginPayload>
  completeBrowserLogin(input: {
    providerID: string
    loginContext: Record<string, unknown>
    callbackURL: string
    signal: AbortSignal
  }): Promise<void>
  onCompleted?(): void
}

type ValidationErrorKind = 'credential_label_required' | 'callback_url_required'

type ChatGPTLoginContext = {
  services: ChatGPTLoginServices
  providerID: string
  entryID: string | undefined
  initialLabel: string
  initialPriority: string
  label: string
  priority: string
  callbackURL: string
  login: ChatGPTLoginPayload | undefined
  validationError: ValidationErrorKind | undefined
  error: unknown
  hasStartedAttempt: boolean
}

type ChatGPTLoginEvent =
  | {
      type: 'OPEN'
      providerID: string
      entryID?: string
      label: string
      priority: string
    }
  | { type: 'CLOSE' }
  | { type: 'SET_LABEL'; label: string }
  | { type: 'SET_PRIORITY'; priority: string }
  | { type: 'SET_CALLBACK_URL'; callbackURL: string }
  | { type: 'SUBMIT' }

function textValue(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function numberValue(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

function retryChatGPTLoginPoll(error: unknown): boolean {
  const status =
    error && typeof error === 'object'
      ? ((error as { httpStatus?: unknown; status?: unknown }).httpStatus ?? (error as { status?: unknown }).status)
      : undefined
  return (
    requestErrorCode(error) === 'chatgpt_login_unreachable' ||
    status === 429 ||
    (typeof status === 'number' && status >= 500 && status < 600)
  )
}

function defaultServices(): ChatGPTLoginServices {
  return {
    async startLogin({ providerID, id, label, priority, signal }) {
      const { data } = await startChatgptLogin({
        path: { provider_id: providerID },
        body: { data: { id, label, priority } },
        signal,
        throwOnError: true
      })
      return recordValue(data) ?? {}
    },
    async pollLogin({ providerID, loginContext, signal }) {
      const { data } = await pollChatgptLogin({
        path: { provider_id: providerID },
        body: { data: { login_context: loginContext } },
        signal,
        throwOnError: true
      })
      return recordValue(data) ?? {}
    },
    async completeBrowserLogin({ providerID, loginContext, callbackURL, signal }) {
      await completeChatgptBrowserLogin({
        path: { provider_id: providerID },
        body: { data: { login_context: loginContext, callback_url: callbackURL } },
        signal,
        throwOnError: true
      })
    }
  }
}

function readOutput<T>(event: object): T | undefined {
  return 'output' in event ? (event as { output?: T }).output : undefined
}

function createChatGPTLoginMachine(services: ChatGPTLoginServices) {
  return setup({
    types: {
      context: {} as ChatGPTLoginContext,
      events: {} as ChatGPTLoginEvent
    },
    actors: {
      startLogin: fromPromise(async ({ input, signal }: { input: ChatGPTLoginContext; signal: AbortSignal }) => {
        return input.services.startLogin({
          providerID: input.providerID,
          id: input.entryID,
          label: input.label.trim() || input.initialLabel || undefined,
          priority: Number.parseInt(input.priority, 10) || 0,
          signal
        })
      }),
      pollLogin: fromPromise(async ({ input, signal }: { input: ChatGPTLoginContext; signal: AbortSignal }) => {
        const loginContext = recordValue(input.login?.login_context)
        if (!loginContext) throw new Error('Missing ChatGPT device login context')
        return input.services.pollLogin({
          providerID: input.providerID,
          loginContext,
          signal
        })
      }),
      completeBrowserLogin: fromPromise(
        async ({ input, signal }: { input: ChatGPTLoginContext; signal: AbortSignal }) => {
          const loginContext = recordValue(input.login?.login_context)
          if (!loginContext) throw new Error('Missing ChatGPT browser login context')
          await input.services.completeBrowserLogin({
            providerID: input.providerID,
            loginContext,
            callbackURL: input.callbackURL.trim(),
            signal
          })
        }
      )
    },
    delays: {
      devicePollDelay: ({ context }) => {
        const seconds = numberValue(context.login?.retry_after) ?? numberValue(context.login?.interval) ?? 5
        return Math.max(0, seconds * 1_000)
      }
    },
    guards: {
      isLabelBlank: ({ context }) => !context.label.trim(),
      isCallbackBlank: ({ context }) => !context.callbackURL.trim(),
      hasLoginContext: ({ context }) => Boolean(recordValue(context.login?.login_context)),
      isStartDeviceComplete: ({ event }) => {
        const payload = readOutput<ChatGPTLoginPayload>(event)
        return textValue(payload?.mode) === 'device' && textValue(payload?.status) === 'complete'
      },
      isStartDevicePending: ({ event }) => {
        const payload = readOutput<ChatGPTLoginPayload>(event)
        return textValue(payload?.mode) === 'device' && Boolean(recordValue(payload?.login_context))
      },
      isStartBrowserPaste: ({ event }) => {
        const payload = readOutput<ChatGPTLoginPayload>(event)
        return textValue(payload?.mode) === 'browser_paste'
      },
      isPollComplete: ({ event }) => {
        const payload = readOutput<ChatGPTLoginPayload>(event)
        return textValue(payload?.status) === 'complete'
      },
      isRetryablePollFailure: ({ event }) => 'error' in event && retryChatGPTLoginPoll(event.error)
    },
    actions: {
      seedDialog: assign(({ event }) => {
        if (event.type !== 'OPEN') return {}
        return {
          providerID: event.providerID,
          entryID: event.entryID,
          initialLabel: event.label,
          initialPriority: event.priority,
          label: event.label,
          priority: event.priority,
          callbackURL: '',
          login: undefined,
          validationError: undefined,
          error: undefined,
          hasStartedAttempt: false
        }
      }),
      clearDialog: assign({
        login: undefined,
        callbackURL: '',
        validationError: undefined,
        error: undefined,
        hasStartedAttempt: false
      }),
      updateLabel: assign(({ event }) =>
        event.type === 'SET_LABEL' ? { label: event.label, validationError: undefined } : {}
      ),
      updatePriority: assign(({ event }) => (event.type === 'SET_PRIORITY' ? { priority: event.priority } : {})),
      updateCallbackURL: assign(({ event }) =>
        event.type === 'SET_CALLBACK_URL' ? { callbackURL: event.callbackURL, validationError: undefined } : {}
      ),
      requireCredentialLabel: assign({
        validationError: 'credential_label_required' as const
      }),
      requireCallbackURL: assign({
        validationError: 'callback_url_required' as const
      }),
      prepareStartAttempt: assign({
        login: undefined,
        callbackURL: '',
        validationError: undefined,
        error: undefined,
        hasStartedAttempt: true
      }),
      prepareBrowserCompletion: assign({
        validationError: undefined,
        error: undefined
      }),
      storeStartedLogin: assign(({ event }) => ({
        login: readOutput<ChatGPTLoginPayload>(event),
        error: undefined
      })),
      mergePolledLogin: assign(({ context, event }) => ({
        login: {
          ...context.login,
          ...readOutput<ChatGPTLoginPayload>(event)
        },
        error: undefined
      })),
      storeFailure: assign(({ event }) => ({
        error: 'error' in event ? event.error : undefined
      })),
      notifyCompleted: ({ context }) => {
        context.services.onCompleted?.()
      }
    }
  }).createMachine({
    id: 'chatgptLogin',
    initial: 'closed',
    context: {
      services,
      providerID: '',
      entryID: undefined,
      initialLabel: '',
      initialPriority: '0',
      label: '',
      priority: '0',
      callbackURL: '',
      login: undefined,
      validationError: undefined,
      error: undefined,
      hasStartedAttempt: false
    },
    on: {
      OPEN: {
        target: '.editing',
        actions: 'seedDialog'
      },
      CLOSE: {
        target: '.closed',
        actions: 'clearDialog'
      }
    },
    states: {
      closed: {},
      editing: {
        on: {
          SET_LABEL: { actions: 'updateLabel' },
          SET_PRIORITY: { actions: 'updatePriority' },
          SUBMIT: [
            {
              guard: 'isLabelBlank',
              actions: 'requireCredentialLabel'
            },
            {
              target: 'starting',
              actions: 'prepareStartAttempt'
            }
          ]
        }
      },
      starting: {
        invoke: {
          src: 'startLogin',
          input: ({ context }) => context,
          onDone: [
            {
              guard: 'isStartDeviceComplete',
              target: 'completed',
              actions: ['storeStartedLogin', 'notifyCompleted']
            },
            {
              guard: 'isStartDevicePending',
              target: 'deviceFlow',
              actions: 'storeStartedLogin'
            },
            {
              guard: 'isStartBrowserPaste',
              target: 'browserPaste',
              actions: 'storeStartedLogin'
            },
            {
              target: 'editing',
              actions: 'storeStartedLogin'
            }
          ],
          onError: {
            target: 'failed',
            actions: 'storeFailure'
          }
        }
      },
      deviceFlow: {
        initial: 'waiting',
        states: {
          waiting: {
            after: {
              devicePollDelay: { target: 'polling' }
            }
          },
          polling: {
            invoke: {
              src: 'pollLogin',
              input: ({ context }) => context,
              onDone: [
                {
                  guard: 'isPollComplete',
                  target: '#chatgptLogin.completed',
                  actions: ['mergePolledLogin', 'notifyCompleted']
                },
                {
                  target: 'waiting',
                  actions: 'mergePolledLogin'
                }
              ],
              onError: [
                {
                  guard: 'isRetryablePollFailure',
                  target: 'waiting',
                  actions: 'storeFailure'
                },
                {
                  target: '#chatgptLogin.failed',
                  actions: 'storeFailure'
                }
              ]
            }
          }
        }
      },
      browserPaste: {
        initial: 'editingCallback',
        states: {
          editingCallback: {
            on: {
              SET_CALLBACK_URL: { actions: 'updateCallbackURL' },
              SUBMIT: [
                {
                  guard: 'isCallbackBlank',
                  actions: 'requireCallbackURL'
                },
                {
                  guard: 'hasLoginContext',
                  target: 'completing',
                  actions: 'prepareBrowserCompletion'
                }
              ]
            }
          },
          completing: {
            invoke: {
              src: 'completeBrowserLogin',
              input: ({ context }) => context,
              onDone: {
                target: '#chatgptLogin.completed',
                actions: 'notifyCompleted'
              },
              onError: {
                target: 'editingCallback',
                actions: 'storeFailure'
              }
            }
          }
        }
      },
      failed: {
        on: {
          SET_LABEL: { actions: 'updateLabel' },
          SET_PRIORITY: { actions: 'updatePriority' },
          SUBMIT: [
            {
              guard: 'isLabelBlank',
              actions: 'requireCredentialLabel'
            },
            {
              target: 'starting',
              actions: 'prepareStartAttempt'
            }
          ]
        }
      },
      completed: {}
    }
  })
}

export const ChatGPTLoginModel = createModel((customServices?: Partial<ChatGPTLoginServices>) => {
  let onCompletedRef: (() => void) | undefined
  const base = defaultServices()
  const services: ChatGPTLoginServices = {
    startLogin: customServices?.startLogin ?? base.startLogin,
    pollLogin: customServices?.pollLogin ?? base.pollLogin,
    completeBrowserLogin: customServices?.completeBrowserLogin ?? base.completeBrowserLogin,
    onCompleted: () => {
      customServices?.onCompleted?.()
      onCompletedRef?.()
    }
  }

  const machine = createActorSignal(createChatGPTLoginMachine(services))
  const snap = machine.snapshot

  const label = computed(() => snap.value.context.label)
  const priority = computed(() => snap.value.context.priority)
  const callbackURL = computed(() => snap.value.context.callbackURL)
  const login = computed(() => snap.value.context.login)
  const validationError = computed(() => snap.value.context.validationError)
  const error = computed(() => snap.value.context.error)
  const submitting = computed(
    () => snap.value.matches('starting') || snap.value.matches({ browserPaste: 'completing' })
  )
  const polling = computed(() => snap.value.matches({ deviceFlow: 'polling' }))
  const showingMetadataFields = computed(
    () => snap.value.matches('editing') || snap.value.matches('starting') || snap.value.matches('failed')
  )
  const showingDeviceFlow = computed(() => snap.value.matches('deviceFlow'))
  const showingBrowserPaste = computed(() => snap.value.matches('browserPaste'))
  const isRestart = computed(() => snap.value.matches('failed') && snap.value.context.hasStartedAttempt)
  const retryAfter = computed(
    () => numberValue(snap.value.context.login?.retry_after) ?? numberValue(snap.value.context.login?.interval) ?? 5
  )
  const loginContext = computed(() => recordValue(snap.value.context.login?.login_context))
  const dirty = computed(() => {
    const ctx = snap.value.context
    const activeFlow = snap.value.matches('deviceFlow') || snap.value.matches('browserPaste')
    return (
      activeFlow ||
      ctx.label !== ctx.initialLabel ||
      ctx.priority !== ctx.initialPriority ||
      ctx.callbackURL.trim() !== ''
    )
  })

  return {
    snapshot: snap,
    label,
    priority,
    callbackURL,
    login,
    validationError,
    error,
    submitting,
    polling,
    showingMetadataFields,
    showingDeviceFlow,
    showingBrowserPaste,
    isRestart,
    retryAfter,
    loginContext,
    dirty,
    setOnCompleted(callback: (() => void) | undefined) {
      onCompletedRef = callback
    },
    open(input: { providerID: string; entryID?: string; label: string; priority: string }) {
      machine.send({ type: 'OPEN', ...input })
    },
    close() {
      machine.send({ type: 'CLOSE' })
    },
    setLabel(next: string) {
      machine.send({ type: 'SET_LABEL', label: next })
    },
    setPriority(next: string) {
      machine.send({ type: 'SET_PRIORITY', priority: next })
    },
    setCallbackURL(next: string) {
      machine.send({ type: 'SET_CALLBACK_URL', callbackURL: next })
    },
    submit() {
      machine.send({ type: 'SUBMIT' })
    }
  }
})
