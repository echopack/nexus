import * as React from 'react'
import * as Dialog from '@radix-ui/react-dialog'
import { X } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Button } from './button'

export const Sheet = Dialog.Root

export function SheetContent({ className, children, title, ...props }: React.ComponentProps<typeof Dialog.Content> & { title: string }) {
  return (
    <Dialog.Portal>
      <Dialog.Overlay className="fixed inset-0 z-40 bg-black/50" />
      <Dialog.Content
        className={cn(
          'fixed inset-y-0 right-0 z-50 flex w-full max-w-[640px] flex-col border-l border-border bg-surface shadow-[var(--shadow)] outline-none',
          className,
        )}
        {...props}
      >
        <div className="flex h-12 flex-none items-center justify-between gap-3 border-b border-rule px-6">
          <Dialog.Title className="truncate text-[15px] font-semibold">{title}</Dialog.Title>
          <Dialog.Close className="rounded-full p-1.5 text-muted hover:bg-raised hover:text-ink" aria-label="Close">
            <X className="size-4" />
          </Dialog.Close>
        </div>
        <Dialog.Description className="sr-only">{title}</Dialog.Description>
        <div className="min-h-0 flex-1 overflow-auto px-6 py-5">{children}</div>
      </Dialog.Content>
    </Dialog.Portal>
  )
}

export function Confirm({
  open,
  onOpenChange,
  title,
  body,
  action,
  destructive,
  onConfirm,
}: {
  open: boolean
  onOpenChange: (o: boolean) => void
  title: string
  body: string
  action: string
  destructive?: boolean
  onConfirm: () => void
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/50" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-50 w-[min(420px,calc(100vw-32px))] -translate-x-1/2 -translate-y-1/2 rounded-md border border-border bg-raised p-6 shadow-[var(--shadow)] outline-none">
          <Dialog.Title className="text-[15px] font-semibold">{title}</Dialog.Title>
          <Dialog.Description className="mt-2 text-[13px] text-muted">{body}</Dialog.Description>
          <div className="mt-6 flex justify-end gap-2">
            <Dialog.Close asChild>
              <Button variant="outline" className="font-normal hover:bg-surface">
                Keep it
              </Button>
            </Dialog.Close>
            <Button
              variant={destructive ? 'danger' : 'default'}
              onClick={() => {
                onConfirm()
                onOpenChange(false)
              }}
            >
              {action}
            </Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
