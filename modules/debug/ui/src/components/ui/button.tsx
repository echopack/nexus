import * as React from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const buttonVariants = cva(
  'inline-flex shrink-0 items-center justify-center gap-1.5 whitespace-nowrap rounded-full text-[13px] font-medium transition-colors outline-none focus-visible:ring-2 focus-visible:ring-accent disabled:pointer-events-none disabled:opacity-50 [&_svg]:size-3.5 [&_svg]:shrink-0',
  {
    variants: {
      variant: {
        default: 'bg-ink text-ground hover:bg-ink/90',
        outline: 'border border-control text-ink hover:bg-raised',
        ghost: 'text-ink hover:bg-raised',
        destructive: 'border border-negative/50 text-negative hover:bg-negative/10',
        danger: 'bg-negative text-white hover:bg-negative/90',
        quiet: 'text-muted hover:text-ink',
      },
      size: {
        default: 'h-[34px] px-4',
        sm: 'h-7 px-3 text-xs',
      },
    },
    defaultVariants: { variant: 'default', size: 'default' },
  },
)

export function Button({ className, variant, size, ...props }: React.ComponentProps<'button'> & VariantProps<typeof buttonVariants>) {
  return <button className={cn(buttonVariants({ variant, size, className }))} {...props} />
}
