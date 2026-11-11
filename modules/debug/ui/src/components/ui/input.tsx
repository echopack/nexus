import * as React from 'react'
import { cn } from '@/lib/utils'

export function Input({ className, ...props }: React.ComponentProps<'input'>) {
  return (
    <input
      className={cn(
        'h-[34px] w-full rounded-md border border-control bg-surface px-3 text-[13px] text-ink placeholder:text-muted outline-none focus-visible:border-accent',
        className,
      )}
      {...props}
    />
  )
}
