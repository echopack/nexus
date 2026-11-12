import { useMemo, useState } from 'react'
import { ChevronRight } from 'lucide-react'
import type { Mark, MarkKind, Row, Timeline } from '@/lib/types'
import { ms, number } from '@/lib/format'
import { arrange, repeated, ticks, totals, type Placed, type Repeat } from '@/lib/timeline'
import { Frame } from '@/components/ViewSection'
import { Tip } from '@/components/ui/tooltip'
import { FigureGrid, type Figure } from '@/components/FigureGrid'
import { cn } from '@/lib/utils'

const KIND: Record<MarkKind, { label: string; bar: string }> = {
  middleware: { label: 'Middleware', bar: 'bg-control' },
  action: { label: 'Action', bar: 'bg-accent' },
  span: { label: 'Span', bar: 'bg-ink/60' },
  query: { label: 'Query', bar: 'bg-warning' },
  cache: { label: 'Cache', bar: 'bg-positive' },
  mail: { label: 'Mail', bar: 'bg-accent/50' },
  files: { label: 'Files', bar: 'bg-positive/50' },
}

const LEVEL_BAR: Record<string, string> = { error: 'bg-negative', warn: 'bg-warning', info: 'bg-ink/70' }

// a tooltip for text of several lines, like a whole statement
const HINT = {
  delay: 150,
  collisionPadding: 12,
  className: 'z-50 max-w-[520px] whitespace-pre-wrap break-words rounded border border-border bg-raised px-2.5 py-1.5 font-mono text-xs leading-relaxed text-ink',
}

/**
 * Where one request spent its time: the figures that matter first, then every mark as a bar on one
 * axis, nested in the mark it ran inside, the lines it logged as ticks above them, and the
 * statements it ran more than once.
 */
export function TimelineView({ data }: { data: Row }) {
  const timeline = data.timeline as Timeline | undefined
  const logs = (data.logs as Row[] | undefined) ?? []
  const placed = useMemo(() => arrange(timeline?.marks ?? []), [timeline])
  const repeats = useMemo(() => repeated(timeline?.marks ?? []), [timeline])
  const [closed, setClosed] = useState<Set<number>>(() => new Set())
  const [lit, setLit] = useState<Repeat | null>(null)

  if (!timeline) return <Frame><p className="text-muted">This request has no timeline.</p></Frame>
  const total = Math.max(timeline.total, 0.001)
  const sum = totals(placed, timeline.total)
  const shown = visible(placed, closed)
  const toggle = (id: number) =>
    setClosed((c) => {
      const next = new Set(c)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })

  return (
    <div className="flex flex-col gap-5">
      <Figures total={timeline.total} sum={sum} />
      {timeline.dropped > 0 && (
        <p className="text-xs text-warning">{number(timeline.dropped)} marks past the cap were counted, not kept.</p>
      )}
      <div className="rounded-md border border-border bg-surface">
        <Axis total={total} />
        <LogLane logs={logs} began={timeline.began} total={total} />
        {placed.length === 0 && <p className="px-4 py-3 text-muted">Nothing was marked inside this request.</p>}
        <div className="divide-y divide-rule">
          {shown.map((p) => (
            <Bar
              key={p.mark.id}
              placed={p}
              total={total}
              closed={closed.has(p.mark.id)}
              toggle={toggle}
              dim={lit !== null && !lit.ids.has(p.mark.id)}
            />
          ))}
        </div>
      </div>
      <Legend />
      {repeats.length > 0 && <Repeats repeats={repeats} lit={lit} light={setLit} />}
    </div>
  )
}

// the marks whose parents are all open
function visible(placed: Placed[], closed: Set<number>): Placed[] {
  const out: Placed[] = []
  let hideBelow = Infinity
  for (const p of placed) {
    if (p.depth > hideBelow) continue
    hideBelow = closed.has(p.mark.id) ? p.depth : Infinity
    out.push(p)
  }
  return out
}

function Figures({ total, sum }: { total: number; sum: ReturnType<typeof totals> }) {
  const share = (v: number) => (total > 0 ? `${Math.round((v / total) * 100)}% of the request` : undefined)
  const figures: Figure[] = [
    { label: 'Total', value: ms(total) },
    { label: 'Action itself', value: ms(sum.actionSelf), hint: share(sum.actionSelf) },
    {
      label: 'Database',
      value: ms(sum.ms.query),
      hint: `${number(sum.count.query)} ${sum.count.query === 1 ? 'query' : 'queries'} · ${share(sum.ms.query) ?? ''}`,
      tone: total > 0 && sum.ms.query / total > 0.5 ? 'text-warning' : undefined,
    },
    { label: 'Cache', value: ms(sum.ms.cache), hint: `${number(sum.hits)} hits · ${number(sum.misses)} misses` },
  ]
  if (sum.count.mail > 0) figures.push({ label: 'Mail', value: ms(sum.ms.mail), hint: `${number(sum.count.mail)} sent` })
  figures.push({ label: 'Untraced', value: ms(sum.untraced), hint: 'inside no mark' })
  return <FigureGrid figures={figures} size="compact" />
}

const GRID = 'grid grid-cols-[minmax(0,300px)_minmax(0,1fr)_72px] items-center gap-3 px-4'

