import type { ReactNode } from "react";
import { AuthProvider } from "@/lib/auth";
import { Nav } from "./nav";
import { Footer } from "./footer";

export default function HomeRootLayout({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-screen flex-col bg-bg text-fg">
      <AuthProvider>
        <Nav />
        <main className="flex-1">{children}</main>
        <Footer />
      </AuthProvider>
    </div>
  );
}
