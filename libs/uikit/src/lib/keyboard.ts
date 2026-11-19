/** Guards keyboard shortcuts and Enter submissions during IME composition, including Safari's keydown ordering. */
export function composingKey(event: Pick<KeyboardEvent, 'isComposing' | 'keyCode'>): boolean {
  return event.isComposing || event.keyCode === 229
}
