import { describe, expect, it } from "bun:test";
import { renderProcedureMdx } from "./render-procedure";
import { parseLexiconFile } from "./parse-lexicon";
import path from "node:path";

describe("renderProcedureMdx", () => {
  it("renders input and output schemas for a procedure", () => {
    const parsed = parseLexiconFile(path.join(import.meta.dir, "__fixtures__/procedure.createGame.json"));
    if (!parsed.ok) throw new Error(parsed.error);
    const mdx = renderProcedureMdx(parsed.doc, "lexicons/games/gamesgamesgamesgames/createGame.json");
    expect(mdx).toContain('type="procedure"');
    expect(mdx).toContain('method="POST"');
    expect(mdx).toContain("Input");
    expect(mdx).toContain("Output");
  });
});
