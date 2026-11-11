import { useCallback, useEffect, useSyncExternalStore } from 'react'
import { follow, type StreamState } from './stream'
import type { Row, TopicEvent } from './types'

// one stream per topic, however many views follow it, closed when the last one leaves

const KEEP = 1000

interface Feed {
  snapshot: { events: TopicEvent[]; state: StreamState }
  // events not yet in the snapshot: a burst is added once per frame
  pending: TopicEvent[]
  frame?: number
  users: number
  stop?: () => void
  listeners: Set<() => void>
}

const feeds = new Map<string, Feed>()

function feed(topic: string): Feed {
  let f = feeds.get(topic)
  if (!f) {
    f = { snapshot: { events: [], state: 'connecting' }, pending: [], users: 0, listeners: new Set() }
    feeds.set(topic, f)
  }
  return f
}

function changed(f: Feed, next: Partial<Feed['snapshot']>): void {
  f.snapshot = { ...f.snapshot, ...next }
  f.listeners.forEach((l) => l())
}

function flush(f: Feed): void {
  f.frame = undefined
  const all = f.snapshot.events.concat(f.pending)
  f.pending = []
  changed(f, { events: all.length > KEEP ? all.slice(all.length - KEEP) : all })
}

function join(topic: string): () => void {
  const f = feed(topic)
  f.users++
  if (!f.stop) {
    const seen = f.pending.length ? f.pending : f.snapshot.events
    const last = seen.length ? seen[seen.length - 1].seq : 0
    f.stop = follow(
      topic,
      last,
      (e) => {
        f.pending.push(e)
        // a hidden tab gets no frames, so it keeps no more than it would show
        if (f.pending.length > KEEP) f.pending.shift()
        f.frame ??= requestAnimationFrame(() => flush(f))
      },
      (s) => changed(f, { state: s }),
    )
  }
  return () => {
    f.users--
    if (f.users === 0 && f.stop) {
      f.stop()
      f.stop = undefined
    }
  }
}

/**
 * The events of `live` newer than every row `read`, as rows, oldest first: each event's data with
 * its `seq`, and its `at` unless the data carries one.
 */
export function fresh(read: Row[], live: TopicEvent[]): Row[] {
  const newest = read.reduce((n, r) => Math.max(n, typeof r.seq === 'number' ? r.seq : 0), 0)
  return live.filter((e) => e.seq > newest).map(row)
}

// an event keeps one row for as long as it is kept, so what is cached about the row stays found
const rows = new WeakMap<TopicEvent, Row>()

function row(e: TopicEvent): Row {
  let r = rows.get(e)
  if (!r) {
    r = { at: e.at, ...e.data, seq: e.seq }
    rows.set(e, r)
  }
  return r
}

/**
 * Whether `r` holds `q`, a lowercased search; an empty one holds everywhere.
 */
export function matches(r: Row, q: string): boolean {
  if (!q) return true
  let text = searched.get(r)
  if (text === undefined) {
    text = JSON.stringify(r).toLowerCase()
    searched.set(r, text)
  }
  return text.includes(q)
}

// a row's text as a search reads it, made once per row
const searched = new WeakMap<Row, string>()

/**
 * The events of `topic` this tab has seen, oldest first, and how its stream stands. An empty name
 * follows nothing.
 */
export function useTopic(topic: string | undefined): { events: TopicEvent[]; state: StreamState } {
  const f = topic ? feed(topic) : undefined
  const subscribe = useCallback(
    (cb: () => void) => {
      if (!f) return () => {}
      f.listeners.add(cb)
      return () => {
        f.listeners.delete(cb)
      }
    },
    [f],
  )
  const snap = useSyncExternalStore(subscribe, () => f?.snapshot ?? EMPTY)
  useEffect(() => (topic ? join(topic) : undefined), [topic])
  return snap
}

const EMPTY = { events: [] as TopicEvent[], state: 'live' as StreamState }
