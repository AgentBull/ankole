export async function copyText(text: string) {
  try {
    await navigator.clipboard.writeText(text)
  } catch {
    const textarea = document.createElement('textarea')
    textarea.value = text
    textarea.style.position = 'fixed'
    textarea.style.opacity = '0'
    document.body.appendChild(textarea)
    try {
      textarea.select()
      if (!document.execCommand('copy')) throw new Error('Clipboard copy failed')
    } finally {
      textarea.remove()
    }
  }
}
