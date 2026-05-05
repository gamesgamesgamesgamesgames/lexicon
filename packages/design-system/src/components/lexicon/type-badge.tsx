import type { ReactNode } from "react";

type LexiconType = "record" | "query" | "procedure" | "subscription" | "token" | "object" | "ref" | "string" | "integer" | "boolean" | "array" | "blob" | "bytes" | "cid-link" | "unknown";

interface TypeBadgeProps {
  type: LexiconType | string;
  children?: ReactNode;
}

const baseClasses = "bg-bg-subtle/60 text-fg-muted border-border";
const emphasisByType: Record<string, string> = {
  record: "bg-bg-subtle text-fg border-border-strong",
  query: "bg-bg-subtle text-fg border-border-strong",
  procedure: "bg-bg-subtle text-fg border-border-strong",
  subscription: "bg-bg-subtle text-fg border-border-strong",
  token: "bg-bg-subtle text-fg border-border-strong",
};

export function TypeBadge({ type, children }: TypeBadgeProps) {
  const classes = emphasisByType[type] ?? baseClasses;
  return (
    <span className={`inline-flex items-center rounded-sm border px-2 py-0.5 text-[0.7rem] font-mono uppercase tracking-wider ${classes}`}>
      {children ?? type}
    </span>
  );
}
