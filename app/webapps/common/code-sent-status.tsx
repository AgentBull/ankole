import { useTranslation } from 'react-i18next'
import { devMailboxPath } from './browser-context'

export function CodeSentStatus({ email }: { email: string }) {
  const { t } = useTranslation()
  const mailboxPath = devMailboxPath()

  return (
    <p role="status" className="break-words text-sm text-muted-foreground">
      {t('auth.code_sent', { email })}
      {mailboxPath && (
        <>
          {' '}
          <a href={mailboxPath} target="_blank" rel="noreferrer" className="link whitespace-nowrap">
            {t('auth.view_dev_mailbox')}
          </a>
        </>
      )}
    </p>
  )
}
