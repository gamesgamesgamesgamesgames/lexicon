import { headers } from "next/headers";
import { NextResponse } from "next/server";

export async function GET() {
  const h = await headers();
  const host = h.get("host") ?? "localhost:3001";
  const proto = h.get("x-forwarded-proto") ?? "http";
  const origin = `${proto}://${host}`;

  return NextResponse.json({
    client_id: `${origin}/oauth-client-metadata.json`,
    client_name: "The Pentaract",
    client_uri: origin,
    redirect_uris: [`${origin}/auth/callback`],
    scope: "atproto",
    grant_types: ["authorization_code"],
    response_types: ["code"],
    token_endpoint_auth_method: "none",
    application_type: "web",
    dpop_bound_access_tokens: true,
  });
}
