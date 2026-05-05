import Link from "next/link";
import { DocsPage, DocsBody, DocsTitle, DocsDescription } from "fumadocs-ui/page";
import { Button } from "@lexicon/design-system";

export default function DocsNotFound() {
  return (
    <DocsPage toc={[]}>
      <DocsTitle>Page not found</DocsTitle>
      <DocsDescription>
        That page doesn&apos;t exist — or the URL may have moved.
      </DocsDescription>
      <DocsBody>
        <p>
          Try the <Link href="/docs">introduction</Link> or browse the
          sidebar for records, queries, procedures, and shared definitions.
        </p>
        <div className="mt-6 flex gap-3">
          <Link href="/docs">
            <Button>Open the docs</Button>
          </Link>
          <Link href="/docs/reference/records/games.gamesgamesgamesgames.game">
            <Button variant="secondary">Browse reference</Button>
          </Link>
        </div>
      </DocsBody>
    </DocsPage>
  );
}
