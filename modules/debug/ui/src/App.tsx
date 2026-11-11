import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Navigate, Route, Routes } from 'react-router'
import { ApiError, apiBase, get, keep } from '@/lib/api'
import type { Manifest, SignIn as SignInSpec } from '@/lib/types'
import { Shell } from '@/components/Shell'
import { PanelPage } from '@/components/PanelPage'
import { SignIn } from '@/components/SignIn'
import { Mark } from '@/components/Mark'

export function App() {
  const client = useQueryClient()
  // panels and topics are fixed once the app booted, so the manifest is read on sign in and focus
  // only; the uptime ticks on from when it was read
  const manifest = useQuery({
    queryKey: ['manifest'],
    queryFn: () => get<Manifest>(apiBase),
  })
  const unauthorized = manifest.error instanceof ApiError && manifest.error.status === 401
  const forbidden = manifest.error instanceof ApiError && manifest.error.status === 403
  const signIn = useQuery({
    queryKey: ['sign-in'],
    queryFn: () => get<SignInSpec>('sign-in'),
    enabled: unauthorized || forbidden,
  })

  const signedIn = () => client.invalidateQueries({ queryKey: ['manifest'] })
  const signOut = () => {
    keep('')
    client.clear()
    client.invalidateQueries({ queryKey: ['manifest'] })
  }

  if (manifest.isPending) {
    return <Centered>Reaching the app…</Centered>
  }
  if (unauthorized || forbidden) {
    if (!signIn.data) return <Centered>{signIn.isError ? 'The app does not say how to sign in.' : 'Asking the app how to sign in…'}</Centered>
    return <SignIn spec={signIn.data} refused={forbidden ? (manifest.error as ApiError).detail || 'This account may not open the console.' : ''} onSignedIn={signedIn} onSignOut={signOut} />
  }
  if (manifest.isError || !manifest.data) {
    return (
      <Centered>
        <span className="text-negative">The app did not answer: {(manifest.error as Error)?.message}</span>
      </Centered>
    )
  }
  const m = manifest.data
  return (
    <Shell manifest={m} onSignOut={signOut}>
      <Routes>
        <Route index element={<Navigate to={`/${m.panels[0]?.name ?? ''}`} replace />} />
        <Route path=":panel" element={<PanelPage manifest={m} readAt={manifest.dataUpdatedAt} />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Shell>
  )
}

function Centered({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-4 text-muted">
      <Mark />
      <p>{children}</p>
    </div>
  )
}
