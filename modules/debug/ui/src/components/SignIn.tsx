import { useState } from 'react'
import type { SignIn as Spec } from '@/lib/types'
import { keep, keepSession, login, loginSession } from '@/lib/api'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Mark } from './Mark'

export function SignIn({ spec, refused, onSignedIn, onSignOut }: { spec: Spec; refused: string; onSignedIn: () => void; onSignOut: () => void }) {
  const [values, setValues] = useState<Record<string, string>>({})
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    setError('')
    setBusy(true)
    try {
      if (spec.kind === 'login' && spec.session) {
        keepSession(await loginSession(spec.session, spec.endpoint, values))
      } else if (spec.kind === 'login') {
        keep(await login(spec.endpoint, values, spec.token))
      } else {
        keep((values.token ?? '').trim())
      }
      onSignedIn()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="flex min-h-full items-center justify-center px-4">
      <form onSubmit={submit} className="w-full max-w-[360px]">
        <div className="mb-8 flex items-center gap-3">
          <Mark size={36} />
          <div>
            <h1 className="text-[20px] font-semibold leading-tight">nexus debug console</h1>
            <p className="text-muted">
              {spec.kind === 'login' ? 'Sign in with your account on this app.' : 'Paste the token that opens this console.'}
            </p>
          </div>
        </div>
        {refused && (
          <div className="mb-4 flex items-center justify-between gap-3 rounded-md bg-pill-negative-bg px-3 py-2 text-pill-negative-ink">
            <span>{refused}</span>
            <button type="button" className="underline" onClick={onSignOut}>
              Sign out
            </button>
          </div>
        )}
        <div className="flex flex-col gap-4">
          {spec.kind === 'login' ? (
            spec.fields.map((f) => (
              <label key={f.name} className="flex flex-col gap-1.5">
                <span className="text-xs text-muted">{f.label}</span>
                <Input
                  type={f.type}
                  autoComplete={f.type === 'password' ? 'current-password' : f.type === 'email' ? 'username' : undefined}
                  value={values[f.name] ?? ''}
                  onChange={(e) => setValues({ ...values, [f.name]: e.target.value })}
                  required
                />
              </label>
            ))
          ) : (
            <label className="flex flex-col gap-1.5">
              <span className="text-xs text-muted">{spec.kind === 'token' && spec.hint ? `Token: ${spec.hint}` : 'Token (NEXUS_DEBUG_TOKEN)'}</span>
              <Input
                type="password"
                autoComplete="off"
                className="font-mono"
                value={values.token ?? ''}
                onChange={(e) => setValues({ token: e.target.value })}
                required
              />
            </label>
          )}
          {error && <p className="text-negative">{error}</p>}
          <Button type="submit" disabled={busy} className="mt-2 self-start">
            {busy ? 'Signing in…' : 'Open the console'}
          </Button>
        </div>
      </form>
    </div>
  )
}
