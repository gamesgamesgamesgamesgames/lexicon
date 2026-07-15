import { describe, expect, it, beforeEach } from "bun:test";
import { generateReference } from "./generate-reference";
import { mkdtempSync, rmSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

describe("generateReference", () => {
  const outDir = mkdtempSync(path.join(tmpdir(), "refgen-"));

  beforeEach(() => {
    rmSync(outDir, { recursive: true, force: true });
  });

  it("writes records, queries, procedures, and shared-definitions from fixtures", async () => {
    const fixtures = path.join(import.meta.dir, "__fixtures__");
    const summary = await generateReference({
      inputDir: fixtures,
      outputDir: outDir,
    });

    expect(summary.records).toBe(1);
    expect(summary.queries).toBe(1);
    expect(summary.procedures).toBe(1);
    expect(summary.skipped).toBe(1); // malformed.json

    expect(existsSync(path.join(outDir, "records", "games-gamesgamesgamesgames-game.mdx"))).toBe(true);
    expect(existsSync(path.join(outDir, "queries", "games-gamesgamesgamesgames-getGame.mdx"))).toBe(true);
    expect(existsSync(path.join(outDir, "procedures", "games-gamesgamesgamesgames-createGame.mdx"))).toBe(true);
    expect(existsSync(path.join(outDir, "shared-definitions.mdx"))).toBe(true);

    const gameMdx = readFileSync(path.join(outDir, "records", "games-gamesgamesgamesgames-game.mdx"), "utf8");
    expect(gameMdx).toContain("games.gamesgamesgamesgames.game");
  });

  it("excludes internal dev.cartridge lexicons from the docs", async () => {
    const fixtures = path.join(import.meta.dir, "__fixtures__");
    const summary = await generateReference({
      inputDir: fixtures,
      outputDir: outDir,
    });

    // record.cartridge.json is a dev.cartridge.* lexicon and must not be emitted.
    expect(summary.excluded).toBe(1);
    expect(summary.records).toBe(1); // only the games record, not the cartridge one
    expect(existsSync(path.join(outDir, "records", "dev-cartridge-verificationRequest.mdx"))).toBe(false);
  });
});
