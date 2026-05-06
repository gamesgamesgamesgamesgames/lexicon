import { createMDX } from "fumadocs-mdx/next";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const withMDX = createMDX();

/** @type {import('next').NextConfig} */
const config = {
  reactStrictMode: true,
  output: "standalone",
  outputFileTracingRoot: join(dirname(fileURLToPath(import.meta.url)), "../../"),
  transpilePackages: ["@lexicon/design-system"],
};

export default withMDX(config);
