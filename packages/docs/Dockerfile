FROM oven/bun:1 AS deps
WORKDIR /app
COPY package.json bun.lock ./
COPY packages/docs/package.json packages/docs/
COPY packages/design-system/package.json packages/design-system/
RUN bun install --frozen-lockfile

FROM oven/bun:1 AS builder
WORKDIR /app
ARG NEXT_PUBLIC_CLIENT_KEY
ARG NEXT_PUBLIC_HAPPYVIEW_URL
ENV NEXT_PUBLIC_CLIENT_KEY=$NEXT_PUBLIC_CLIENT_KEY
ENV NEXT_PUBLIC_HAPPYVIEW_URL=$NEXT_PUBLIC_HAPPYVIEW_URL
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/packages/docs/node_modules ./packages/docs/node_modules
COPY --from=deps /app/packages/design-system/node_modules ./packages/design-system/node_modules
COPY packages/design-system ./packages/design-system
COPY packages/docs ./packages/docs
COPY lexicons ./lexicons
COPY tsconfig.base.json ./
COPY package.json ./

WORKDIR /app/packages/docs
RUN bun run build

FROM node:22-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3001

COPY --from=builder /app/packages/docs/.next/standalone ./
COPY --from=builder /app/packages/docs/.next/static ./packages/docs/.next/static
COPY --from=builder /app/packages/docs/public ./packages/docs/public

EXPOSE 3001
CMD ["node", "packages/docs/server.js"]
