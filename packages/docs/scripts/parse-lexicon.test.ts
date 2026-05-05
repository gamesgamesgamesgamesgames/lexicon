import { describe, expect, it } from "bun:test";
import { parseLexiconFile } from "./parse-lexicon";
import path from "node:path";

const fixtures = path.join(import.meta.dir, "__fixtures__");

describe("parseLexiconFile", () => {
  it("returns a valid lexicon for a well-formed file", () => {
    const result = parseLexiconFile(path.join(fixtures, "record.game.json"));
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.doc.id).toBe("games.gamesgamesgamesgames.game");
      expect(result.doc.defs.main).toBeDefined();
    }
  });

  it("returns an error for a malformed file", () => {
    const result = parseLexiconFile(path.join(fixtures, "malformed.json"));
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toContain("defs");
  });

  it("returns an error for a file that doesn't exist", () => {
    const result = parseLexiconFile(path.join(fixtures, "nope.json"));
    expect(result.ok).toBe(false);
  });
});
