"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter, useParams } from "next/navigation";
import { Button } from "@lexicon/design-system";
import { useAuth } from "@/lib/auth";
import { xrpcQuery, xrpcProcedure } from "@/lib/xrpc";

interface ApiClient {
  id: string;
  name: string;
  clientKey: string;
  clientIdUrl: string;
  clientUri: string;
  redirectUris: string[];
  clientType: string;
  scopes: string;
  allowedOrigins: string[];
  isActive: boolean;
  createdAt: string;
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <span className="font-mono text-xs uppercase tracking-wider text-fg-muted">{label}</span>
      <div className="text-sm text-fg">{children}</div>
    </div>
  );
}

export default function ClientDetailPage() {
  const { session, loading } = useAuth();
  const router = useRouter();
  const params = useParams();
  const id = params.id as string;

  const [client, setClient] = useState<ApiClient | null>(null);
  const [fetching, setFetching] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [showConfirm, setShowConfirm] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);

  useEffect(() => {
    if (!loading && !session) {
      router.replace("/");
    }
  }, [loading, session, router]);

  useEffect(() => {
    if (!session || !id) return;
    setFetching(true);
    xrpcQuery<{ client: ApiClient }>(session, "dev.happyview.getApiClient", { id })
      .then((res) => setClient(res.client))
      .catch((err) => {
        // Treat not-found as a redirect
        if (err.message.includes("404") || err.message.includes("not found")) {
          router.replace("/dashboard");
        } else {
          setError(err.message);
        }
      })
      .finally(() => setFetching(false));
  }, [session, id, router]);

  if (loading || (!session && !loading)) {
    return null;
  }

  async function handleDelete() {
    if (!session) return;
    setDeleting(true);
    setDeleteError(null);
    try {
      await xrpcProcedure(session, "dev.happyview.deleteApiClient", { id });
      router.replace("/dashboard");
    } catch (err) {
      setDeleteError(err instanceof Error ? err.message : "Something went wrong.");
      setDeleting(false);
    }
  }

  return (
    <div className="mx-auto max-w-4xl px-6 py-20">
      <Link href="/dashboard" className="mb-8 inline-flex items-center gap-1 text-sm text-accent hover:underline">
        &larr; Back
      </Link>

      {error && (
        <div className="mt-6 rounded border border-red-500/30 bg-red-500/10 px-4 py-3 text-sm text-red-400">
          {error}
        </div>
      )}

      {fetching ? (
        <div className="mt-8 surface-card px-6 py-12 text-center text-sm text-fg-muted">
          Loading…
        </div>
      ) : client ? (
        <>
          <h1 className="mb-8 mt-6 font-mono text-2xl tracking-tight text-fg">{client.name}</h1>

          <div className="surface-card p-8">
            <div className="grid grid-cols-1 gap-6 sm:grid-cols-2">
              <Field label="Client Key">
                <span className="font-mono text-xs break-all">{client.clientKey}</span>
              </Field>

              <Field label="Type">
                <span className="capitalize">{client.clientType}</span>
              </Field>

              <Field label="Status">
                <span className={client.isActive ? "text-green-400" : "text-fg-muted"}>
                  {client.isActive ? "Active" : "Inactive"}
                </span>
              </Field>

              <Field label="Created">
                {new Date(client.createdAt).toLocaleString()}
              </Field>

              <Field label="Scopes">
                <ul className="flex flex-wrap gap-2 mt-1">
                  {client.scopes.split(" ").filter(Boolean).map((scope) => (
                    <li key={scope} className="rounded border border-border bg-bg-subtle/60 px-2 py-0.5 font-mono text-xs text-fg-muted">
                      {scope}
                    </li>
                  ))}
                </ul>
              </Field>

              <div className="sm:col-span-2">
                <Field label="Client ID URL">
                  <a
                    href={client.clientIdUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="break-all font-mono text-xs text-accent hover:underline"
                  >
                    {client.clientIdUrl}
                  </a>
                </Field>
              </div>

              <div className="sm:col-span-2">
                <Field label="Client URI">
                  <a
                    href={client.clientUri}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="break-all font-mono text-xs text-accent hover:underline"
                  >
                    {client.clientUri}
                  </a>
                </Field>
              </div>

              <div className="sm:col-span-2">
                <Field label="Redirect URIs">
                  <ul className="flex flex-col gap-1 mt-1">
                    {client.redirectUris.map((uri) => (
                      <li key={uri} className="font-mono text-xs text-fg-muted break-all">
                        {uri}
                      </li>
                    ))}
                  </ul>
                </Field>
              </div>

              {client.clientType === "public" && client.allowedOrigins.length > 0 && (
                <div className="sm:col-span-2">
                  <Field label="Allowed Origins">
                    <ul className="flex flex-col gap-1 mt-1">
                      {client.allowedOrigins.map((origin) => (
                        <li key={origin} className="font-mono text-xs text-fg-muted break-all">
                          {origin}
                        </li>
                      ))}
                    </ul>
                  </Field>
                </div>
              )}
            </div>
          </div>

          {/* Delete section */}
          <div className="mt-10 surface-card p-8">
            <h2 className="mb-1 font-mono text-sm uppercase tracking-wider text-fg-muted">
              Danger Zone
            </h2>

            {deleteError && (
              <div className="mb-4 rounded border border-red-500/30 bg-red-500/10 px-4 py-3 text-sm text-red-400">
                {deleteError}
              </div>
            )}

            {showConfirm ? (
              <div className="flex flex-col gap-4">
                <p className="text-sm text-fg-muted">
                  Delete this client and all its children? This action cannot be undone.
                </p>
                <div className="flex items-center gap-3">
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => {
                      setShowConfirm(false);
                      setDeleteError(null);
                    }}
                    disabled={deleting}
                  >
                    Cancel
                  </Button>
                  <button
                    onClick={handleDelete}
                    disabled={deleting}
                    className="rounded border border-red-500/40 bg-red-500/10 px-3 py-1.5 text-sm text-red-400 hover:bg-red-500/20 disabled:opacity-50"
                  >
                    {deleting ? "Deleting…" : "Confirm delete"}
                  </button>
                </div>
              </div>
            ) : (
              <button
                onClick={() => setShowConfirm(true)}
                className="text-sm text-red-400 hover:text-red-300"
              >
                Delete this client
              </button>
            )}
          </div>
        </>
      ) : null}
    </div>
  );
}
