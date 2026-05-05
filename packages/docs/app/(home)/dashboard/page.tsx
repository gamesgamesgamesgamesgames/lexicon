"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Button } from "@lexicon/design-system";
import { useAuth } from "@/lib/auth";
import { xrpcQuery } from "@/lib/xrpc";

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
      onClick={(e) => {
        e.stopPropagation();
        handleCopy();
      }}
      className="ml-2 shrink-0 rounded border border-border bg-bg px-2 py-0.5 font-mono text-xs text-fg-muted hover:text-fg"
    >
      {copied ? "Copied!" : "Copy"}
    </button>
  );
}

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

export default function DashboardPage() {
  const { session, loading } = useAuth();
  const router = useRouter();
  const [clients, setClients] = useState<ApiClient[]>([]);
  const [fetching, setFetching] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!loading && !session) {
      router.replace("/");
    }
  }, [loading, session, router]);

  useEffect(() => {
    if (!session) return;
    setFetching(true);
    xrpcQuery<{ clients: ApiClient[] }>(session, "dev.happyview.listApiClients")
      .then((res) => setClients(res.clients))
      .catch((err) => setError(err.message))
      .finally(() => setFetching(false));
  }, [session]);

  if (loading || (!session && !loading)) {
    return null;
  }

  return (
    <div className="mx-auto max-w-4xl px-6 py-20">
      <div className="mb-8 flex items-center justify-between">
        <h1 className="font-mono text-2xl tracking-tight text-fg">API Clients</h1>
        <Link href="/dashboard/new">
          <Button size="sm">Create new client</Button>
        </Link>
      </div>

      {error && (
        <div className="mb-6 rounded border border-red-500/30 bg-red-500/10 px-4 py-3 text-sm text-red-400">
          {error}
        </div>
      )}

      {fetching ? (
        <div className="surface-card px-6 py-12 text-center text-sm text-fg-muted">
          Loading clients…
        </div>
      ) : clients.length === 0 ? (
        <div className="surface-card flex flex-col items-center gap-4 px-6 py-16 text-center">
          <p className="text-fg-muted">No API clients yet.</p>
          <Link href="/dashboard/new">
            <Button variant="secondary" size="sm">Create your first client</Button>
          </Link>
        </div>
      ) : (
        <div className="surface-card overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border">
                <th className="px-4 py-3 text-left font-mono text-xs uppercase tracking-wider text-fg-muted">Name</th>
                <th className="px-4 py-3 text-left font-mono text-xs uppercase tracking-wider text-fg-muted">Client Key</th>
                <th className="px-4 py-3 text-left font-mono text-xs uppercase tracking-wider text-fg-muted">Type</th>
                <th className="px-4 py-3 text-left font-mono text-xs uppercase tracking-wider text-fg-muted">Created</th>
              </tr>
            </thead>
            <tbody>
              {clients.map((client, i) => (
                <tr
                  key={client.id}
                  className={i < clients.length - 1 ? "border-b border-border" : ""}
                >
                  <td className="px-4 py-3">
                    <Link
                      href={`/dashboard/${client.id}`}
                      className="text-accent hover:underline"
                    >
                      {client.name}
                    </Link>
                  </td>
                  <td className="px-4 py-3">
                    <div className="flex items-center">
                      <span className="font-mono text-xs text-fg-muted break-all">{client.clientKey}</span>
                      <CopyButton value={client.clientKey} />
                    </div>
                  </td>
                  <td className="px-4 py-3 text-fg-muted capitalize">{client.clientType}</td>
                  <td className="px-4 py-3 text-fg-muted">
                    {new Date(client.createdAt).toLocaleDateString()}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
