import { docs } from "@/.source";
import { loader, getSlugs } from "fumadocs-core/source";

const NSID_PREFIX = "games-gamesgamesgamesgames-";

export const source = loader({
  baseUrl: "/docs",
  source: docs.toFumadocsSource(),
  slugs: (info) =>
    getSlugs(info).map((segment) =>
      segment.startsWith(NSID_PREFIX) ? segment.replace(/-/g, ".") : segment,
    ),
});
