import { readFileSync } from "node:fs";
import type { LexiconDoc } from "./lexicon-types";

export type ParseResult =
  | { ok: true; doc: LexiconDoc; path: string }
  | { ok: false; error: string; path: string };

export function parseLexiconFile(filePath: string): ParseResult {
  let raw: string;
  try {
    raw = readFileSync(filePath, "utf8");
  } catch (err) {
    return { ok: false, error: `read failed: ${(err as Error).message}`, path: filePath };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    return { ok: false, error: `invalid JSON: ${(err as Error).message}`, path: filePath };
  }

  if (!parsed || typeof parsed !== "object") {
    return { ok: false, error: "not an object", path: filePath };
  }
  const obj = parsed as Record<string, unknown>;
  if (typeof obj["id"] !== "string") {
    return { ok: false, error: "missing id", path: filePath };
  }
  if (!obj["defs"] || typeof obj["defs"] !== "object") {
    return { ok: false, error: "missing defs", path: filePath };
  }
  return { ok: true, doc: parsed as LexiconDoc, path: filePath };
}
