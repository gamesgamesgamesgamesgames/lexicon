import { describe, expect, it } from "bun:test";
import { extractFields } from "./extract-fields";
import type { ObjectDef } from "./lexicon-types";

const obj: ObjectDef = {
  type: "object",
  required: ["name"],
  properties: {
    name: { type: "string", description: "The game's name." },
    createdAt: { type: "string", format: "datetime" },
    genres: { type: "array", items: { type: "ref", ref: "games.gamesgamesgamesgames.defs#genre" } },
  },
};

describe("extractFields", () => {
  it("returns one row per property", () => {
    expect(extractFields(obj)).toHaveLength(3);
  });

  it("marks required fields", () => {
    const fields = extractFields(obj);
    const name = fields.find((f) => f.name === "name");
    expect(name?.required).toBe(true);
    const createdAt = fields.find((f) => f.name === "createdAt");
    expect(createdAt?.required).toBe(false);
  });

  it("formats ref arrays as 'array<ref>'", () => {
    const fields = extractFields(obj);
    const genres = fields.find((f) => f.name === "genres");
    expect(genres?.type).toBe("array<ref>");
    expect(genres?.refTarget).toEqual({
      href: "/docs/reference/shared-definitions#genre",
      label: "genre",
    });
  });

  it("returns empty array for an object with no properties", () => {
    expect(extractFields({ type: "object", properties: {} })).toEqual([]);
  });
});
