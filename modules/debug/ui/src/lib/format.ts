import type { Column } from './types'

// how a cell reads: numbers grouped, times local, durations with their unit, a dash for nothing

const grouped = new Intl.NumberFormat('en-US')

export function missing(v: unknown): boolean {
  return v === undefined || v === null || v === ''
}

export function number(v: unknown): string {
  return typeof v === 'number' ? grouped.format(v) : String(v)
}

export function ms(v: unknown): string {
  if (typeof v !== 'number') return String(v)
  if (v >= 1000) return `${(v / 1000).toFixed(2)} s`
  if (v >= 100) return `${v.toFixed(0)} ms`
  if (v >= 10) return `${v.toFixed(1)} ms`
  return `${v.toFixed(2)} ms`
}

export function time(v: unknown): string {
  if (typeof v !== 'string') return String(v)
  const d = new Date(v)
  if (Number.isNaN(d.getTime())) return v
  const today = new Date()
  const clock = d.toLocaleTimeString('en-GB', { hour12: false })
  if (d.toDateString() === today.toDateString()) return `${clock}.${String(d.getMilliseconds()).padStart(3, '0')}`
  return `${d.toISOString().slice(0, 10)} ${clock}`
}

export function since(seconds: number): string {
  const d = Math.floor(seconds / 86400)
  const h = Math.floor((seconds % 86400) / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${m}m`
  if (m > 0) return `${m}m ${seconds % 60}s`
  return `${seconds}s`
}

// a value as it reads plainly: objects (null too) as JSON, the rest as their string
export function asText(v: unknown): string {
  return typeof v === 'object' ? JSON.stringify(v) : String(v)
}

export function text(v: unknown, format: Column['format']): string {
  if (missing(v)) return '—'
  switch (format) {
    case 'number':
      return number(v)
    case 'ms':
      return ms(v)
    case 'time':
      return time(v)
    case 'json':
      return JSON.stringify(v)
    default:
      return asText(v)
  }
}

/**
 * What a status says: good, bad, waiting or plain, for an HTTP status or a task's state.
 */
export function tone(v: unknown): 'positive' | 'negative' | 'warning' | 'neutral' {
  if (typeof v === 'number') {
    if (v >= 500) return 'negative'
    if (v >= 400) return 'warning'
    return 'neutral'
  }
  switch (String(v)) {
    case 'done':
      return 'positive'
    case 'failed':
    case 'expired':
    case 'blocked':
    case 'error':
      return 'negative'
    case 'retry':
    case 'warn':
    case 'running':
    case 'started':
      return 'warning'
    default:
      return 'neutral'
  }
}

export function numeric(format: Column['format']): boolean {
  return format === 'number' || format === 'ms'
}
