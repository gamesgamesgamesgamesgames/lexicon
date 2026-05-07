import Image from "next/image";
import Link from "next/link";
import { Button } from "@lexicon/design-system";
import { highlight } from "fumadocs-core/server";

export default async function HomePage() {
	return (
		<>
			<Hero />
			<CodeShowcase />
		</>
	);
}

function Hero() {
	return (
		<section className="relative overflow-hidden border-b border-border/60">
			<div className="absolute inset-0 bg-grid mask-fade-b" aria-hidden />
			<div className="absolute inset-0 hero-glow" aria-hidden />
			<div className="relative mx-auto flex max-w-5xl flex-col items-center gap-10 px-6 py-28 md:flex-row md:items-center md:gap-14 md:text-left">
				<Image
					src="/pentaract-logo.png"
					alt="The Pentaract"
					width={512}
					height={512}
					className="h-64 w-64 shrink-0 md:h-80 md:w-80"
					priority
				/>
				<div className="flex flex-col items-center gap-6 text-center md:items-start md:text-left">
					<span className="inline-flex items-center gap-2 rounded-full border border-border bg-bg-subtle/60 px-3 py-1 font-mono text-xs text-fg-muted">
						<span className="h-1.5 w-1.5 rounded-full bg-fg/70" />
						v1 · games.gamesgamesgamesgames.*
					</span>
					<h1 className="font-[family-name:var(--font-dragonsteel)] text-5xl tracking-tight text-fg sm:text-6xl md:text-7xl">
						The Pentaract
					</h1>
					<p className="max-w-2xl text-lg text-fg-muted">
						The AppView for the{" "}
						<code className="rounded border border-border bg-code-bg px-1.5 py-0.5 text-sm">
							games.gamesgamesgamesgames.*
						</code>{" "}
						AT Protocol lexicons. A unified namespace for storing games,
						contributions, reviews, and feeds in user-owned repositories. Build
						once, read anywhere.
					</p>
					<div className="flex items-center gap-3">
						<Link href="/docs">
							<Button>Open the docs →</Button>
						</Link>
						<Link href="/docs/reference/records/games.gamesgamesgamesgames.game">
							<Button variant="secondary">Browse reference</Button>
						</Link>
					</div>
				</div>
			</div>
		</section>
	);
}

const codeExample = `import { Agent } from "@atproto/api";

const agent = new Agent({ service: "https://bsky.social" });

const { data } = await agent.com.atproto.repo.getRecord({
  repo: "did:web:gamesgamesgamesgames.games",
  collection: "games.gamesgamesgamesgames.game",
  rkey: "3mghf7hlkf52d",
});

console.log(data.value);
// { $type: "games.gamesgamesgamesgames.game",
//   name: "Tunic",
//   releasedAt: "2022-03-16",
//   genres: ["action", "puzzle"], ... }`;

async function CodeShowcase() {
	const highlighted = await highlight(codeExample, {
		lang: "ts",
		theme: "github-dark",
	});

	return (
		<section className="border-b border-border/60">
			<div className="mx-auto max-w-4xl px-6 py-20">
				<div className="mb-6 text-center">
					<h2 className="font-mono text-2xl tracking-tight text-fg">
						Read a game from any user&apos;s repo
					</h2>
					<p className="mt-2 text-sm text-fg-muted">
						Every record is a typed, signed entry in the author&apos;s ATProto
						PDS.
					</p>
				</div>
				<div className="surface-card overflow-hidden">
					<div className="flex items-center justify-between border-b border-border px-4 py-2.5">
						<div className="flex items-center gap-2">
							<span className="h-2.5 w-2.5 rounded-full bg-border-strong" />
							<span className="h-2.5 w-2.5 rounded-full bg-border-strong" />
							<span className="h-2.5 w-2.5 rounded-full bg-border-strong" />
						</div>
						<span className="font-mono text-xs text-fg-subtle">
							read-game.ts
						</span>
						<span className="font-mono text-xs text-fg-subtle">TS</span>
					</div>
					<div className="overflow-x-auto bg-code-bg px-5 py-5 font-mono text-[13px] leading-relaxed [&_pre]:!bg-transparent [&_code]:!bg-transparent">
						{highlighted}
					</div>
				</div>
			</div>
		</section>
	);
}
