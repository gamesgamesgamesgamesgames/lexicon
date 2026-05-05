import type { LexiconDoc, StringDef } from "./lexicon-types";

export function renderSharedDefsMdx(docs: LexiconDoc[]): string {
  const sections: string[] = [];

  for (const doc of docs) {
    for (const [defName, def] of Object.entries(doc.defs)) {
      if (!def || typeof def !== "object") continue;
      const obj = def as { type: string; description?: string; knownValues?: string[] };
      const anchorName = defName === "main" ? doc.id.split(".").pop() ?? doc.id : defName;
      sections.push(renderDefSection(doc.id, defName, anchorName, obj));
    }
  }

  return [
    "---",
    'title: "Shared definitions"',
    'description: "Reusable definitions referenced across the games lexicons."',
    "---",
    "",
    "Definitions from `.defs` lexicons that other records, queries, and procedures reference.",
    "",
    ...sections,
  ].join("\n");
}

function renderDefSection(lexId: string, defName: string, anchorName: string, def: { type: string; description?: string; knownValues?: string[] }): string {
  const lines: string[] = [];
  const heading = defName === "main" ? lexId.split(".").pop() ?? lexId : defName;
  lines.push(`<section id="${anchorName}" data-lex-def className="scroll-mt-24">`);
  lines.push("");
  lines.push(`## ${heading}`);
  lines.push("");
  const ref = defName === "main" ? lexId : `${lexId}#${defName}`;
  lines.push(`\`${ref}\` &middot; <TypeBadge type="${def.type}" />`);
  lines.push("");
  if (def.description) {
    lines.push(def.description);
    lines.push("");
  }
  if (def.type === "string" && Array.isArray((def as StringDef).knownValues)) {
    lines.push("**Known values:**");
    lines.push("");
    for (const v of (def as StringDef).knownValues ?? []) {
      lines.push(`- \`${v}\``);
    }
    lines.push("");
  }
  lines.push("</section>");
  lines.push("");
  return lines.join("\n");
}
