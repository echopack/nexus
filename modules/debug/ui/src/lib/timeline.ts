import type { Mark, MarkKind } from './types'

// a request's marks laid out for the waterfall: the tree in start order, each mark's own time, the
// totals per kind and the statements that ran more than once

export interface Placed {
  mark: Mark
  depth: number
  /** its time minus the time of the marks inside it */
  self: number
  children: number
}

/**
 * The marks depth first, each under the one it ran inside, siblings in start order.
 */
export function arrange(marks: Mark[]): Placed[] {
  const known = new Set(marks.map((m) => m.id))
  const kids = new Map<number, Mark[]>()
  for (const m of marks) {
    // a parent past the cap was not kept: hang it on the root
    const parent = known.has(m.parent) ? m.parent : 0
    const list = kids.get(parent)
    if (list) list.push(m)
    else kids.set(parent, [m])
  }
  for (const list of kids.values()) list.sort((a, b) => a.start - b.start || a.id - b.id)
  const out: Placed[] = []
  const walk = (parent: number, depth: number) => {
    for (const m of kids.get(parent) ?? []) {
      const inside = kids.get(m.id) ?? []
      const covered = inside.reduce((sum, c) => sum + c.ms, 0)
      out.push({ mark: m, depth, self: Math.max(0, m.ms - covered), children: inside.length })
      walk(m.id, depth + 1)
    }
  }
  walk(0, 0)
  return out
}

export interface Totals {
  count: Record<MarkKind, number>
  ms: Record<MarkKind, number>
  /** the action's own time, without what ran inside it */
  actionSelf: number
  hits: number
  misses: number
  /** time of the request no mark accounts for */
  untraced: number
}

export function totals(placed: Placed[], total: number): Totals {
  const zero = { middleware: 0, action: 0, span: 0, query: 0, cache: 0, mail: 0 }
  const t: Totals = { count: { ...zero }, ms: { ...zero }, actionSelf: 0, hits: 0, misses: 0, untraced: total }
  for (const p of placed) {
    const m = p.mark
    t.count[m.kind] += 1
    t.ms[m.kind] += m.ms
    if (m.kind === 'action') t.actionSelf += p.self
    if (m.note === 'hit') t.hits += 1
    if (m.note === 'miss') t.misses += 1
    if (p.depth === 0) t.untraced -= m.ms
  }
  t.untraced = Math.max(0, t.untraced)
  return t
}

export interface Repeat {
  statement: string
  count: number
  ms: number
  ids: Set<number>
}

/**
 * Statements that ran more than once, the costliest first: where an N+1 hides.
 */
export function repeated(marks: Mark[]): Repeat[] {
  const by = new Map<string, Repeat>()
  for (const m of marks) {
    if (m.kind !== 'query') continue
    const key = m.detail.replace(/\s+/g, ' ').trim()
    const r = by.get(key)
    if (r) {
      r.count += 1
      r.ms += m.ms
      r.ids.add(m.id)
    } else {
      by.set(key, { statement: key, count: 1, ms: m.ms, ids: new Set([m.id]) })
    }
  }
  return [...by.values()].filter((r) => r.count > 1).sort((a, b) => b.ms - a.ms || b.count - a.count)
}

/**
 * Round points along `[0, total]` ms for the axis: steps of 1, 2 or 5 times a power of ten, about
 * six of them.
 */
export function ticks(total: number): number[] {
  if (!(total > 0)) return [0]
  const rough = total / 6
  const power = Math.pow(10, Math.floor(Math.log10(rough)))
  const step = [1, 2, 5, 10].map((f) => f * power).find((s) => s >= rough) ?? 10 * power
  const out: number[] = []
  for (let at = 0; at <= total + step * 1e-9; at += step) out.push(at)
  return out
}
