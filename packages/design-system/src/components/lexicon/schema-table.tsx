import type { ReactNode } from "react";

export interface SchemaField {
  name: string;
  type: string;
  required: boolean;
  description?: string;
  refTarget?: { href: string; label: string };
}

interface SchemaTableProps {
  title?: string;
  fields: SchemaField[];
  empty?: ReactNode;
}

export function SchemaTable({ title, fields, empty }: SchemaTableProps) {
  if (fields.length === 0) {
    return empty ? <div className="my-4 text-sm text-fg-muted">{empty}</div> : null;
  }
  return (
    <section className="not-prose my-8">
      {title && <h3 className="mb-3 text-sm font-semibold uppercase tracking-wide text-fg-muted">{title}</h3>}
      <div className="overflow-hidden rounded-md border border-border">
        <table className="w-full border-collapse text-left text-sm">
          <thead className="bg-bg-subtle text-xs uppercase tracking-wide text-fg-subtle">
            <tr>
              <th className="px-4 py-2 font-medium">Field</th>
              <th className="px-4 py-2 font-medium">Type</th>
              <th className="px-4 py-2 font-medium">Description</th>
            </tr>
          </thead>
          <tbody>
            {fields.map((f) => (
              <tr key={f.name} className="border-t border-border">
                <td className="px-4 py-2 font-mono text-fg">
                  {f.name}
                  {f.required && <span className="ml-1 text-fg-subtle">*</span>}
                </td>
                <td className="px-4 py-2 font-mono text-fg-muted">
                  {f.refTarget ? <a href={f.refTarget.href} className="text-fg underline decoration-fg/30 underline-offset-[3px] hover:decoration-fg">{f.refTarget.label}</a> : f.type}
                </td>
                <td className="px-4 py-2 text-fg-muted">{f.description ?? ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
