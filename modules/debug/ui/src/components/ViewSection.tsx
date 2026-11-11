import { useState } from 'react'
import { useSearchParams } from 'react-router'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { RefreshCw } from 'lucide-react'
import { ApiError, apiBase, post, readView, viewQuery } from '@/lib/api'
import type { ActionSpec, Panel, Row, View } from '@/lib/types'
import { useTopic } from '@/lib/live'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Confirm } from '@/components/ui/sheet'
import { Tip } from '@/components/ui/tooltip'
import { StatsView } from '@/views/StatsView'
import { FieldsView } from '@/views/FieldsView'
import { TableView } from '@/views/TableView'
import { LogView } from '@/views/LogView'
import { JsonView } from '@/views/JsonView'
import { GraphView } from '@/views/GraphView'
import { TimelineView } from '@/views/TimelineView'
import { cn } from '@/lib/utils'

/**
 * One view of a panel: its heading, filters and actions, and its data drawn by its kind, read again
 * on its refresh and kept live on its topic.
 */
export function ViewSection({ panel, view }: { panel: Panel; view: View }) {
  const [params, setParams] = useSearchParams()
  const client = useQueryClient()
  const filters = Object.fromEntries((view.filters ?? []).map((f) => [f, params.get(f) ?? '']))
  const query = viewQuery(view, filters)
  const needs = (view.kind === 'graph' || view.kind === 'timeline') && (view.filters ?? []).some((f) => !filters[f])
  const detail = view.detail ? panel.views.find((v) => v.name === view.detail) : undefined

  const data = useQuery({
    queryKey: ['view', panel.name, view.name, query],
    queryFn: () => readView(view, query),
    refetchInterval: view.refresh ? view.refresh * 1000 : false,
    enabled: !needs,
  })
  const live = useTopic(view.topic)

  const [said, setSaid] = useState<{ text: string; bad: boolean } | null>(null)
  const [asking, setAsking] = useState<{ action: ActionSpec; input: Row } | null>(null)
  const act = useMutation({
    mutationFn: ({ action, input }: { action: ActionSpec; input: Row }) =>
      post<{ message?: string }>(`${apiBase}/panels/${panel.name}/actions/${action.name}`, input),
    onSuccess: (r) => {
      setSaid({ text: r.message ?? 'Done.', bad: false })
      client.invalidateQueries({ queryKey: ['view', panel.name] })
    },
    onError: (e) => setSaid({ text: e instanceof ApiError ? e.message : String(e), bad: true }),
  })
  const run = (action: ActionSpec, input: Row) => {
    if (action.confirm) setAsking({ action, input })
    else act.mutate({ action, input })
  }

  const setFilter = (name: string, value: string) => {
    const next = new URLSearchParams(params)
    if (value) next.set(name, value)
    else next.delete(name)
    setParams(next, { replace: true })
  }

  const open = (target: string, key: string, value: unknown) => {
    const next = new URLSearchParams(params)
    next.set(key, String(value))
    setParams(next)
    requestAnimationFrame(() => document.getElementById(`view-${target}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' }))
  }

  const viewActions = (view.actions ?? []).filter((a) => !a.row)
  const rowActions = (view.actions ?? []).filter((a) => a.row)

  return (
    <section id={`view-${view.name}`} className="scroll-mt-6">
      <div className="mb-3 flex flex-wrap items-end gap-x-4 gap-y-2">
        <h2 className="text-[20px] font-normal leading-tight text-muted">{view.title}</h2>
        {view.topic && <LiveState state={live.state} />}
        <div className="ml-auto flex flex-wrap items-center gap-2">
          {(view.filters ?? []).map((f) => (
            <Input
              key={f}
              aria-label={f}
              placeholder={f}
              defaultValue={filters[f]}
              onKeyDown={(e) => e.key === 'Enter' && setFilter(f, (e.target as HTMLInputElement).value.trim())}
              onBlur={(e) => setFilter(f, e.target.value.trim())}
              className="h-7 w-[180px] font-mono text-xs"
            />
          ))}
          {viewActions.map((a) => (
            <Button key={a.name} size="sm" variant={a.destructive ? 'destructive' : 'outline'} onClick={() => run(a, filters)}>
              {a.title}
            </Button>
          ))}
          <Tip label="Read again">
            <Button size="sm" variant="quiet" aria-label="Read again" onClick={() => data.refetch()} disabled={needs}>
              <RefreshCw className={cn(data.isFetching && 'animate-spin')} />
            </Button>
          </Tip>
        </div>
      </div>
      {said && (
        <p className={cn('mb-3 text-[13px]', said.bad ? 'text-negative' : 'text-positive')} role="status">
          {said.text}
        </p>
      )}
      <Body view={view} detail={detail} data={data.data} error={data.error} pending={data.isPending && !needs} needs={needs} live={live.events} run={run} rowActions={rowActions} open={open} />
      {asking && (
        <Confirm
          open
          onOpenChange={(o) => !o && setAsking(null)}
          title={`${asking.action.title}?`}
          body={describe(asking.action, asking.input)}
          action={asking.action.title}
          destructive={asking.action.destructive}
          onConfirm={() => act.mutate(asking)}
        />
      )}
    </section>
  )
}

function describe(a: ActionSpec, input: Row): string {
  const id = input.id ?? input.name
  if (a.row && id) return `${a.title} ${String(id)}. This acts on the running app.`
  return `${a.title} for this view. This acts on the running app.`
}

function LiveState({ state }: { state: string }) {
  const tone = state === 'live' ? 'bg-positive' : state === 'retrying' ? 'bg-warning' : 'bg-muted'
  return (
    <span className="mb-0.5 inline-flex items-center gap-1.5 text-xs text-muted">
      <span className={cn('size-1.5 rounded-full', tone)} />
      {state === 'live' ? 'Live' : state === 'retrying' ? 'Reconnecting' : 'Connecting'}
    </span>
  )
}

function Body({
  view,
  detail,
  data,
  error,
  pending,
  needs,
  live,
  run,
  rowActions,
  open,
}: {
  view: View
  detail?: View
  data: Row | undefined
  error: Error | null
  pending: boolean
  needs: boolean
  live: { seq: number; at: string; data: Row }[]
  run: (a: ActionSpec, input: Row) => void
  rowActions: ActionSpec[]
  open: (target: string, key: string, value: unknown) => void
}) {
  if (needs) {
    return (
      <Frame>
        <p className="text-muted">Pick one: open an id from a table above, or type it into the {view.filters?.join(', ')} field.</p>
      </Frame>
    )
  }
  if (error) {
    return (
      <Frame>
        <p className="text-negative">{error.message}</p>
      </Frame>
    )
  }
  if (pending || !data) {
    return (
      <Frame>
        <p className="text-muted">Reading…</p>
      </Frame>
    )
  }
  switch (view.kind) {
    case 'stats':
      return <StatsView data={data} />
    case 'fields':
      return <FieldsView data={data} />
    case 'table':
      return <TableView view={view} detail={detail} data={data} live={live} run={run} rowActions={rowActions} open={open} />
    case 'log':
      return <LogView data={data} live={live} />
    case 'graph':
      return <GraphView data={data} />
    case 'timeline':
      return <TimelineView data={data} />
    default:
      return <JsonView data={data} />
  }
}

export function Frame({ children, className }: { children: React.ReactNode; className?: string }) {
  return <div className={cn('rounded-md border border-border bg-surface px-5 py-4', className)}>{children}</div>
}
