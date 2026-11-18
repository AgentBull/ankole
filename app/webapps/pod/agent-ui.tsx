import {
  Button,
  destructiveAgentConfirm,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogTitle
} from '@ankole/uikit'
import type { AgentAction } from '@ankole/uikit/lib/agent'
import type { TFunction } from 'i18next'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { connectAgentUI } from './agent-ui-bridge'
import { useContent } from './content-context'

type Confirmation = { agentName?: string; step: AgentAction; answer(allowed: boolean): void }

/** A press names the button the Agent wants to press; any other action shows its name and arguments as the Agent sent them. */
function describeStep({ action, args, label, component }: AgentAction, t: TFunction) {
  const control = label ?? component
  // A press on a menu or dialog carries the text of the button inside it.
  if (action === 'press') {
    return t('pod.agent_ui.confirm_press', { control: typeof args[0] === 'string' ? args[0] : control })
  }
  return t('pod.agent_ui.confirm_description', {
    control,
    action: args.length ? `${action} ${args.map(arg => JSON.stringify(arg)).join(', ')}` : action
  })
}

/**
 * Connects this tab to the Agents that operate Pod for the signed-in person, and asks the person before an Agent
 * runs a step on a control marked `data-agent-confirm`, such as a destructive button.
 */
export function PodAgentUI() {
  const { t } = useTranslation()
  const { realtime } = useContent()
  const [confirmation, setConfirmation] = useState<Confirmation>()

  useEffect(
    () =>
      connectAgentUI(
        realtime,
        (agentName, step, signal) =>
          new Promise<boolean>(resolve => {
            if (signal.aborted) return resolve(false)
            const answer = (allowed: boolean) => {
              signal.removeEventListener('abort', refuse)
              setConfirmation(shown => (shown === pending ? undefined : shown))
              resolve(allowed)
            }
            const refuse = () => answer(false)
            const pending: Confirmation = { agentName, step, answer }
            signal.addEventListener('abort', refuse, { once: true })
            setConfirmation(pending)
          })
      ),
    [realtime]
  )

  const agent = confirmation?.agentName ?? t('pod.agent_ui.browser_assistant')
  return (
    <Dialog open={!!confirmation} onOpenChange={open => !open && confirmation?.answer(false)}>
      {/* The bridge must not see this dialog, or an Agent could answer it for the person. */}
      <DialogContent data-agent-hidden closeLabel={t('common.close')}>
        {confirmation && (
          <>
            <DialogTitle>{t('pod.agent_ui.confirm_title', { agent })}</DialogTitle>
            <DialogDescription>{describeStep(confirmation.step, t)}</DialogDescription>
            {/* The kit's English sentence for every destructive button adds nothing to the localised description. */}
            {confirmation.step.confirm !== destructiveAgentConfirm && <p>{confirmation.step.confirm}</p>}
            <DialogFooter>
              <Button variant="outline" onClick={() => confirmation.answer(false)}>
                {t('pod.agent_ui.deny')}
              </Button>
              <Button onClick={() => confirmation.answer(true)}>{t('pod.agent_ui.allow')}</Button>
            </DialogFooter>
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}
