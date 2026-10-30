import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger
} from '@ankole/uikit/components/dropdown-menu'
import { RiCheckLine, RiGlobalLine } from '@remixicon/react'

type LocaleItem = {
  href: string
  label: string
  active: boolean
}

interface LanguageDropdownProps {
  /** Accessible label for the trigger button. */
  label: string
  items: LocaleItem[]
}

export default function LanguageDropdown({ label, items }: LanguageDropdownProps) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        aria-label={label}
        title={label}
        className="inline-flex size-9 items-center justify-center text-muted-foreground transition-colors hover:bg-muted hover:text-foreground">
        <RiGlobalLine className="size-5" />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-auto min-w-36">
        {items.map(item => (
          <DropdownMenuItem
            key={item.href}
            render={<a href={item.href} aria-current={item.active ? 'true' : undefined} />}
            className="flex cursor-pointer items-center justify-between gap-4 px-4 py-2 no-underline">
            <span>{item.label}</span>
            {item.active ? (
              <RiCheckLine aria-hidden="true" className="size-4 text-brand-60 dark:text-brand-40" />
            ) : null}
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
