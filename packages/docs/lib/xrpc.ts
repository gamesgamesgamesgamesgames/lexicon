import type { HappyViewSession } from "@happyview/oauth-client-browser";

export async function xrpcQuery<T>(
  session: HappyViewSession,
  nsid: string,
  params?: Record<string, string>,
): Promise<T> {
  const base = process.env.NEXT_PUBLIC_HAPPYVIEW_URL || window.location.origin;
  const url = new URL(`/xrpc/${nsid}`, base);
  if (params) {
    for (const [k, v] of Object.entries(params)) {
      url.searchParams.set(k, v);
    }
  }

  const res = await session.fetchHandler(url.toString(), { method: "GET" });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`${nsid} failed (${res.status}): ${body}`);
  }
  return res.json();
}

export async function xrpcProcedure<T>(
  session: HappyViewSession,
  nsid: string,
  input: unknown,
): Promise<T> {
  const base = process.env.NEXT_PUBLIC_HAPPYVIEW_URL || window.location.origin;
  const url = `${base}/xrpc/${nsid}`;
  const res = await session.fetchHandler(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`${nsid} failed (${res.status}): ${body}`);
  }
  return res.json();
}
