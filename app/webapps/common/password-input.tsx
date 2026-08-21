import { InputGroup, InputGroupAddon, InputGroupButton, InputGroupInput } from '@ankole/uikit'
import { RiEyeLine, RiEyeOffLine } from '@remixicon/react'
import { useState, type ComponentProps } from 'react'
import { useTranslation } from 'react-i18next'

/** Password field with a visibility toggle. Extra props reach the input. */
export function PasswordInput(props: Omit<ComponentProps<typeof InputGroupInput>, 'type'>) {
  const { t } = useTranslation()
  const [visible, setVisible] = useState(false)

  return (
    <InputGroup>
      <InputGroupInput type={visible ? 'text' : 'password'} {...props} />
      <InputGroupAddon align="inline-end">
        <InputGroupButton
          aria-label={visible ? t('common.hide_password') : t('common.show_password')}
          size="icon-xs"
          onClick={() => setVisible(current => !current)}>
          {visible ? <RiEyeOffLine aria-hidden /> : <RiEyeLine aria-hidden />}
        </InputGroupButton>
      </InputGroupAddon>
    </InputGroup>
  )
}
