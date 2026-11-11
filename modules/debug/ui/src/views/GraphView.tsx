import { useMemo } from 'react'
import type { Row } from '@/lib/types'
import { tone } from '@/lib/format'
import { Badge } from '@/components/ui/badge'
import { Frame } from '@/components/ViewSection'
import { Record } from './TableView'
import { cn } from '@/lib/utils'

interface Node {
  id: string
  label: string
  state: string
  current?: boolean
}

interface Edge {
  from: string
  to: string
}

/**
 * Nodes in columns by how many steps they wait behind, each column in order, with what each waits
 * for named under it; the record of the node asked for beside them.
 */
export function GraphView({ data }: { data: Row }) {
  const { nodes, columns, before, label } = useMemo(() => {
    const nodes = (data.nodes as Node[] | undefined) ?? []
    const edges = (data.edges as Edge[] | undefined) ?? []
    const after = new Map<string, string[]>()
    edges.forEach((e) => after.set(e.to, [...(after.get(e.to) ?? []), e.from]))
    const labels = new Map(nodes.map((n) => [n.id, n.label]))
    const before = (id: string) => after.get(id) ?? []
    const depth = new Map<string, number>()
    const level = (id: string, seen: Set<string>): number => {
      if (depth.has(id)) return depth.get(id)!
      if (seen.has(id)) return 0
      seen.add(id)
      const d = before(id).reduce((m, b) => Math.max(m, level(b, seen) + 1), 0)
      depth.set(id, d)
      return d
    }
    nodes.forEach((n) => level(n.id, new Set()))
    const columns: Node[][] = []
    nodes.forEach((n) => {
      const d = depth.get(n.id) ?? 0
      ;(columns[d] ??= []).push(n)
    })
    return { nodes, columns, before, label: (id: string) => labels.get(id) ?? id }
  }, [data])

  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_420px]">
      <Frame className="overflow-x-auto">
        {nodes.length === 0 ? (
          <p className="text-muted">No task is connected to this one.</p>
        ) : (
          <div className="flex gap-8">
            {columns.map((col, i) => (
              <div key={i} className="flex min-w-[200px] flex-col gap-3">
                <div className="text-xs text-muted">{i === 0 ? 'Waits for nothing' : `Step ${i + 1}`}</div>
                {col.map((n) => (
                  <div key={n.id} className={cn('rounded-md border bg-raised px-3 py-2.5', n.current ? 'border-accent' : 'border-border')}>
                    <div className="flex items-center justify-between gap-2">
                      <span className="truncate font-medium">{n.label}</span>
                      <Badge tone={tone(n.state)}>{n.state}</Badge>
                    </div>
                    <div className="mt-1 truncate font-mono text-xs text-muted">{n.id}</div>
                    {before(n.id).length > 0 && (
                      <div className="mt-1 truncate text-xs text-muted">after {before(n.id).map(label).join(', ')}</div>
                    )}
                  </div>
                ))}
              </div>
            ))}
          </div>
        )}
      </Frame>
      {data.task !== undefined && (
        <Frame>
          <Record row={data.task as Row} />
        </Frame>
      )}
    </div>
  )
}
