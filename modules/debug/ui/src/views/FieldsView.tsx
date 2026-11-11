import type { Row } from '@/lib/types'
import { asText } from '@/lib/format'
import { Frame } from '@/components/ViewSection'

interface Field {
  label: string
  value: unknown
}

export function FieldsView({ data }: { data: Row }) {
  const fields = (data.fields as Field[] | undefined) ?? []
  return (
    <Frame className="py-2">
      <dl className="divide-y divide-rule">
        {fields.map((f, i) => (
          <div key={i} className="grid grid-cols-1 gap-1 py-2.5 md:grid-cols-[200px_1fr] md:gap-4">
            <dt className="text-muted">{f.label}</dt>
            <dd className="min-w-0">
              {Array.isArray(f.value) ? (
                <span className="flex flex-wrap gap-1.5">
                  {f.value.map((v, j) => (
                    <span key={j} className="rounded bg-raised px-1.5 py-0.5 font-mono text-xs">
                      {String(v)}
                    </span>
                  ))}
                </span>
              ) : (
                <span className="break-words">{asText(f.value)}</span>
              )}
            </dd>
          </div>
        ))}
      </dl>
    </Frame>
  )
}
