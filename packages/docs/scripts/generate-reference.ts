#!/usr/bin/env bun
import { readdirSync, mkdirSync, writeFileSync, rmSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseLexiconFile } from "./parse-lexicon";
import { renderRecordMdx } from "./render-record";
import { renderQueryMdx } from "./render-query";
import { renderProcedureMdx } from "./render-procedure";
import { renderSharedDefsMdx } from "./render-defs";
import type { RefIndex } from "./extract-fields";
import { getMainType, type LexiconDoc } from "./lexicon-types";

export interface GenerateOptions {
  inputDir: string;
  outputDir: string;
  repoRelativePrefix?: string;
}

export interface GenerateSummary {
  records: number;
  queries: number;
  procedures: number;
  subscriptions: number;
  sharedDefs: number;
  skipped: number;
}

export async function generateReference(opts: GenerateOptions): Promise<GenerateSummary> {
  const { inputDir, outputDir, repoRelativePrefix = "lexicons/games/gamesgamesgamesgames" } = opts;
  const summary: GenerateSummary = { records: 0, queries: 0, procedures: 0, subscriptions: 0, sharedDefs: 0, skipped: 0 };

  rmSync(outputDir, { recursive: true, force: true });
  mkdirSync(outputDir, { recursive: true });

  const files = walk(inputDir).filter((f) => f.endsWith(".json"));
  const docsForDefs: LexiconDoc[] = [];

  const parsedDocs: { file: string; doc: LexiconDoc; kind: ReturnType<typeof getMainType> }[] = [];
  for (const file of files) {
    const parsed = parseLexiconFile(file);
    if (!parsed.ok) {
      console.warn(`[generate-reference] skip ${file}: ${parsed.error}`);
      summary.skipped += 1;
      continue;
    }
    parsedDocs.push({ file, doc: parsed.doc, kind: getMainType(parsed.doc) });
  }

  const categoryByKind = {
    record: "records",
    query: "queries",
    procedure: "procedures",
    subscription: "subscriptions",
  } as const;
  const refIndex: RefIndex = new Map();
  for (const { doc, kind } of parsedDocs) {
    if (kind === "record" || kind === "query" || kind === "procedure" || kind === "subscription") {
      refIndex.set(doc.id, categoryByKind[kind]);
    }
  }

  for (const { file, doc, kind } of parsedDocs) {
    const sourcePath = `${repoRelativePrefix}/${path.relative(inputDir, file)}`;
    const slug = doc.id.replace(/\./g, "-");

    switch (kind) {
      case "record":
        writeMdx(path.join(outputDir, "records", `${slug}.mdx`), renderRecordMdx(doc, sourcePath, refIndex));
        summary.records += 1;
        break;
      case "query":
        writeMdx(path.join(outputDir, "queries", `${slug}.mdx`), renderQueryMdx(doc, sourcePath, refIndex));
        summary.queries += 1;
        break;
      case "procedure":
        writeMdx(path.join(outputDir, "procedures", `${slug}.mdx`), renderProcedureMdx(doc, sourcePath, refIndex));
        summary.procedures += 1;
        break;
      case "subscription":
        writeMdx(path.join(outputDir, "subscriptions", `${slug}.mdx`), renderProcedureMdx(doc, sourcePath, refIndex));
        summary.subscriptions += 1;
        break;
      case "token":
      case "other":
        docsForDefs.push(doc);
        summary.sharedDefs += 1;
        break;
    }
  }

  writeMdx(path.join(outputDir, "shared-definitions.mdx"), renderSharedDefsMdx(docsForDefs));

  writeMeta(outputDir, { title: "Reference", pages: ["records", "queries", "procedures", "shared-definitions"] });

  console.log(
    `[generate-reference] records=${summary.records} queries=${summary.queries} procedures=${summary.procedures} subscriptions=${summary.subscriptions} sharedDefs=${summary.sharedDefs} skipped=${summary.skipped}`,
  );

  return summary;
}

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = path.join(dir, entry);
    const stat = statSync(full);
    if (stat.isDirectory()) {
      out.push(...walk(full));
    } else {
      out.push(full);
    }
  }
  return out;
}

function writeMdx(filePath: string, contents: string): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  writeFileSync(filePath, contents, "utf8");
}

function writeMeta(dir: string, meta: { title: string; pages?: string[] }): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, "meta.json"), JSON.stringify(meta, null, 2), "utf8");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const repoRoot = path.resolve(fileURLToPath(import.meta.url), "..", "..", "..", "..");
  const inputDir = path.join(repoRoot, "lexicons", "games", "gamesgamesgamesgames");
  const outputDir = path.join(repoRoot, "apps", "docs", "content", "docs", "reference");
  generateReference({ inputDir, outputDir }).catch((err) => {
    console.error("[generate-reference] fatal:", err);
    process.exit(1);
  });
}
