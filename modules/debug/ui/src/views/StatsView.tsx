import type { Row } from '@/lib/types'
import { number } from '@/lib/format'
import { Frame } from '@/components/ViewSection'
import { FigureGrid } from '@/components/FigureGrid'

interface Stat {
  label: string
  value: unknown
  hint?: string
}

export function StatsView({ data }: { data: Row }) {
  const stats = (data.stats as Stat[] | undefined) ?? []
  if (!stats.length) return <Frame><p className="text-muted">No figures yet.</p></Frame>
  return <FigureGrid figures={stats.map((s) => ({ label: s.label, value: number(s.value), hint: s.hint }))} />
}
