import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const badgeVariants = cva('inline-flex flex-none items-center whitespace-nowrap rounded-full px-2 h-5 text-xs font-medium tabular-nums', {
  variants: {
    tone: {
      positive: 'bg-pill-positive-bg text-pill-positive-ink',
      negative: 'bg-pill-negative-bg text-pill-negative-ink',
      warning: 'bg-pill-warning-bg text-pill-warning-ink',
      neutral: 'bg-pill-neutral-bg text-pill-neutral-ink',
    },
  },
  defaultVariants: { tone: 'neutral' },
})

export function Badge({ className, tone, ...props }: React.ComponentProps<'span'> & VariantProps<typeof badgeVariants>) {
  return <span className={cn(badgeVariants({ tone }), className)} {...props} />
}
