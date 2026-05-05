"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Button } from "@lexicon/design-system";
import { useAuth } from "@/lib/auth";
import { xrpcProcedure } from "@/lib/xrpc";

interface CreatedClient {
  id: string;
  name: string;
  clientKey: string;
  clientType: string;
  clientSecret?: string;
}

function CopyButton({ value }: { value: string }) {
  const [copied, setCopied] = useState(false);

  function handleCopy() {
    navigator.clipboard.writeText(value).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  }

  return (
    <button
      onClick={handleCopy}
      className="ml-2 rounded border border-border bg-bg px-2 py-0.5 font-mono text-xs text-fg-muted hover:text-fg"
    >
      {copied ? "Copied!" : "Copy"}
    </button>
  );
}

function MultiInput({
  label,
  values,
  onChange,
  placeholder,
  required,
}: {
  label: string;
  values: string[];
  onChange: (values: string[]) => void;
  placeholder?: string;
  required?: boolean;
}) {
  function update(i: number, val: string) {
    const next = [...values];
    next[i] = val;
    onChange(next);
  }

  function add() {
    onChange([...values, ""]);
  }

  function remove(i: number) {
    onChange(values.filter((_, idx) => idx !== i));
  }

  return (
    <div className="flex flex-col gap-2">
      <label className="font-mono text-xs uppercase tracking-wider text-fg-muted">
        {label}
        {required && <span className="ml-1 text-red-400">*</span>}
      </label>
      {values.map((v, i) => (
        <div key={i} className="flex items-center gap-2">
          <input
            type="text"
            value={v}
            onChange={(e) => update(i, e.target.value)}
            placeholder={placeholder}
            required={required && i === 0}
            className="flex-1 rounded border border-border bg-bg px-3 py-2 font-mono text-sm text-fg placeholder:text-fg-subtle focus:border-accent focus:outline-none"
          />
          {values.length > 1 && (
            <button
              type="button"
              onClick={() => remove(i)}
              className="text-fg-muted hover:text-fg"
              aria-label="Remove"
            >
              &#x2715;
            </button>
          )}
        </div>
      ))}
      <button
        type="button"
        onClick={add}
        className="self-start rounded border border-border px-2 py-0.5 font-mono text-xs text-fg-muted hover:text-fg"
      >
        + Add
      </button>
    </div>
  );
}

