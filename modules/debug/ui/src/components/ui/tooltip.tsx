import * as React from 'react'
import * as T from '@radix-ui/react-tooltip'

export const TooltipProvider = T.Provider

/**
 * A tooltip on its child. `className` replaces the content's classes rather than adding to them.
 */
export function Tip({
  label,
  children,
  delay = 300,
  collisionPadding,
  className = 'z-50 rounded border border-border bg-raised px-2 py-1 text-xs text-ink',
}: {
  label: string
  children: React.ReactNode
  delay?: number
  collisionPadding?: number
  className?: string
}) {
  return (
    <T.Root delayDuration={delay}>
      <T.Trigger asChild>{children}</T.Trigger>
      <T.Portal>
        <T.Content sideOffset={6} collisionPadding={collisionPadding} className={className}>
          {label}
        </T.Content>
      </T.Portal>
    </T.Root>
  )
}
