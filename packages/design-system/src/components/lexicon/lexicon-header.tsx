import { TypeBadge } from "./type-badge";

interface LexiconHeaderProps {
  id: string;
  type: string;
  method?: "GET" | "POST";
}

export function LexiconHeader({ id, type, method }: LexiconHeaderProps) {
  return (
    <div className="not-prose mb-6 flex flex-wrap items-center gap-2">
      <TypeBadge type={type} />
      {method && (
        <span className="inline-flex items-center rounded-sm border border-border bg-bg-subtle/60 px-2 py-0.5 text-[0.7rem] font-mono uppercase tracking-wider text-fg-muted">
          {method}
        </span>
      )}
      <code className="font-mono text-xs text-fg-subtle">{id}</code>
    </div>
  );
}