export default function NewClientPage() {
  const { session, loading } = useAuth();
  const router = useRouter();

  const [name, setName] = useState("");
  const [clientIdUrl, setClientIdUrl] = useState("");
  const [clientUri, setClientUri] = useState("");
  const [redirectUris, setRedirectUris] = useState<string[]>([""]);
  const [clientType, setClientType] = useState<"confidential" | "public">("confidential");
  const [scopes, setScopes] = useState<string[]>(["atproto"]);
  const [allowedOrigins, setAllowedOrigins] = useState<string[]>([""]);

  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [created, setCreated] = useState<CreatedClient | null>(null);

  useEffect(() => {
    if (!loading && !session) {
      router.replace("/");
    }
  }, [loading, session, router]);

  if (loading || (!session && !loading)) {
    return null;
  }

  if (created) {
    return (
      <div className="mx-auto max-w-2xl px-6 py-20">
        <Link href="/dashboard" className="mb-8 inline-flex items-center gap-1 text-sm text-accent hover:underline">
          &larr; Back
        </Link>
        <div className="mt-6 surface-card p-8">
          <h1 className="mb-2 font-mono text-xl tracking-tight text-fg">Client created</h1>
          <p className="mb-8 text-sm text-fg-muted">
            Your new API client <strong className="text-fg">{created.name}</strong> has been created.
          </p>

          <div className="flex flex-col gap-6">
            <div>
              <p className="mb-1 font-mono text-xs uppercase tracking-wider text-fg-muted">Client Key</p>
              <div className="flex items-center rounded border border-border bg-bg px-3 py-2">
                <span className="flex-1 font-mono text-sm text-fg break-all">{created.clientKey}</span>
                <CopyButton value={created.clientKey} />
              </div>
            </div>

            {created.clientSecret && (
              <div>
                <p className="mb-1 font-mono text-xs uppercase tracking-wider text-fg-muted">Client Secret</p>
                <div className="flex items-center rounded border border-border bg-bg px-3 py-2">
                  <span className="flex-1 font-mono text-sm text-fg break-all">{created.clientSecret}</span>
                  <CopyButton value={created.clientSecret} />
                </div>
                <p className="mt-2 rounded border border-red-500/30 bg-red-500/10 px-3 py-2 text-xs text-red-400">
                  This secret will not be shown again. Copy it now and store it securely.
                </p>
              </div>
            )}
          </div>

          <div className="mt-8">
            <Link href="/dashboard" className="text-sm text-accent hover:underline">
              &larr; Back to dashboard
            </Link>
          </div>
        </div>
      </div>
    );
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!session) return;

    const filteredRedirectUris = redirectUris.filter(Boolean);
    if (filteredRedirectUris.length === 0) {
      setError("At least one redirect URI is required.");
      return;
    }

    const filteredOrigins = allowedOrigins.filter(Boolean);
    const filteredScopes = scopes.filter(Boolean).join(" ");

    setSubmitting(true);
    setError(null);

    try {
      const res = await xrpcProcedure<{ client: CreatedClient; clientSecret?: string }>(
        session,
        "dev.happyview.createApiClient",
        {
          name,
          clientIdUrl,
          clientUri,
          redirectUris: filteredRedirectUris,
          clientType,
          scopes: filteredScopes,
          ...(filteredOrigins.length > 0 ? { allowedOrigins: filteredOrigins } : {}),
        },
      );
      setCreated({ ...res.client, clientSecret: res.clientSecret });
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="mx-auto max-w-2xl px-6 py-20">
      <Link href="/dashboard" className="mb-8 inline-flex items-center gap-1 text-sm text-accent hover:underline">
        &larr; Back
      </Link>

      <h1 className="mb-8 mt-6 font-mono text-2xl tracking-tight text-fg">Create API Client</h1>

      {error && (
        <div className="mb-6 rounded border border-red-500/30 bg-red-500/10 px-4 py-3 text-sm text-red-400">
          {error}
        </div>
      )}

      <form onSubmit={handleSubmit} className="surface-card flex flex-col gap-6 p-8">
        {/* Name */}
        <div className="flex flex-col gap-1.5">
          <label className="font-mono text-xs uppercase tracking-wider text-fg-muted">
            Name <span className="text-red-400">*</span>
          </label>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            required
            placeholder="My App"
            className="rounded border border-border bg-bg px-3 py-2 font-mono text-sm text-fg placeholder:text-fg-subtle focus:border-accent focus:outline-none"
          />
        </div>

        {/* Client ID URL */}
        <div className="flex flex-col gap-1.5">
          <label className="font-mono text-xs uppercase tracking-wider text-fg-muted">
            Client ID URL <span className="text-red-400">*</span>
          </label>
          <input
            type="url"
            value={clientIdUrl}
            onChange={(e) => setClientIdUrl(e.target.value)}
            required
            placeholder="https://example.com/client-metadata.json"
            className="rounded border border-border bg-bg px-3 py-2 font-mono text-sm text-fg placeholder:text-fg-subtle focus:border-accent focus:outline-none"
          />
        </div>

        {/* Client URI */}
        <div className="flex flex-col gap-1.5">
          <label className="font-mono text-xs uppercase tracking-wider text-fg-muted">
            Client URI <span className="text-red-400">*</span>
          </label>
          <input
            type="url"
            value={clientUri}
            onChange={(e) => setClientUri(e.target.value)}
            required
            placeholder="https://example.com"
            className="rounded border border-border bg-bg px-3 py-2 font-mono text-sm text-fg placeholder:text-fg-subtle focus:border-accent focus:outline-none"
          />
        </div>

        {/* Redirect URIs */}
        <MultiInput
          label="Redirect URIs"
          values={redirectUris}
          onChange={setRedirectUris}
          placeholder="https://example.com/callback"
          required
        />

        {/* Client Type */}
        <div className="flex flex-col gap-1.5">
          <span className="font-mono text-xs uppercase tracking-wider text-fg-muted">
            Client Type <span className="text-red-400">*</span>
          </span>
          <div className="flex flex-col gap-2">
            {(["confidential", "public"] as const).map((type) => (
              <label key={type} className="flex cursor-pointer items-center gap-2 text-sm text-fg">
                <input
                  type="radio"
                  name="clientType"
                  value={type}
                  checked={clientType === type}
                  onChange={() => setClientType(type)}
                  className="accent-accent"
                />
                <span className="capitalize">{type}</span>
              </label>
            ))}
          </div>
        </div>

        {/* Scopes */}
        <MultiInput
          label="Scopes"
          values={scopes}
          onChange={setScopes}
          placeholder="atproto"
        />

        {/* Allowed Origins (public clients only) */}
        {clientType === "public" && (
          <MultiInput
            label="Allowed Origins"
            values={allowedOrigins}
            onChange={setAllowedOrigins}
            placeholder="https://example.com"
          />
        )}

        <div className="pt-2">
          <Button type="submit" disabled={submitting}>
            {submitting ? "Creating…" : "Create client"}
          </Button>
        </div>
      </form>
    </div>
  );
}
