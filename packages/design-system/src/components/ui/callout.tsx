import type { ReactNode } from "react";

type Kind = "note" | "warn" | "danger";

interface CalloutProps {
  kind?: Kind;
  title?: string;
  children: ReactNode;
}

const kindClasses: Record<Kind, string> = {
  note: "border-border bg-bg-subtle",
  warn: "border-amber-500/40 bg-amber-500/10",
  danger: "border-red-500/40 bg-red-500/10",
};

export function Callout({ kind = "note", title, children }: CalloutProps) {
  return (
    <aside className={`my-6 rounded-md border p-4 ${kindClasses[kind]}`}>
      {title && <div className="mb-1 text-sm font-semibold text-fg">{title}</div>}
      <div className="text-sm text-fg-muted">{children}</div>
    </aside>
  );
}
