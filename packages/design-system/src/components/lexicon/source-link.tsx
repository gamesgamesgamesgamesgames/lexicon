interface SourceLinkProps {
  path: string;
  repoUrl?: string;
}

export function SourceLink({ path, repoUrl = "https://github.com/gamesgamesgamesgamesgames/lexicon/blob/main" }: SourceLinkProps) {
  return (
    <div className="mt-12 border-t border-border pt-4 text-xs text-fg-subtle">
      Source: <a href={`${repoUrl}/${path}`} className="font-mono text-fg-muted underline decoration-fg/20 underline-offset-[3px] hover:text-fg hover:decoration-fg">{path}</a>
    </div>
  );
}
