// talks to the console's API under the base the server wrote into index.html, with the bearer
// token or the signed session kept for this tab

import type { Row, View } from './types'
import { missing } from './format'

const meta = document.querySelector<HTMLMetaElement>('meta[name="nexus-base"]')
export const base = (meta?.content ?? '/__nexus').replace(/\/+$/, '')
export const apiBase = `${base}/api`

const KEY = 'nexus-debug-token'
const SESSION = 'nexus-debug-session'

export interface Session {
  id: string
  secret: string
}

export function token(): string {
  try {
    return sessionStorage.getItem(KEY) ?? ''
  } catch {
    return ''
  }
}

export function keep(value: string): void {
  try {
    if (value) sessionStorage.setItem(KEY, value)
    else sessionStorage.removeItem(KEY)
    sessionStorage.removeItem(SESSION)
  } catch {
    // a tab without storage signs in again on reload
  }
}

export function session(): Session | null {
  try {
    const kept = sessionStorage.getItem(SESSION)
    return kept ? (JSON.parse(kept) as Session) : null
  } catch {
    return null
  }
}

export function keepSession(value: Session): void {
  try {
    sessionStorage.removeItem(KEY)
    sessionStorage.setItem(SESSION, JSON.stringify(value))
  } catch {
    // a tab without storage signs in again on reload
  }
}

export class ApiError extends Error {
  constructor(
    public status: number,
    public title: string,
    public detail: string,
  ) {
    super(detail || title)
  }
}

const utf8 = (text: string) => new TextEncoder().encode(text)
const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('')

/**
 * The `Authorization: Nexus-Sig` value of a request signed with session `s`: the method, the target
 * as sent, the unix time and the body's sha256, one per line, under the session's secret.
 */
export async function sign(s: Session, method: string, target: string, body: string): Promise<string> {
  const ts = Math.floor(Date.now() / 1000)
  const digest = hex(await crypto.subtle.digest('SHA-256', utf8(body)))
  const key = await crypto.subtle.importKey('raw', utf8(s.secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = hex(await crypto.subtle.sign('HMAC', key, utf8(`${method}\n${target}\n${ts}\n${digest}`)))
  return `Nexus-Sig id=${s.id},ts=${ts},sig=${sig}`
}

/**
 * The headers of a request to `target`: signed with the kept session, else the kept bearer token.
 */
export async function headers(method: string, target: string, body = '', extra: Record<string, string> = {}): Promise<Record<string, string>> {
  const h: Record<string, string> = { Accept: 'application/json', ...extra }
  const s = session()
  if (s) {
    h.Authorization = await sign(s, method, target, body)
    return h
  }
  const t = token()
  if (t) h.Authorization = `Bearer ${t}`
  return h
}

async function fail(res: Response): Promise<never> {
  let title = res.statusText
  let detail = ''
  try {
    const p = await res.json()
    title = p.title ?? title
    detail = p.detail ?? ''
  } catch {
    // not a problem document
  }
  throw new ApiError(res.status, title, detail)
}

function url(path: string): string {
  return path.startsWith('/') ? path : `${apiBase}/${path}`
}

export async function get<T>(path: string): Promise<T> {
  const target = url(path)
  const res = await fetch(target, { headers: await headers('GET', target) })
  if (!res.ok) return fail(res)
  return res.json()
}

/**
 * The query string a view is read with: each of its filters that has a value in `values`.
 */
export function viewQuery(view: View, values: Record<string, unknown>): string {
  const set = (view.filters ?? []).filter((f) => !missing(values[f]))
  return new URLSearchParams(set.map((f) => [f, String(values[f])])).toString()
}

// a view read with its query string
export function readView(view: View, query: string): Promise<Row> {
  return get<Row>(`${view.url}${query ? `?${query}` : ''}`)
}

export async function post<T>(path: string, body: unknown): Promise<T> {
  const target = url(path)
  const text = JSON.stringify(body ?? {})
  const res = await fetch(target, {
    method: 'POST',
    headers: await headers('POST', target, text, { 'Content-Type': 'application/json' }),
    body: text,
  })
  if (!res.ok) return fail(res)
  return res.json()
}

/**
 * Posts the app's own sign in form and takes the token from the answer at `path` (dots for nested
 * keys).
 */
export async function login(endpoint: string, fields: Record<string, string>, path: string): Promise<string> {
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify(fields),
  })
  if (!res.ok) return fail(res)
  const doc = await res.json()
  const found = path.split('.').reduce<unknown>((at, k) => (at && typeof at === 'object' ? (at as Record<string, unknown>)[k] : undefined), doc)
  if (typeof found !== 'string' || !found) throw new ApiError(500, 'No token', `the sign in answered no token at "${path}"`)
  return found
}

/**
 * Opens a signed session at `opens`, then posts the app's own sign in form to `endpoint` signed with
 * it, and answers the session, now with the user on it.
 */
export async function loginSession(opens: string, endpoint: string, fields: Record<string, string>): Promise<Session> {
  const opened = await fetch(opens, { method: 'POST', headers: { Accept: 'application/json' } })
  if (!opened.ok) return fail(opened)
  const { id, secret } = (await opened.json()) as Session
  const s = { id, secret }
  const text = JSON.stringify(fields)
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json', Authorization: await sign(s, 'POST', endpoint, text) },
    body: text,
  })
  if (!res.ok) return fail(res)
  return s
}
