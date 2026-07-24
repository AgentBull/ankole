import { motion, useReducedMotion } from 'motion/react'
import type { ReactNode } from 'react'

/** Carbon expressive entrance easing, expressed as a cubic-bezier control array. */
const EXPRESSIVE_ENTRANCE = [0, 0, 0.3, 1] as const

/**
 * `rise` moves content a short distance along the vertical grid axis.
 * `wipe` uncovers content along the horizontal grid axis, the Carbon reveal.
 */
type RevealVariant = 'rise' | 'wipe'

interface RevealProps {
  children?: ReactNode
  variant?: RevealVariant
  /** Seconds of offset, used to stagger the members of one row or grid. */
  delay?: number
  className?: string
}

const HIDDEN: Record<RevealVariant, Record<string, string | number>> = {
  rise: { opacity: 0, y: 16 },
  wipe: { opacity: 0, clipPath: 'inset(0 100% 0 0)' }
}

const SHOWN: Record<RevealVariant, Record<string, string | number>> = {
  rise: { opacity: 1, y: 0 },
  wipe: { opacity: 1, clipPath: 'inset(0 0% 0 0)' }
}

export default function Reveal({ children, variant = 'rise', delay = 0, className }: RevealProps) {
  const reduced = useReducedMotion()

  if (reduced) {
    return (
      <div className={className} data-reveal>
        {children}
      </div>
    )
  }

  return (
    <motion.div
      className={className}
      data-reveal
      initial={HIDDEN[variant]}
      whileInView={SHOWN[variant]}
      viewport={{ once: true, amount: 0.2 }}
      transition={{ duration: variant === 'wipe' ? 0.64 : 0.5, ease: EXPRESSIVE_ENTRANCE, delay }}>
      {children}
    </motion.div>
  )
}
