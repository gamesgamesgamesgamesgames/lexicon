import Link from "next/link";

const GITHUB_URL = "https://github.com/gamesgamesgamesgamesgames/lexicon";

export function Footer() {
	return (
		<footer className="mx-auto flex w-full max-w-6xl items-center justify-between px-6 py-10 text-xs text-fg-subtle">
			<span className="font-mono">
				The Pentaract · games.gamesgamesgamesgames.*
			</span>
			<div className="flex items-center gap-4">
				<Link href="/docs" className="hover:text-fg">
					Docs
				</Link>
				<a href={GITHUB_URL} className="hover:text-fg">
					GitHub
				</a>
			</div>
		</footer>
	);
}
