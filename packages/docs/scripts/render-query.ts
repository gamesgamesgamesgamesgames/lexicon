import type { LexiconDoc, QueryDef } from "./lexicon-types";
import { extractFields, type RefIndex } from "./extract-fields";

export function renderQueryMdx(doc: LexiconDoc, sourcePath: string, refIndex: RefIndex = new Map()): string {
  const main = doc.defs["main"] as QueryDef;
  const description = main.description ?? "";
  const params = main.parameters ? extractFields(main.parameters, refIndex) : [];
  const output = main.output?.schema ? extractFields(main.output.schema, refIndex) : [];
  const title = doc.id.replace(/^games\.gamesgamesgamesgames\./, "");

  return [
    "---",
    `title: ${JSON.stringify(title)}`,
    `fullTitle: ${JSON.stringify(doc.id)}`,
    `description: ${JSON.stringify(description)}`,
    "---",
    "",
    `<LexiconHeader id="${doc.id}" type="query" method="GET" />`,
    "",
    `<ParamsTable params={${JSON.stringify(params, null, 2)}} />`,
    "",
    "## Output",
    "",
    `<SchemaTable title="Response body" fields={${JSON.stringify(output, null, 2)}} />`,
    "",
    `<SourceLink path="${sourcePath}" />`,
    "",
  ].join("\n");
}
