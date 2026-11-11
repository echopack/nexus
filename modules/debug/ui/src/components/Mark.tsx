// the console's mark: three nodes joined, the nexus of a request, its log and its jobs

export function Mark({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 28 28" aria-hidden="true">
      <path d="M8 19 L14 8 L20 19 Z" fill="none" stroke="var(--accent)" strokeWidth="1.5" strokeLinejoin="round" />
      <circle cx="14" cy="8" r="3" fill="var(--text)" />
      <circle cx="8" cy="19" r="3" fill="var(--accent)" />
      <circle cx="20" cy="19" r="3" fill="var(--text)" />
    </svg>
  )
}
