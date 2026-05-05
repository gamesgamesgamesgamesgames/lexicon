import type { LexiconDoc, ProcedureDef } from "./lexicon-types";
import { extractFields, type RefIndex } from "./extract-fields";

export function renderProcedureMdx(doc: LexiconDoc, sourcePath: string, refIndex: RefIndex = new Map()): string {
  const main = doc.defs["main"] as ProcedureDef;
  const description = main.description ?? "";
  const input = main.input?.schema ? extractFields(main.input.schema, refIndex) : [];
  const output = main.output?.schema ? extractFields(main.output.schema, refIndex) : [];
  const title = doc.id.replace(/^games\.gamesgamesgamesgames\./, "");

  return [
    "---",
    `title: ${JSON.stringify(title)}`,
    `fullTitle: ${JSON.stringify(doc.id)}`,
    `description: ${JSON.stringify(description)}`,
    "---",
    "",
    `<LexiconHeader id="${doc.id}" type="procedure" method="POST" />`,
    "",
    "## Input",
    "",
    `<SchemaTable title="Request body" fields={${JSON.stringify(input, null, 2)}} />`,
    "",
    "## Output",
    "",
    `<SchemaTable title="Response body" fields={${JSON.stringify(output, null, 2)}} />`,
    "",
    `<SourceLink path="${sourcePath}" />`,
    "",
  ].join("\n");
}
