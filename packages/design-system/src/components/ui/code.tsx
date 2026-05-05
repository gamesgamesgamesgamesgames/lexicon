import type { HTMLAttributes, ReactNode } from "react";

interface CodeProps extends HTMLAttributes<HTMLElement> {
  children: ReactNode;
}

export function Code({ className = "", children, ...rest }: CodeProps) {
  return (
    <code
      className={`rounded-sm border border-border bg-code-bg text-code-fg px-1.5 py-0.5 text-[0.9em] font-mono ${className}`}
      {...rest}
    >
      {children}
    </code>
  );
}
