import { cn } from '@/lib/utils'

export interface Figure {
  label: string
  value: string
  hint?: string
  tone?: string
}

const SIZE = {
  regular: {
    cell: 'border-rule px-5 py-4 [&:not(:last-child)]:border-r',
    value: 'mt-1 text-[20px] font-medium leading-tight tabular-nums',
    hint: 'mt-0.5 text-xs text-muted',
  },
  compact: {
    cell: 'border-rule px-4 py-3 [&:not(:last-child)]:border-r',
    value: 'mt-1 text-[18px] font-medium leading-tight tabular-nums',
    hint: 'mt-0.5 truncate text-xs text-muted',
  },
}

/**
 * Figures side by side, two to a row on narrow screens: each a label, its value large and an
 * optional hint under it.
 */
export function FigureGrid({ figures, size = 'regular' }: { figures: Figure[]; size?: keyof typeof SIZE }) {
  const s = SIZE[size]
  return (
    <div className="grid grid-cols-2 overflow-hidden rounded-md border border-border bg-surface md:grid-flow-col md:auto-cols-fr md:grid-cols-none">
      {figures.map((f, i) => (
        <div key={i} className={s.cell}>
          <div className="text-xs text-muted">{f.label}</div>
          <div className={cn(s.value, f.tone)}>{f.value}</div>
          {f.hint && <div className={s.hint}>{f.hint}</div>}
        </div>
      ))}
    </div>
  )
}
