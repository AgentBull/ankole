import { batch, createModel, signal } from '@preact/signals-react'

export const PrincipalRenameModel = createModel(() => {
  const open = signal(false)
  const newUID = signal('')
  return {
    open,
    newUID,
    start(uid: string) {
      batch(() => {
        newUID.value = uid
        open.value = true
      })
    }
  }
})
