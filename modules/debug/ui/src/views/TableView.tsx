import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import type { ActionSpec, Column, Row, TopicEvent, View } from '@/lib/types'
import { readView, viewQuery } from '@/lib/api'
import { asText, missing, numeric, text, tone } from '@/lib/format'
import { fresh, matches } from '@/lib/live'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Sheet, SheetContent } from '@/components/ui/sheet'
import { Frame } from '@/components/ViewSection'
import { TimelineView } from '@/views/TimelineView'
import { GraphView } from '@/views/GraphView'
import { FieldsView } from '@/views/FieldsView'
import { JsonView } from '@/views/JsonView'
import { cn } from '@/lib/utils'

const SHOWN = 200

/**
 * Rows under the view's columns, newest first when live: what the panel read, then every event of
 * the view's topic since. A row opens its whole record, and the view's detail view beside it.
 */
export function TableView({
  view,
  detail,
  data,
  live,
  run,
  rowActions,
  open,
}: {
  view: View
  detail?: View
  data: Row
  live: TopicEvent[]
  run: (a: ActionSpec, input: Row) => void
  rowActions: ActionSpec[]
  open: (target: string, key: string, value: unknown) => void
}) {
  const columns = view.columns ?? []
  const [search, setSearch] = useState('')
  const [picked, setPicked] = useState<Row | null>(null)

  const rows = useMemo((): Row[] => {
    const read = (data.rows as Row[] | undefined) ?? []
    if (!view.topic) return read
    return [...fresh(read, live).reverse(), ...read]
  }, [data, live, view.topic])

  const shown = useMemo(() => {
    const q = search.trim().toLowerCase()
    const hits = q ? rows.filter((r) => matches(r, q)) : rows
    return hits.slice(0, SHOWN)
  }, [rows, search])

  return (
    <div>
      {rows.length > 8 && (
        <div className="mb-3 flex items-center gap-3">
          <Input placeholder="Search these rows" value={search} onChange={(e) => setSearch(e.target.value)} className="h-8 max-w-[300px]" />
          <span className="text-xs text-muted">
            {shown.length < rows.length ? `${shown.length} of ${rows.length}` : `${rows.length}`} rows
          </span>
        </div>
      )}
      {rows.length === 0 ? (
        <Frame>
          <p className="text-muted">{view.topic ? 'Nothing yet. New ones appear here as they happen.' : 'Nothing here.'}</p>
        </Frame>
      ) : (
        <div className="overflow-x-auto rounded-md border border-border bg-surface">
          <table className="w-full border-collapse text-[13px]">
            <thead>
              <tr className="h-10 text-left text-xs text-muted">
                {columns.map((c) => (
                  <th key={c.key} className={cn('whitespace-nowrap px-4 font-normal', numeric(c.format) && 'text-right')}>
                    {c.title}
                  </th>
                ))}
                {rowActions.length > 0 && <th className="sticky right-0 w-px bg-surface px-4" />}
              </tr>
            </thead>
            <tbody>
              {shown.map((r, i) => (
                <tr
                  key={typeof r.seq === 'number' ? r.seq : i}
                  onClick={() => setPicked(r)}
                  className="h-[42px] cursor-pointer border-t border-rule hover:bg-raised/60"
                >
                  {columns.map((c) => (
                    <td key={c.key} className={cn('max-w-[360px] truncate px-4', numeric(c.format) && 'text-right')}>
                      <Cell column={c} value={r[c.key]} open={open} />
                    </td>
                  ))}
                  {rowActions.length > 0 && (
                    <td className="sticky right-0 whitespace-nowrap bg-surface px-4 text-right" onClick={(e) => e.stopPropagation()}>
                      {rowActions.filter((a) => applies(a, r)).map((a) => (
                        <Button key={a.name} size="sm" variant={a.destructive ? 'destructive' : 'ghost'} onClick={() => run(a, r)}>
                          {a.title}
                        </Button>
                      ))}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Sheet open={picked !== null} onOpenChange={(o) => !o && setPicked(null)}>
        {picked && (
          <SheetContent title={headline(picked, columns)} className={cn(detail && 'max-w-[1100px]')}>
            {detail ? <Tabbed detail={detail} row={picked} /> : <Record row={picked} />}
          </SheetContent>
        )}
      </Sheet>
    </div>
  )
}

/**
 * A row's sheet with its detail view first and its fields a tab away.
 */
function Tabbed({ detail, row }: { detail: View; row: Row }) {
  const [tab, setTab] = useState<'detail' | 'record'>('detail')
  return (
    <div className="flex flex-col gap-5">
      <div className="flex gap-5 border-b border-rule pb-2 text-[13px]" role="tablist">
        {(
          [
            ['detail', detail.title],
            ['record', 'Details'],
          ] as const
        ).map(([key, title]) => (
          <button
            key={key}
            role="tab"
            aria-selected={tab === key}
            onClick={() => setTab(key)}
            className={cn('pb-1', tab === key ? 'marked text-ink' : 'text-muted hover:text-ink')}
          >
            {title}
          </button>
        ))}
      </div>
      {tab === 'detail' ? <Detail view={detail} row={row} /> : <Record row={row} />}
    </div>
  )
}

// the detail view read with its filters taken from the row
function Detail({ view, row }: { view: View; row: Row }) {
  const filters = view.filters ?? []
  const lacking = filters.filter((f) => missing(row[f]))
  const query = viewQuery(view, row)
  const data = useQuery({
    queryKey: ['detail', view.url, query],
    queryFn: () => readView(view, query),
    enabled: lacking.length === 0,
    staleTime: Infinity,
  })
  if (lacking.length) return <Frame><p className="text-muted">This row has no {lacking.join(', ')} to open it by.</p></Frame>
  if (data.error) return <Frame><p className="text-negative">{data.error.message}</p></Frame>
  if (!data.data) return <Frame><p className="text-muted">Reading…</p></Frame>
  switch (view.kind) {
    case 'timeline':
      return <TimelineView data={data.data} />
    case 'graph':
      return <GraphView data={data.data} />
    case 'fields':
      return <FieldsView data={data.data} />
    default:
      return <JsonView data={data.data} />
  }
}

function applies(a: ActionSpec, r: Row): boolean {
  if (!a.when) return true
  const [key, value] = a.when.split('=', 2)
  return String(r[key] ?? '') === value
}

function headline(r: Row, columns: Column[]): string {
  if (r.method && r.target) return `${r.method} ${r.target}`
  if (r.name && r.id) return `${r.name} ${r.id}`
  const first = columns[0]
  return first ? String(r[first.key] ?? 'Record') : 'Record'
}

function Cell({ column, value, open }: { column: Column; value: unknown; open: (target: string, key: string, value: unknown) => void }) {
  if (missing(value)) return <span className="text-muted">—</span>
  const shown = text(value, column.format)
  if (column.link) {
    return (
      <button
        className="font-mono text-xs text-accent hover:underline"
        onClick={(e) => {
          e.stopPropagation()
          open(column.link!, column.key, value)
        }}
      >
        {shown}
      </button>
    )
  }
  switch (column.format) {
    case 'status':
      return <Badge tone={tone(value)}>{shown}</Badge>
    case 'level':
      return <Level value={String(value)} />
    case 'code':
      return <span className="font-mono text-xs">{shown}</span>
    case 'time':
      return <span className="font-mono text-xs text-muted">{shown}</span>
    case 'number':
    case 'ms':
      return <span className="tabular-nums">{shown}</span>
    default:
      return <span>{shown}</span>
  }
}

const LEVEL_TONE = { negative: 'text-negative', warning: 'text-warning' } as const

export function Level({ value }: { value: string }) {
  const t = tone(value)
  const color = t === 'negative' || t === 'warning' ? LEVEL_TONE[t] : value === 'info' ? 'text-ink' : 'text-muted'
  return <span className={cn('font-mono text-xs', color)}>{value}</span>
}

/**
 * A record laid out for reading: its plain fields as label and value, then its nested ones (the
 * headers, the lines it logged, a task's data) each under its name.
 */
export function Record({ row }: { row: Row }) {
  const plain = Object.entries(row).filter(([, v]) => v === null || typeof v !== 'object')
  const nested = Object.entries(row).filter(([, v]) => v !== null && typeof v === 'object')
  return (
    <div className="flex flex-col gap-6">
      <dl className="divide-y divide-rule">
        {plain.map(([k, v]) => (
          <div key={k} className="grid grid-cols-[140px_1fr] gap-4 py-2">
            <dt className="text-muted">{k}</dt>
            <dd className="break-all font-mono text-xs leading-5">{String(v)}</dd>
          </div>
        ))}
      </dl>
      {nested.map(([k, v]) => (
        <div key={k}>
          <h3 className="mb-2 text-[15px] font-semibold">{k}</h3>
          {k === 'logs' && Array.isArray(v) ? (
            <div className="flex flex-col divide-y divide-rule rounded-md border border-border">
              {v.length === 0 && <p className="px-3 py-2 text-muted">It logged nothing.</p>}
              {(v as Row[]).map((line, i) => (
                <div key={i} className="flex flex-wrap gap-x-3 px-3 py-2 font-mono text-xs">
                  <Level value={String(line.level)} />
                  <span className="text-ink">{String(line.message)}</span>
                  <span className="text-muted">{fields(line.fields)}</span>
                </div>
              ))}
            </div>
          ) : (
            <pre className="overflow-auto rounded-md border border-border p-3 font-mono text-xs leading-relaxed">{JSON.stringify(v, null, 2)}</pre>
          )}
        </div>
      ))}
    </div>
  )
}

export function fields(f: unknown): string {
  if (!f || typeof f !== 'object') return ''
  return Object.entries(f as Row)
    .map(([k, v]) => `${k}=${asText(v)}`)
    .join(' ')
}
