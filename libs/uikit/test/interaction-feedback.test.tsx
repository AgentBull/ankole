import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import { Button } from '../src/components/button'
import { CopyButton, CopyIcon } from '../src/components/copy-button'
import { RollingNumber } from '../src/components/rolling-number'
import { Skeleton } from '../src/components/skeleton'
import { StepTransition, stepEnter } from '../src/components/step-transition'

function Icon(props: { 'aria-hidden'?: boolean; className?: string }) {
  return <svg data-testid="icon" {...props} />
}

describe('Button loading', () => {
  test('turns the leading icon into the spinner and keeps the label, so the button keeps its width', () => {
    const html = renderToStaticMarkup(
      <Button loading>
        <Icon className="size-3.5" />
        Save
      </Button>
    )

    expect(html).toContain('aria-busy="true"')
    expect(html).toContain('data-loading="true"')
    expect(html).toContain('data-slot="spinner"')
    expect(html).toContain('size-3.5')
    expect(html).not.toContain('data-testid="icon"')
    expect(html).toContain('data-busy-label="Save"')
    // A loading button stays focusable and reports one busy state, not a second status inside it.
    expect(html).not.toContain('disabled=""')
    expect(html).not.toContain('role="status"')
  })

  test('adds nothing to a text-only button and leaves a trailing icon in place', () => {
    const textOnly = renderToStaticMarkup(<Button loading>Save</Button>)
    expect(textOnly).not.toContain('data-slot="spinner"')
    expect(textOnly).toContain('data-busy-label="Save"')

    const trailing = renderToStaticMarkup(
      <Button loading>
        Continue
        <Icon />
      </Button>
    )
    expect(trailing).not.toContain('data-slot="spinner"')
    expect(trailing).toContain('data-testid="icon"')
  })

  test('swaps only a marked icon when the caller sets aria-busy alone', () => {
    const unmarked = renderToStaticMarkup(
      <Button aria-busy>
        <Icon />
        Save
      </Button>
    )
    expect(unmarked).toContain('data-testid="icon"')
    expect(unmarked).not.toContain('data-slot="spinner"')

    const marked = renderToStaticMarkup(
      <Button aria-busy>
        <Icon aria-hidden />
        Save
      </Button>
    )
    expect(marked).toContain('data-slot="spinner"')
    expect(marked).not.toContain('data-testid="icon"')
  })

  test('renders its children untouched at rest', () => {
    const html = renderToStaticMarkup(
      <Button>
        <Icon />
        Save
      </Button>
    )
    expect(html).toContain('data-testid="icon"')
    expect(html).not.toContain('aria-busy')
    expect(html).not.toContain('data-loading')
  })
})

describe('CopyButton', () => {
  test('names the action, shows the copy mark at rest, and keeps an empty announcement region', () => {
    const html = renderToStaticMarkup(<CopyButton value="secret" label="Copy link" copiedLabel="Copied" />)

    expect(html).toContain('aria-label="Copy link"')
    expect(html).toContain('title="Copy link"')
    expect(html).toContain('data-slot="copy-icon"')
    expect(html).not.toContain('data-copied')
    expect(html).toContain('<span class="sr-only" aria-live="polite"></span>')
    // The announcement region is not a status role, so a page keeps one status per surface.
    expect(html).not.toContain('role="status"')
  })

  test('shows a visible label without animating it on the first render', () => {
    const html = renderToStaticMarkup(
      <CopyButton value="secret" label="Copy link" copiedLabel="Copied">
        Copy
      </CopyButton>
    )

    expect(html).toContain('<span>Copy</span>')
    expect(html).not.toContain('animate-label-swap')
    expect(html).not.toContain('title=')
  })

  test('marks a confirmed copy on the mark itself', () => {
    expect(renderToStaticMarkup(<CopyIcon copied />)).toContain('data-copied="true"')
    expect(renderToStaticMarkup(<CopyIcon copied={false} />)).not.toContain('data-copied')
  })
})

describe('RollingNumber', () => {
  test('renders a figure as one plain text node before it changes', () => {
    expect(renderToStaticMarkup(<RollingNumber value="48,920" />)).toBe(
      '<span data-slot="rolling-number" class="tabular-nums">48,920</span>'
    )
    expect(renderToStaticMarkup(<RollingNumber value={7} className="text-lg" />)).toContain('>7</span>')
  })
})

describe('Skeleton', () => {
  test('is a still block that the shared sweep animates', () => {
    const html = renderToStaticMarkup(<Skeleton className="h-4 w-20" />)

    expect(html).toContain('data-slot="skeleton"')
    expect(html).toContain('bg-skeleton')
    expect(html).not.toContain('animate-pulse')
  })
})

describe('StepTransition', () => {
  test('renders the first step still and tells the step which way it travels', () => {
    const html = renderToStaticMarkup(
      <StepTransition step="email" className="grid">
        <p>Enter your email</p>
      </StepTransition>
    )

    expect(html).toContain('data-slot="step-transition"')
    expect(html).toContain('class="group/step-transition grid"')
    expect(html).toContain('--step-from:8px')
    // The entrance plays only inside a frame that has moved.
    expect(html).not.toContain('data-moved="true"')
    expect(html).toContain('data-slot="step-transition-step"')
    expect(html).toContain('<p>Enter your email</p>')
    expect(renderToStaticMarkup(<StepTransition step="code" direction="back" />)).toContain('--step-from:-8px')
  })

  test('leaves the steps to a caller that keeps them mounted', () => {
    const html = renderToStaticMarkup(
      <StepTransition step="email" keyed={false}>
        <p className={stepEnter}>Email</p>
        <p hidden className={stepEnter}>
          Space
        </p>
      </StepTransition>
    )

    expect(html).not.toContain('data-slot="step-transition-step"')
    expect(html).toContain('>Email</p>')
    expect(html).toContain('hidden=""')
  })
})
