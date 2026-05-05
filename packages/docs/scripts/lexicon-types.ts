// Minimal types for the subset of the ATProto lexicon schema we need.
// Not a complete definition — just what the generator consumes.

export interface LexiconDoc {
  lexicon: 1;
  id: string;
  description?: string;
  defs: Record<string, LexiconDef>;
}

export type LexiconDef =
  | RecordDef
  | QueryDef
  | ProcedureDef
  | SubscriptionDef
  | ObjectDef
  | TokenDef
  | StringDef
  | { type: string; [k: string]: unknown };

export interface RecordDef {
  type: "record";
  description?: string;
  key: string;
  record: ObjectDef;
}

export interface QueryDef {
  type: "query";
  description?: string;
  parameters?: ObjectDef;
  output?: { encoding: string; schema?: ObjectDef };
  errors?: { name: string; description?: string }[];
}

export interface ProcedureDef {
  type: "procedure";
  description?: string;
  parameters?: ObjectDef;
  input?: { encoding: string; schema?: ObjectDef };
  output?: { encoding: string; schema?: ObjectDef };
  errors?: { name: string; description?: string }[];
}

export interface SubscriptionDef {
  type: "subscription";
  description?: string;
  parameters?: ObjectDef;
  message?: { schema?: ObjectDef };
}

export interface ObjectDef {
  type: "object";
  description?: string;
  required?: string[];
  properties: Record<string, LexiconProperty>;
}

export interface TokenDef {
  type: "token";
  description?: string;
}

export interface StringDef {
  type: "string";
  description?: string;
  format?: string;
  knownValues?: string[];
}

export interface LexiconProperty {
  type: string;
  description?: string;
  ref?: string;
  items?: LexiconProperty;
  format?: string;
  [k: string]: unknown;
}

export type MainType = "record" | "query" | "procedure" | "subscription" | "token" | "other";

export function getMainType(doc: LexiconDoc): MainType {
  const main = doc.defs["main"];
  if (!main || typeof main !== "object") return "other";
  const t = (main as { type?: string }).type;
  if (t === "record" || t === "query" || t === "procedure" || t === "subscription" || t === "token") return t;
  return "other";
}
