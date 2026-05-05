import type { LexiconDoc, RecordDef } from "./lexicon-types";
import { extractFields, type SchemaFieldRow, type RefIndex } from "./extract-fields";

export function renderRecordMdx(doc: LexiconDoc, sourcePath: string, refIndex: RefIndex = new Map()): string {
  const main = doc.defs["main"] as RecordDef;
  const description = main.description ?? "";
  const fields = extractFields(main.record, refIndex);
  const title = shortTitle(doc.id);

  const frontmatter = [
    "---",
    `title: ${JSON.stringify(title)}`,
    `fullTitle: ${JSON.stringify(doc.id)}`,
    `description: ${JSON.stringify(description)}`,
    "---",
    "",
  ].join("\n");

  return [
    frontmatter,
    `<LexiconHeader id="${doc.id}" type="record" />`,
    "",
    `<SchemaTable title="Record fields" fields={${serializeFields(fields)}} />`,
    "",
    `<SourceLink path="${sourcePath}" />`,
    "",
  ].join("\n");
}

function serializeFields(fields: SchemaFieldRow[]): string {
  return JSON.stringify(fields, null, 2);
}

function shortTitle(id: string): string {
  return id.replace(/^games\.gamesgamesgamesgames\./, "");
}
