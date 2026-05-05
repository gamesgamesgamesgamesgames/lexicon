import type { ObjectDef, LexiconProperty } from "./lexicon-types";

export interface SchemaFieldRow {
  name: string;
  type: string;
  required: boolean;
  description?: string;
  refTarget?: { href: string; label: string };
}

export type RefIndex = Map<string, "records" | "queries" | "procedures" | "subscriptions">;

export function extractFields(obj: ObjectDef, refIndex: RefIndex = new Map()): SchemaFieldRow[] {
  const required = new Set(obj.required ?? []);
  return Object.entries(obj.properties ?? {}).map(([name, prop]) => {
    const { type, refTarget } = describeType(prop, refIndex);
    return {
      name,
      type,
      required: required.has(name),
      description: prop.description,
      refTarget,
    };
  });
}

function describeType(prop: LexiconProperty, refIndex: RefIndex): { type: string; refTarget?: { href: string; label: string } } {
  if (prop.type === "ref" && typeof prop.ref === "string") {
    return { type: "ref", refTarget: refToHref(prop.ref, refIndex) };
  }
  if (prop.type === "array" && prop.items) {
    const inner = describeType(prop.items, refIndex);
    return { type: `array<${inner.type}>`, refTarget: inner.refTarget };
  }
  if (prop.type === "string" && typeof prop.format === "string") {
    return { type: `string (${prop.format})` };
  }
  return { type: prop.type };
}

function refToHref(ref: string, refIndex: RefIndex): { href: string; label: string } {
  if (ref.startsWith("#")) {
    return { href: ref, label: ref.slice(1) };
  }
  const [lexId, anchor] = ref.split("#");
  if (lexId && lexId.endsWith(".defs") && anchor) {
    return { href: `/docs/reference/shared-definitions#${anchor}`, label: anchor };
  }
  const targetId = lexId ?? ref;
  const label = anchor ?? targetId.split(".").pop() ?? targetId;
  const category = refIndex.get(targetId);
  if (category) {
    const href = anchor
      ? `/docs/reference/${category}/${targetId}#${anchor}`
      : `/docs/reference/${category}/${targetId}`;
    return { href, label };
  }
  if (!targetId.startsWith("games.gamesgamesgamesgames.")) {
    const parts = targetId.split(".");
    const group = parts.slice(0, 3).join("-");
    const hash = parts.join("").toLowerCase();
    return { href: `https://atproto.com/lexicons/${group}#${hash}`, label };
  }
  const defsAnchor = anchor ?? targetId.split(".").pop() ?? targetId;
  return { href: `/docs/reference/shared-definitions#${defsAnchor}`, label };
}
