FROM node:18.20.0-alpine3.18 AS base

# Install dependencies only when needed
FROM base AS deps
# Check https://github.com/nodejs/docker-node/tree/b4117f9333da4138b03a546ec926ef50a31506c3#nodealpine to understand why libc6-compat might be needed.
RUN apk add --no-cache libc6-compat
WORKDIR /app

# Install dependencies based on the preferred package manager
COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* ./
RUN \
  if [ -f yarn.lock ]; then yarn --frozen-lockfile; \
  elif [ -f package-lock.json ]; then npm ci; \
  elif [ -f pnpm-lock.yaml ]; then yarn global add pnpm && pnpm i --frozen-lockfile; \
  else echo "Lockfile not found." && exit 1; \
  fi

# Rebuild the source code only when needed
FROM base AS builder
# expose buildkit target arch
ARG TARGETARCH
ARG YTDLP_VERSION=2025.11.12

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Install minimal tools for fetching and compressing yt-dlp, and for building
RUN apk add --no-cache --virtual .build-deps curl ca-certificates upx bash && \
    update-ca-certificates

# Download yt-dlp musl binary (choose asset by build target arch), avoid zipimport assets, compress with upx
RUN set -eux; \
    release_api="https://api.github.com/repos/yt-dlp/yt-dlp/releases/tags/${YTDLP_VERSION}"; \
    arch="$(echo "${TARGETARCH:-$(uname -m)}" | tr '[:upper:]' '[:lower:]')"; \
    if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then \
      token="yt-dlp_musllinux_aarch64"; \
    else \
      token="yt-dlp_musllinux"; \
    fi; \
    # extract URLs reliably with awk (field 4 is the URL in "browser_download_url": "..." lines)
    url="$(curl -fsSL "$release_api" | awk -F'\"' '/browser_download_url/ {print $4}' | grep -i "$token" | grep -v '\.zip$' | head -n1)"; \
    if [ -z "$url" ]; then \
      url="$(curl -fsSL "$release_api" | awk -F'\"' '/browser_download_url/ {print $4}' | grep -v '\.zip$' | head -n1)"; \
    fi; \
    if [ -z "$url" ]; then echo "Could not find yt-dlp asset for ${YTDLP_VERSION} (arch=${arch})"; exit 1; fi; \
    echo "Downloading yt-dlp from: ${url}"; \
    curl -fsSL "${url}" -o /app/yt-dlp && chmod a+rx /app/yt-dlp && upx --best --lzma /app/yt-dlp || true; \
    ls -lh /app/yt-dlp

# Build the Next.js app (standalone)
ENV NEXT_TELEMETRY_DISABLED=1
RUN npx update-browserslist-db@latest && npm run build

# --- NEW: clean builder /app, keep only standalone/static/public/yt-dlp to minimize final image ---
RUN set -eux; \
    mkdir -p /tmp/clean/.next/static; \
    # prefer standalone output (Next.js standalone build layout); fallback to copying .next if standalone missing
    if [ -d /app/.next/standalone ]; then \
      mv /app/.next/standalone /tmp/clean/; \
    fi; \
    # copy static and public if present
    mv /app/.next/static /tmp/clean/.next 2>/dev/null || true; \
    mv /app/public /tmp/clean/ 2>/dev/null || true; \
    # copy compressed yt-dlp if present
    if [ -f /app/yt-dlp ]; then mv /app/yt-dlp /tmp/clean/; fi; \
    [ -f /tmp/clean/yt-dlp ] && chmod a+rx /tmp/clean/yt-dlp || true; \
    # remove everything at /app root and move cleaned artifacts back
    rm /app/* -rf; \
    mv /tmp/clean/* /app/ || true; rmdir /tmp/clean || true; \
    echo "Remaining /app contents:"; ls -al /app

# Production image, copy all the files and run next
FROM base AS runner
WORKDIR /app

ENV NODE_ENV=production

# Create group/user using build-time args (use defaults if not provided)
ARG UID=1001
ARG GID=1001

# Copy entire /app from builder in one go (includes yt-dlp in /app/yt-dlp and built standalone app)
COPY --from=builder --chown=nextjs:nodejs /app /app

RUN apk add --no-cache ffmpeg && \
    addgroup --system --gid ${GID} nodejs && \
    adduser --system --uid ${UID} --ingroup nodejs nextjs && \
    chmod a+rx /app/yt-dlp || true && \
    ln -sf /app/yt-dlp /usr/local/bin/yt-dlp

# Make sure yt-dlp is executable and on PATH
ENV PATH=/app:${PATH}

USER nextjs

EXPOSE 3000

ENV PORT=3000
ENV HOSTNAME=0.0.0.0

CMD ["node", "server.js"]
