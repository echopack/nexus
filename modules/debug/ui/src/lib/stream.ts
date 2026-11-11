import { apiBase, headers } from './api'
import type { TopicEvent } from './types'

// follows a topic as server-sent events over fetch, so the token or the session signature goes along, and picks up
// after the last event it saw when the connection drops

export type StreamState = 'connecting' | 'live' | 'retrying'

export function follow(
  topic: string,
  after: number,
  onEvent: (e: TopicEvent) => void,
  onState: (s: StreamState) => void,
): () => void {
  const stop = new AbortController()
  let cursor = after

  async function once(): Promise<void> {
    onState('connecting')
    const target = `${apiBase}/topics/${encodeURIComponent(topic)}/stream?after=${cursor}`
    const res = await fetch(target, {
      headers: await headers('GET', target, '', { Accept: 'text/event-stream' }),
      signal: stop.signal,
    })
    if (!res.ok || !res.body) throw new Error(`stream ${res.status}`)
    onState('live')
    const reader = res.body.pipeThrough(new TextDecoderStream()).getReader()
    let buf = ''
    for (;;) {
      const { value, done } = await reader.read()
      if (done) return
      buf += value
      let cut = buf.indexOf('\n\n')
      while (cut >= 0) {
        const block = buf.slice(0, cut)
        buf = buf.slice(cut + 2)
        const data = block
          .split('\n')
          .filter((l) => l.startsWith('data: '))
          .map((l) => l.slice(6))
          .join('\n')
        if (data) {
          const e = JSON.parse(data) as TopicEvent
          cursor = e.seq
          onEvent(e)
        }
        cut = buf.indexOf('\n\n')
      }
    }
  }

  ;(async () => {
    let wait = 1000
    while (!stop.signal.aborted) {
      try {
        await once()
        wait = 1000
      } catch {
        if (stop.signal.aborted) return
      }
      if (stop.signal.aborted) return
      onState('retrying')
      await new Promise((r) => setTimeout(r, wait))
      wait = Math.min(wait * 2, 15000)
    }
  })()

  return () => stop.abort()
}
