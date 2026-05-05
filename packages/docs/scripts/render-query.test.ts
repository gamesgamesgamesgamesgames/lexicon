import { describe, expect, it } from "bun:test";
import { renderQueryMdx } from "./render-query";
import { parseLexiconFile } from "./parse-lexicon";
import path from "node:path";

describe("renderQueryMdx", () => {
  it("renders params and output schema for a query", () => {
    const parsed = parseLexiconFile(path.join(import.meta.dir, "__fixtures__/query.getGame.json"));
    if (!parsed.ok) throw new Error(parsed.error);
    const mdx = renderQueryMdx(parsed.doc, "lexicons/games/gamesgamesgamesgames/getGame.json");
    expect(mdx).toContain('type="query"');
    expect(mdx).toContain('method="GET"');
    expect(mdx).toContain("<ParamsTable");
    expect(mdx).toContain("Output");
  });
});
