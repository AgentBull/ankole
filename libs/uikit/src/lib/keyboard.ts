/** IME confirmation must not trigger menu actions, including Safari's keydown ordering. */
export function composingKey(event: Pick<KeyboardEvent, 'isComposing' | 'keyCode'>): boolean {
  return event.isComposing || event.keyCode === 229
}
