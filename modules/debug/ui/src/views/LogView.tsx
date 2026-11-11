import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { Pause, Play } from 'lucide-react'
import type { Row, TopicEvent } from '@/lib/types'
import { time } from '@/lib/format'
import { fresh, matches } from '@/lib/live'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Sheet, SheetContent } from '@/components/ui/sheet'
import { Level, Record, fields } from './TableView'
import { cn } from '@/lib/utils'

const LEVELS = ['trace', 'debug', 'info', 'warn', 'error']

// every line is one row of text, so the box draws only the lines in sight and spaces for the rest
const LINE = 26
const OVERSCAN = 20

/**
 * The log, oldest at the top and following the newest line while the reader is at the bottom: a
 * minimum level, a search, and a pause that holds the lines where they are.
 */
export function LogView({ data, live }: { data: Row; live: TopicEvent[] }) {
  const [min, setMin] = useState('trace')
  const [search, setSearch] = useState('')
  const [paused, setPaused] = useState<number | null>(null)
  const [picked, setPicked] = useState<Row | null>(null)
  const box = useRef<HTMLDivElement>(null)
  const pinned = useRef(true)
  const [view, setView] = useState({ top: 0, height: 800 })

  const lines = useMemo(() => {
    const read = ((data.rows as Row[] | undefined) ?? []).slice().reverse()
    let all: Row[] = [...read, ...fresh(read, live)]
    if (paused !== null) all = all.filter((r) => (r.seq as number) <= paused)
    const floor = LEVELS.indexOf(min)
    const q = search.trim().toLowerCase()
    return all
      .filter((r) => LEVELS.indexOf(String(r.level)) >= floor)
      .filter((r) => matches(r, q))
      .slice(-1000)
  }, [data, live, min, search, paused])

  useLayoutEffect(() => {
    const el = box.current
    if (el && pinned.current) el.scrollTop = el.scrollHeight
  }, [lines])

  useEffect(() => {
    const el = box.current
    if (!el) return
    const measure = () => setView({ top: el.scrollTop, height: el.clientHeight })
    measure()
    const seen = new ResizeObserver(measure)
    seen.observe(el)
    return () => seen.disconnect()
  }, [])

  const first = Math.max(0, Math.floor(view.top / LINE) - OVERSCAN)
  const last = Math.min(lines.length, Math.ceil((view.top + view.height) / LINE) + OVERSCAN)

  const newest = live.length ? live[live.length - 1].seq : 0

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-center gap-3">
        <div className="flex items-center gap-3" role="group" aria-label="Lowest level shown">
          {LEVELS.map((l) => (
            <button key={l} onClick={() => setMin(l)} className={cn('h-7 text-xs text-muted hover:text-ink', min === l && 'marked text-ink')}>
              {l}
            </button>
          ))}
        </div>
        <Input placeholder="Search the log" value={search} onChange={(e) => setSearch(e.target.value)} className="h-8 max-w-[300px]" />
        <Button size="sm" variant="outline" onClick={() => setPaused(paused === null ? newest || Number.MAX_SAFE_INTEGER : null)}>
          {paused === null ? <Pause /> : <Play />}
          {paused === null ? 'Pause' : 'Follow'}
        </Button>
        <span className="text-xs text-muted">{lines.length} lines</span>
      </div>
      <div
        ref={box}
        onScroll={(e) => {
          const el = e.currentTarget
          pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 24
          setView({ top: el.scrollTop, height: el.clientHeight })
        }}
        className="h-[calc(100vh-260px)] min-h-[320px] overflow-auto rounded-md border border-border bg-surface py-2 font-mono text-xs"
      >
        {lines.length === 0 && <p className="px-4 py-2 font-sans text-[13px] text-muted">Nothing logged at this level yet.</p>}
        <div style={{ height: first * LINE }} />
        {lines.slice(first, last).map((r) => (
          <LogLine key={String(r.seq)} row={r} pick={setPicked} />
        ))}
        <div style={{ height: (lines.length - last) * LINE }} />
      </div>
      <Sheet open={picked !== null} onOpenChange={(o) => !o && setPicked(null)}>
        {picked && (
          <SheetContent title={String(picked.message)}>
            <Record row={picked} />
          </SheetContent>
        )}
      </Sheet>
    </div>
  )
}

const LogLine = memo(function LogLine({ row: r, pick }: { row: Row; pick: (r: Row) => void }) {
  return (
    <div
      onClick={() => pick(r)}
      className="grid h-[26px] cursor-pointer grid-cols-[96px_44px_1fr] items-baseline gap-3 px-4 py-[3px] leading-5 hover:bg-raised/60"
    >
      <span className="text-muted">{time(r.at)}</span>
      <Level value={String(r.level)} />
      <span className="min-w-0 truncate">
        <span className="text-ink">{String(r.message)}</span>
        {r.span ? <span className="text-accent"> {String(r.span)}</span> : null}
        <span className="text-muted"> {fields(r.fields)}</span>
      </span>
    </div>
  )
})
