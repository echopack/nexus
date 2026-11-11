// the shapes of the console's API, as nexus-debug writes them

export type ViewKind = 'stats' | 'table' | 'fields' | 'log' | 'json' | 'graph' | 'timeline'

export interface Column {
  key: string
  title: string
  format: 'text' | 'number' | 'ms' | 'time' | 'status' | 'level' | 'code' | 'json'
  link?: string
}

export interface ActionSpec {
  name: string
  title: string
  row: boolean
  confirm: boolean
  destructive: boolean
  when?: string
}

export interface View {
  name: string
  title: string
  kind: ViewKind
  url: string
  topic?: string
  columns?: Column[]
  actions?: ActionSpec[]
  refresh?: number
  filters?: string[]
  /** a view of the same panel a row opens in its sheet, filled from the row's fields */
  detail?: string
}

export interface Panel {
  name: string
  title: string
  views: View[]
}

export interface Topic {
  name: string
  title: string
  last: number
  poll: string
  stream: string
}

export type SignIn =
  | { kind: 'token'; hint?: string }
  | { kind: 'open' }
  | { kind: 'login'; endpoint: string; fields: { name: string; label: string; type: string }[]; token: string; session?: string }

export interface Manifest {
  name: string
  base: string
  api: string
  viewer: { via: string; subject: string }
  signIn: SignIn
  app: { mode: string; started: string; uptime: number }
  panels: Panel[]
  topics: Topic[]
}

export interface TopicEvent {
  seq: number
  at: string
  data: Row
}

export type Row = Record<string, unknown>

export type MarkKind = 'middleware' | 'action' | 'span' | 'query' | 'cache' | 'mail'

/** one timed stretch of a request, times in ms from its start */
export interface Mark {
  id: number
  parent: number
  kind: MarkKind
  name: string
  detail: string
  note: string
  start: number
  ms: number
  failed: boolean
}

export interface Timeline {
  began: string
  total: number
  dropped: number
  marks: Mark[]
}
