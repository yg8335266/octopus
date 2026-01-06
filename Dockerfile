  # Stage 0: Fetch upstream version tag (no .git available on Zeabur)
  FROM alpine:latest AS version-fetcher

  RUN apk add --no-cache curl

  # Upstream repo to read release tag from (owner/name)
  ARG UPSTREAM_REPO=bestruirui/octopus

  # Write the latest release tag to /version_tag (fallback to "dev" if unavailable)
  RUN set -eux; \
      TAG="$(curl -fsSL "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" | sed -n
  's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"; \
      if [ -z "${TAG}" ]; then TAG="dev"; fi; \
      printf '%s' "${TAG}" > /version_tag

  # Stage 1: Build frontend
  FROM node:20-alpine AS frontend-builder

  WORKDIR /build

  # Install pnpm
  RUN corepack enable && corepack prepare pnpm@latest --activate

  # Copy entire project
  COPY . .

  WORKDIR /build/web

  # Copy upstream version tag
  COPY --from=version-fetcher /version_tag /tmp/version_tag

  # Install dependencies
  RUN pnpm install --frozen-lockfile

  # Get version from upstream GitHub release tag and build
  RUN set -eux; \
      APP_VERSION="$(cat /tmp/version_tag)"; \
      NEXT_PUBLIC_APP_VERSION="${APP_VERSION}" pnpm run build

  # Stage 2: Build backend
  FROM golang:1.24-alpine AS backend-builder

  WORKDIR /build

  # Copy entire project (no .git available on Zeabur)
  COPY . .

  # Download dependencies
  RUN go mod download

  # Copy frontend build output
  COPY --from=frontend-builder /build/web/out ./static/out

  # Copy upstream version tag
  COPY --from=version-fetcher /version_tag /tmp/version_tag

  # Zeabur provides commit SHA during build
  ARG ZEABUR_GIT_COMMIT_SHA

  # Build binary with version info from upstream tag + Zeabur commit SHA
  RUN set -eux; \
      GIT_VERSION="$(cat /tmp/version_tag)"; \
      GIT_COMMIT="unknown"; \
      if [ -n "${ZEABUR_GIT_COMMIT_SHA:-}" ]; then GIT_COMMIT="$(printf '%s' "${ZEABUR_GIT_COMMIT_SHA}" | cut
  -c1-7)"; fi; \
      BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
      CGO_ENABLED=0 GOOS=linux go build \
      -ldflags="-X 'github.com/bestruirui/octopus/internal/conf.Version=${GIT_VERSION}' \
                -X 'github.com/bestruirui/octopus/internal/conf.Commit=${GIT_COMMIT}' \
                -X 'github.com/bestruirui/octopus/internal/conf.BuildTime=${BUILD_TIME}' \
                -X 'github.com/bestruirui/octopus/internal/conf.Author=bestrui' \
                -s -w" \
      -tags=jsoniter \
      -o octopus .

  # Stage 3: Runtime
  FROM alpine:latest

  ENV TZ=Asia/Shanghai

  RUN apk add --no-cache ca-certificates tzdata && \
      cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
      echo "Asia/Shanghai" > /etc/timezone && \
      mkdir -p /app/data

  WORKDIR /app

  COPY --from=backend-builder /build/octopus /app/octopus

  RUN chmod +x /app/octopus

  EXPOSE 8080

  VOLUME ["/app/data"]

  CMD ["./octopus", "start"]
