import { type ClassValue, clsx } from 'clsx'
import { extendTailwindMerge } from 'tailwind-merge'

const typeSteps = ['25', '50', '65', '75', '85', '100', '200', '300', '400', '500', '600', '700', '800']

/**
 * tailwind-merge knows Tailwind's default scales only, so it reads an Ankole type step such as `text-75` as a
 * colour and drops `text-foreground` beside it, and it keeps both `rounded-control` and `rounded-surface`. The
 * kit therefore tells it the names that `theme.css` adds to each scale.
 */
const twMerge = extendTailwindMerge({
  extend: {
    theme: {
      text: [...typeSteps, ...typeSteps.map(step => `num-${step}`)],
      radius: ['control', 'mini', 'micro', 'panel', 'surface'],
      spacing: ['top-bar', 'sidebar'],
      shadow: ['control'],
      blur: ['composer']
    }
  }
})

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
