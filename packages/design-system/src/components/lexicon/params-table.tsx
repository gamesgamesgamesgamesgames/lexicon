import { SchemaTable, type SchemaField } from "./schema-table";

interface ParamsTableProps {
  params: SchemaField[];
}

export function ParamsTable({ params }: ParamsTableProps) {
  return <SchemaTable title="Parameters" fields={params} empty="No parameters." />;
}
