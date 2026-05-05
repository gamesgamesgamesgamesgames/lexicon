import type { AnchorHTMLAttributes, ReactNode } from "react";

interface LinkProps extends AnchorHTMLAttributes<HTMLAnchorElement> {
  children: ReactNode;
}

export function Link({ className = "", children, ...rest }: LinkProps) {
  return (
    <a
      className={`text-fg underline decoration-fg/30 underline-offset-[3px] hover:decoration-fg ${className}`}
      {...rest}
    >
      {children}
    </a>
  );
}
