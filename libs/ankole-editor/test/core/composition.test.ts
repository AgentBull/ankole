import { expect, test } from 'bun:test'
import { Wordgard } from '../../src/core/editor'
import { compositionComplete, InputState } from '../../src/core/editor/input'
import browser from '../../src/core/editor/browser'
import { GardState, Transaction } from '../../src/core/state'
import { basicBuilders } from './schema'

/** A unit view replaces DOM drawing; production input handlers, lifecycle and transactions run unchanged. */
function fixture() {
  const calls: string[] = []
  const { doc, p } = basicBuilders
  const state = GardState.create({
    doc: doc(p('base')),
    selection: { anchor: 5 },
    config: [
      Wordgard.exceptionSink.of(error => {
        throw error
      }),
      compositionComplete.of(() => {
        expect((editor as unknown as { flushing?: number }).flushing ?? 0).toBe(0)
        calls.push('complete')
      }),
      Wordgard.updateListener.of(update => {
        expect(update.state).toBe(editor.state)
        calls.push('listener')
      })
    ]
  })
  const shell = {
    state,
    dispatch(spec: Transaction | Transaction.Spec) {
      const transactions = Transaction.append(spec instanceof Transaction ? spec : shell.state.update(spec))
      shell.state = transactions.at(-1)!.state
    },
    get composing(): boolean {
      return !!input.composing || input.compositionPending
    },
    get isFlushing(): boolean {
      return ((shell as unknown as { flushing?: number }).flushing ?? 0) !== 0
    },
    connected: true,
    contentDOM: { addEventListener() {}, removeEventListener() {}, contains: () => false },
    observer: {
      readSelectionRange() {},
      pollSelection() {},
      editorSelectionPending: true,
      takeDirty: () => null,
      ignore: (draw: () => void) => draw()
    },
    viewState: {
      flushedState: state,
      get state() {
        return editor.state
      },
      pending: [] as Transaction[],
      flush() {
        this.flushedState = editor.state
        this.pending = []
      },
      measure: () => 0
    },
    domReaders: [],
    domWriters: [],
    runUpdate() {
      calls.push('draw')
    },
    checkDir() {},
    scheduleFlush() {},
    flush() {
      Wordgard.prototype.flush.call(editor)
    },
    inputState: null! as InputState
  }
  const editor = shell as unknown as Wordgard
  const input = new InputState(editor)
  shell.inputState = input
  input.ensureHandlers(editor.state)
  return { editor, shell, input, calls }
}

test('an end without a composing text node completes once without requiring a redraw', () => {
  const { input, calls } = fixture()
  input.finishComposition()
  expect(calls).toEqual([])
  input.composing = { changes: 0, target: null }
  input.runHandlers('compositionend', new Event('compositionend'))
  input.finishComposition()
  expect(calls).toEqual(['complete'])
})

test('an abort during a draw completes after the drawn update listeners and outside flushing', () => {
  const { editor, shell, input, calls } = fixture()
  shell.viewState.pending.push(editor.state.update({}))
  input.composing = { changes: 1, target: null }
  shell.runUpdate = () => {
    calls.push('draw')
    input.clearComposition()
    expect(calls).toEqual(['draw'])
  }
  shell.flush()
  expect(calls).toEqual(['draw', 'listener', 'complete'])
  expect((shell as unknown as { flushing: number }).flushing).toBe(0)
  input.finishComposition()
  expect(calls).toEqual(['draw', 'listener', 'complete'])
})

test('normal completion survives a pending native input that prevents drawing', () => {
  const { input, calls } = fixture()
  input.composing = { changes: 1, target: {} as Text }
  input.pendingInputEvent = { inputType: 'insertCompositionText', data: '', domRange: null, readDOM: false }
  input.runHandlers('compositionend', new Event('compositionend'))
  expect(calls).toEqual(['complete'])
  expect(input.pendingInputEvent).not.toBeNull()
})

test.each([false, true])(
  'a synchronous compositionend during drawing waits for the outer flush (removed target=%s)',
  removedTarget => {
    const { shell, input, calls } = fixture()
    input.composing = { changes: 1, target: removedTarget ? ({} as Text) : null }
    shell.viewState.pending.push(shell.state.update({}))
    shell.runUpdate = () => {
      calls.push('draw')
      input.runHandlers('compositionend', new Event('compositionend'))
      expect(calls).toEqual(['draw'])
    }
    shell.flush()
    expect(calls).toEqual(['draw', 'listener', 'complete'])
    input.finishComposition()
    expect(calls).toEqual(['draw', 'listener', 'complete'])
  }
)

test('Safari finishes its previous composition before handling the same-stack ordinary input', () => {
  const { editor, input, calls } = fixture()
  const dispatch = editor.dispatch
  editor.dispatch = spec => {
    const transaction = spec instanceof Transaction ? spec : editor.state.update(spec)
    if (transaction.docChanged) calls.push(transaction.annotation(Transaction.userEvent)!)
    dispatch(transaction)
  }
  const safari = browser.safari
  try {
    browser.safari = true
    input.composing = { changes: 1, target: null }
    input.runHandlers('beforeinput', {
      inputType: 'insertText',
      data: 'x',
      cancelable: true,
      getTargetRanges: () => []
    } as unknown as InputEvent)
    expect(calls).toEqual(['complete', 'input.type'])
    expect(editor.state.doc.textContent()).toBe('basex')
    input.finishComposition()
    expect(calls).toEqual(['complete', 'input.type'])
  } finally {
    browser.safari = safari
  }
})

test('disconnect postpones an unconsumed completion until the editor reconnects', () => {
  const { input, shell, calls } = fixture()
  input.composing = { changes: 1, target: null }
  input.clearComposition()
  shell.connected = false
  input.disconnect()
  input.finishComposition()
  expect(calls).toEqual([])
  shell.connected = true
  input.connect()
  shell.flush()
  expect(calls).toEqual(['draw', 'complete'])
  input.finishComposition()
  expect(calls).toEqual(['draw', 'complete'])
})

test('reconnecting preserves Safari suppression of the trailing composition key', () => {
  const { input, shell } = fixture()
  const safari = browser.safari
  try {
    browser.safari = true
    input.composing = { changes: 1, target: null }
    input.runHandlers('compositionend', new Event('compositionend'))
    shell.connected = false
    input.disconnect()
    shell.connected = true
    input.connect()
    expect(input.ignoreDuringComposition(new Event('keydown'))).toBe(true)
    expect(input.ignoreDuringComposition(new Event('keydown'))).toBe(false)
  } finally {
    browser.safari = safari
  }
})

test('disconnect drops native tracking and pending input while preserving the model for completion', () => {
  const { editor, input, shell, calls } = fixture()
  const before = editor.state
  input.composing = { changes: 1, target: {} as Text }
  input.pendingInputEvent = { inputType: 'insertCompositionText', data: 'base', domRange: null, readDOM: false }
  shell.connected = false
  input.disconnect()
  expect(input.composing).toBeNull()
  expect(input.pendingInputEvent).toBeNull()
  input.finishComposition()
  expect(calls).toEqual([])
  expect(editor.state).toBe(before)
  shell.connected = true
  input.connect()
  shell.flush()
  expect(calls).toEqual(['draw', 'complete'])
})
