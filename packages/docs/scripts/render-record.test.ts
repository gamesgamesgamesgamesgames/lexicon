import { describe, expect, it } from "bun:test";
import { renderRecordMdx } from "./render-record";
import { parseLexiconFile } from "./parse-lexicon";
import path from "node:path";

const fixtures = path.join(import.meta.dir, "__fixtures__");

describe("renderRecordMdx", () => {
  it("produces MDX with frontmatter, header, and schema table", () => {
    const parsed = parseLexiconFile(path.join(fixtures, "record.game.json"));
    if (!parsed.ok) throw new Error(parsed.error);

    const mdx = renderRecordMdx(parsed.doc, "lexicons/games/gamesgamesgamesgames/game.json");

    expect(mdx).toContain("---");
    expect(mdx).toContain('title: "games.gamesgamesgamesgames.game"');
    expect(mdx).toContain("<LexiconHeader");
    expect(mdx).toContain('type="record"');
    expect(mdx).toContain("<SchemaTable");
    expect(mdx).toContain('fields={[');
    expect(mdx).toContain('"name"');
    expect(mdx).toContain("<SourceLink");
  });
});
