type SpinnerProps = Omit<React.ComponentPropsWithoutRef<'svg'>, 'children'>

/**
 * The one spinner of every Ankole surface: an arc that turns while it grows and shrinks, drawn in the current
 * text color over a faint track. It is an SVG, so button and icon slots size it like any other icon.
 * Decorative by default (`aria-hidden`); supplying `aria-label` or `aria-labelledby` exposes `role="status"`.
 */
function Spinner({ 'aria-hidden': ariaHidden, role, ...props }: SpinnerProps) {
  const labelled = Boolean(props['aria-label'] || props['aria-labelledby'])
  const resolvedHidden = ariaHidden ?? (labelled ? undefined : true)
  const resolvedRole = role ?? (labelled && !resolvedHidden ? 'status' : undefined)

  return (
    <svg
      data-slot="spinner"
      aria-hidden={resolvedHidden}
      role={resolvedRole}
      viewBox="0 0 16 16"
      fill="none"
      {...props}>
      <circle data-part="track" cx="8" cy="8" r="6.5" pathLength="100" />
      <circle data-part="arc" cx="8" cy="8" r="6.5" pathLength="100" />
    </svg>
  )
}

export { Spinner }
