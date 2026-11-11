import type { Row } from '@/lib/types'
import { Frame } from '@/components/ViewSection'

export function JsonView({ data }: { data: Row }) {
  return (
    <Frame>
      <pre className="overflow-auto font-mono text-xs leading-relaxed">{JSON.stringify(data, null, 2)}</pre>
    </Frame>
  )
}
