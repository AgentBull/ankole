type SpinnerProps = Omit<React.ComponentPropsWithoutRef<'svg'>, 'children'>

/**
 * The one spinner of every Ankole surface: an arc that turns while it grows and shrinks, drawn in the current
 * text color over a faint track. It is an SVG, so button and icon slots size it like any other icon.
 */
function Spinner(props: SpinnerProps) {
  return (
    <svg data-slot="spinner" role="status" aria-label="Loading" viewBox="0 0 16 16" fill="none" {...props}>
      <circle data-part="track" cx="8" cy="8" r="6.5" pathLength="100" />
      <circle data-part="arc" cx="8" cy="8" r="6.5" pathLength="100" />
    </svg>
  )
}

export { Spinner }
