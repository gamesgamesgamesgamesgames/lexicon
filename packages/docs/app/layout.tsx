import type { ReactNode } from "react";
import { RootProvider } from "fumadocs-ui/provider";
import { fontVariables } from "@lexicon/design-system/fonts";
import "./global.css";

export const metadata = {
  metadataBase: new URL(`https://${process.env.VERCEL_PROJECT_PRODUCTION_URL ?? "localhost:3000"}`),
  title: "The Pentaract",
  description: "The AppView for the games.gamesgamesgamesgames.* ATProto lexicons",
  icons: { icon: "/pentaract-logo.png" },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${fontVariables} dark`} suppressHydrationWarning>
      <body>
        <RootProvider>{children}</RootProvider>
      </body>
    </html>
  );
}