function Axis({ total }: { total: number }) {
  return (
    <div className={cn(GRID, 'h-8 border-b border-rule text-xs text-muted')}>
      <span>Mark</span>
      <div className="relative h-full">
        {ticks(total).map((at) => (
          <span
            key={at}
            className="absolute top-1/2 -translate-y-1/2 whitespace-nowrap tabular-nums [&:not(:first-child)]:-translate-x-1/2"
            style={{ left: `${(at / total) * 100}%` }}
          >
            {at === 0 ? '0' : ms(at)}
          </span>
        ))}
      </div>
      <span className="text-right">Took</span>
    </div>
  )
}

function LogLane({ logs, began, total }: { logs: Row[]; began: string; total: number }) {
  const start = new Date(began).getTime()
  if (!logs.length || Number.isNaN(start)) return null
  return (
    <div className={cn(GRID, 'h-7 border-b border-rule')}>
      <span className="text-xs text-muted">Logged</span>
      <div className="relative h-full">
        {logs.map((line, i) => {
          const at = new Date(String(line.at)).getTime() - start
          if (Number.isNaN(at)) return null
          const left = Math.min(100, Math.max(0, (at / total) * 100))
          return (
            <Tip key={i} label={`${String(line.level)} at ${ms(Math.max(0, at))}\n${String(line.message)}`} {...HINT}>
              <span
                className={cn('absolute top-1.5 bottom-1.5 w-[3px] -translate-x-1/2 rounded-sm', LEVEL_BAR[String(line.level)] ?? 'bg-muted')}
                style={{ left: `${left}%` }}
              />
            </Tip>
          )
        })}
      </div>
      <span className="text-right text-xs tabular-nums text-muted">{logs.length}</span>
    </div>
  )
}

function Bar({
  placed,
  total,
  closed,
  toggle,
  dim,
}: {
  placed: Placed
  total: number
  closed: boolean
  toggle: (id: number) => void
  dim: boolean
}) {
  const m = placed.mark
  const left = Math.min(100, (m.start / total) * 100)
  const width = Math.min(100 - left, (m.ms / total) * 100)
  return (
    <div className={cn(GRID, 'h-8 hover:bg-raised/60', dim && 'opacity-30')}>
      <div className="flex min-w-0 items-center gap-1.5" style={{ paddingLeft: placed.depth * 14 }}>
        {placed.children > 0 ? (
          <button
            className="flex-none rounded p-0.5 text-muted hover:bg-raised hover:text-ink"
            aria-label={closed ? `Open ${m.name}` : `Close ${m.name}`}
            onClick={() => toggle(m.id)}
          >
            <ChevronRight className={cn('size-3.5 transition-transform', !closed && 'rotate-90')} />
          </button>
        ) : (
          <span className="w-[18px] flex-none" />
        )}
        <span className={cn('size-2 flex-none rounded-sm', KIND[m.kind].bar)} />
        <span className="truncate font-mono text-xs">
          {label(m)}
          {m.detail && <span className="ml-2 text-muted">{m.detail}</span>}
        </span>
      </div>
      <Tip label={describe(placed)} {...HINT}>
        <div className="relative h-full">
          <span
            className={cn('absolute top-2 bottom-2 min-w-px rounded-sm', KIND[m.kind].bar, m.failed && 'ring-1 ring-negative')}
            style={{ left: `${left}%`, width: `${width}%` }}
          />
        </div>
      </Tip>
      <span className={cn('text-right text-xs tabular-nums', m.failed && 'text-negative')}>{ms(m.ms)}</span>
    </div>
  )
}

function label(m: Mark): string {
  if (m.kind === 'query') return m.note ? `query · ${m.note}` : 'query'
  if (m.kind === 'cache' && m.note) return `${m.name} · ${m.note}`
  return m.name
}

function describe(p: Placed): string {
  const m = p.mark
  const what = m.name === m.kind ? KIND[m.kind].label : `${KIND[m.kind].label}: ${m.name}`
  const lines = [`${what}${m.failed ? ' (failed)' : ''}`]
  if (m.detail) lines.push(m.detail)
  if (m.note) lines.push(m.note)
  lines.push(`at ${ms(m.start)} · took ${ms(m.ms)}${p.children > 0 ? ` · itself ${ms(p.self)}` : ''}`)
  return lines.join('\n')
}

function Legend() {
  return (
    <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted">
      {Object.entries(KIND).map(([kind, k]) => (
        <span key={kind} className="inline-flex items-center gap-1.5">
          <span className={cn('size-2 rounded-sm', k.bar)} />
          {k.label}
        </span>
      ))}
      <span className="inline-flex items-center gap-1.5">
        <span className="size-2 rounded-sm ring-1 ring-negative" />
        Failed
      </span>
    </div>
  )
}

function Repeats({ repeats, lit, light }: { repeats: Repeat[]; lit: Repeat | null; light: (r: Repeat | null) => void }) {
  return (
    <div>
      <h3 className="mb-1 text-[15px] font-semibold">Repeated queries</h3>
      <p className="mb-2 text-xs text-muted">The same statement more than once, often a query per row that one query could answer. Pick one to light its bars.</p>
      <div className="flex flex-col divide-y divide-rule rounded-md border border-border bg-surface">
        {repeats.map((r) => {
          const on = lit?.statement === r.statement
          return (
            <button
              key={r.statement}
              onClick={() => light(on ? null : r)}
              className={cn('grid grid-cols-[56px_72px_minmax(0,1fr)] items-center gap-3 px-4 py-2 text-left hover:bg-raised/60', on && 'bg-raised')}
            >
              <span className="font-mono text-xs text-warning">×{r.count}</span>
              <span className="text-right text-xs tabular-nums">{ms(r.ms)}</span>
              <span className={cn('truncate font-mono text-xs', on && 'marked')}>{r.statement}</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}
