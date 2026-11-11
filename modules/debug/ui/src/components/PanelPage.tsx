import { useEffect, useState } from 'react'
import { useParams } from 'react-router'
import type { Manifest } from '@/lib/types'
import { since } from '@/lib/format'
import { ViewSection } from './ViewSection'

export function PanelPage({ manifest, readAt }: { manifest: Manifest; readAt: number }) {
  const { panel: name } = useParams()
  const now = useNow(30000)
  const up = manifest.app.uptime + Math.max(0, Math.floor((now - readAt) / 1000))
  const panel = manifest.panels.find((p) => p.name === name)
  if (!panel) {
    return <p className="text-muted">There is no panel called {name}.</p>
  }
  // a view another one opens in its rows' sheet lives only there
  const details = new Set(panel.views.map((v) => v.detail).filter(Boolean))
  return (
    <div className="mx-auto flex max-w-[1400px] flex-col gap-10">
      <header>
        <h1 className="text-[26px] font-semibold leading-tight">{panel.title}</h1>
        <p className="mt-1 text-[14px] text-muted">
          {manifest.app.mode} mode · up {since(up)} · console at {manifest.base}/
        </p>
      </header>
      {panel.views.filter((v) => !details.has(v.name)).map((v) => (
        <ViewSection key={v.name} panel={panel} view={v} />
      ))}
    </div>
  )
}

/**
 * The time now, read again every `every` milliseconds.
 */
function useNow(every: number): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), every)
    return () => clearInterval(id)
  }, [every])
  return now
}
