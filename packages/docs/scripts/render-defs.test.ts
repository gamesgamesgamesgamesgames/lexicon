import { describe, expect, it } from "bun:test";
import { renderSharedDefsMdx } from "./render-defs";
import { parseLexiconFile } from "./parse-lexicon";
import path from "node:path";

describe("renderSharedDefsMdx", () => {
  it("renders one section per non-main def across all input docs", () => {
    const parsed = parseLexiconFile(path.join(import.meta.dir, "__fixtures__/defs.json"));
    if (!parsed.ok) throw new Error(parsed.error);
    const mdx = renderSharedDefsMdx([parsed.doc]);
    expect(mdx).toContain('title: "Shared definitions"');
    expect(mdx).toContain('<a id="genre"');
    expect(mdx).toContain("A game genre.");
    expect(mdx).toContain("action");
  });
});
