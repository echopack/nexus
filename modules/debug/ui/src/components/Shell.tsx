import { NavLink } from 'react-router'
import { LogOut } from 'lucide-react'
import type { Manifest } from '@/lib/types'
import { token } from '@/lib/api'
import { Badge } from '@/components/ui/badge'
import { Mark } from './Mark'
import { cn } from '@/lib/utils'

export function Shell({ manifest, onSignOut, children }: { manifest: Manifest; onSignOut: () => void; children: React.ReactNode }) {
  const prod = manifest.app.mode === 'prod'
  return (
    <div className="flex min-h-full flex-col md:flex-row">
      <aside className="flex flex-none flex-col border-border bg-ground md:sticky md:top-0 md:h-screen md:w-[224px] md:border-r">
        <div className="flex h-14 items-center gap-2.5 px-5">
          <Mark />
          <div className="min-w-0">
            <div className="text-[15px] font-semibold leading-tight">nexus</div>
            <div className="text-xs leading-tight text-muted">debug console</div>
          </div>
          <Badge tone={prod ? 'warning' : 'neutral'} className="ml-auto">
            {manifest.app.mode}
          </Badge>
        </div>
        <nav aria-label="Panels" className="flex gap-1 overflow-x-auto px-3 pb-2 md:mt-4 md:flex-col md:gap-0 md:overflow-visible md:pb-0">
          {manifest.panels.map((p) => (
            <NavLink
              key={p.name}
              to={`/${p.name}`}
              className={({ isActive }) =>
                cn('flex h-8 flex-none items-center rounded px-2 text-[14px] text-muted hover:text-ink', isActive && 'text-ink')
              }
            >
              {({ isActive }) => <span className={cn(isActive && 'marked')}>{p.title}</span>}
            </NavLink>
          ))}
        </nav>
        <div className="mt-auto hidden items-center gap-2 border-t border-rule px-5 py-4 md:flex">
          <div className="min-w-0 flex-1">
            <div className="truncate text-[13px]">{manifest.viewer.subject}</div>
            <div className="truncate text-xs text-muted">signed in by {manifest.viewer.via}</div>
          </div>
          {token() && (
            <button onClick={onSignOut} className="rounded-full p-1.5 text-muted hover:bg-raised hover:text-ink" aria-label="Sign out" title="Sign out">
              <LogOut className="size-4" />
            </button>
          )}
        </div>
      </aside>
      <main className="min-w-0 flex-1 px-4 pb-16 pt-6 md:px-8 md:pt-8">{children}</main>
    </div>
  )
}
