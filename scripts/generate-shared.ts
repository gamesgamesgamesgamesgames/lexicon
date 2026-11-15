#!/usr/bin/env bun
/**
 * Inlines every src/shared/*.lua into the handlers that mark a slot for it.
 *
 * A handler opts in by writing the marker pair and leaving the body to the
 * generator:
 *
 *   -- >>> generated from src/shared/game_changes.lua — do not edit
 *   -- <<< generated from src/shared/game_changes.lua
 *
 * With `--check` nothing is written: the command fails if any checked-in
 * handler differs from what generation would produce, which is what CI runs.
 */

import { readdir, readFile, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { join, relative } from 'node:path'

const ROOT = fileURLToPath(new URL('..', import.meta.url))
const SHARED_DIR = join(ROOT, 'src/shared')
const TARGET_DIRS = ['src/scripts', 'src/jobs']

const begin = (name: string) =>
	`-- >>> generated from src/shared/${name} — do not edit`
const end = (name: string) => `-- <<< generated from src/shared/${name}`

// Any begin marker at all, so a slot naming a source that no longer exists is
// an error rather than a block nothing ever regenerates again.
const ANY_BEGIN = /-- >>> generated from src\/shared\/(\S+)/g

const sources = new Map<string, string>()
for (const entry of (await readdir(SHARED_DIR)).sort()) {
	if (entry.endsWith('.lua')) {
		sources.set(entry, await readFile(join(SHARED_DIR, entry), 'utf8'))
	}
}

const targets: string[] = []
for (const dir of TARGET_DIRS) {
	for (const entry of await readdir(join(ROOT, dir), { recursive: true })) {
		if (entry.endsWith('.lua')) {
			targets.push(join(ROOT, dir, entry))
		}
	}
}
targets.sort()

const isCheck = process.argv.includes('--check')
const stale: string[] = []
let written = 0

for (const target of targets) {
	const original = await readFile(target, 'utf8')
	let next = original
	const where = relative(ROOT, target)

	for (const [, name] of original.matchAll(ANY_BEGIN)) {
		if (!sources.has(name)) {
			throw new Error(
				`${where}: generated block names src/shared/${name}, which does not exist`,
			)
		}
	}

	// A handler whose body is CRLF keeps CRLF inside the block too, so that
	// generating does not leave the file with mixed endings and `--check`
	// comparing against endings no editor would produce.
	const newline = next.includes('\r\n') ? '\r\n' : '\n'

	for (const [name, source] of sources) {
		const beginMarker = begin(name)
		const endMarker = end(name)

		if (!next.includes(beginMarker)) {
			if (next.includes(endMarker)) {
				throw new Error(`${where}: end marker for ${name} with no begin marker`)
			}
			continue
		}

		const body = [
			beginMarker,
			...source.trimEnd().split(/\r?\n/),
			endMarker,
		].join(newline)

		// A file may open more than one slot for the same source. Walking from a
		// cursor fills all of them; stopping at the first would leave the rest
		// stale forever, and `--check` would call that clean.
		let cursor = 0
		while (true) {
			const beginIndex = next.indexOf(beginMarker, cursor)
			if (beginIndex === -1) {
				break
			}

			const endIndex = next.indexOf(endMarker, beginIndex)
			if (endIndex === -1) {
				throw new Error(`${where}: begin marker for ${name} with no end marker`)
			}

			// A begin marker inside the slot it is meant to close means the pair is
			// crossed or nested; splicing would silently eat the inner one.
			const nested = next.indexOf(beginMarker, beginIndex + beginMarker.length)
			if (nested !== -1 && nested < endIndex) {
				throw new Error(`${where}: nested begin markers for ${name}`)
			}

			next =
				next.slice(0, beginIndex) + body + next.slice(endIndex + endMarker.length)
			cursor = beginIndex + body.length
		}
	}

	if (next === original) {
		continue
	}

	if (isCheck) {
		stale.push(where)
	} else {
		await writeFile(target, next)
		written += 1
	}
}

if (isCheck) {
	if (stale.length > 0) {
		console.error(
			'These handlers no longer match src/shared/. Run `bun run generate:shared` and commit the result:',
		)
		for (const path of stale) {
			console.error(`  ${path}`)
		}
		process.exit(1)
	}
	console.log(`check:shared — ${targets.length} handlers up to date`)
} else {
	console.log(`generate:shared — updated ${written} of ${targets.length} handlers`)
}
