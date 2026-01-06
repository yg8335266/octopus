  FROM alpine:3.20 AS version-fetcher

  RUN apk add --no-cache curl ca-certificates

  ARG UPSTREAM_REPO=bestruirui/octopus
  ARG GITHUB_TOKEN

  RUN set -eu; \
      URL="https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest"; \
      if [ -n "${GITHUB_TOKEN:-}" ]; then \
          BODY="$(curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GITHUB_TOKEN}"
  "${URL}" || true)"; \
      else \
          BODY="$(curl -fsSL -H "Accept: application/vnd.github+json" "${URL}" || true)"; \
      fi; \
      TAG="$(printf '%s' "${BODY}" | grep -m1 "\"tag_name\"" | cut -d '"' -f4)"; \
      if [ -z "${TAG}" ]; then TAG="dev"; fi; \
      printf '%s' "${TAG}" > /version_tag

  FROM node:20-alpine3.20 AS frontend-builder

  WORKDIR /build/web
  ENV NEXT_TELEMETRY_DISABLED=1

  ARG PNPM_VERSION=9.15.4
  RUN corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate

  COPY web/package.json web/pnpm-lock.yaml ./
  RUN pnpm install --frozen-lockfile

  COPY web/ ./
  COPY --from=version-fetcher /version_tag /tmp/version_tag

  RUN set -eu; \
      APP_VERSION="$(cat /tmp/version_tag)"; \
      NEXT_PUBLIC_APP_VERSION="${APP_VERSION}" pnpm run build

  FROM golang:1.24-alpine AS backend-builder

  WORKDIR /build

  COPY go.mod go.sum ./
  RUN go mod download

  COPY . .
  COPY --from=frontend-builder /build/web/out ./static/out
  COPY --from=version-fetcher /version_tag /tmp/version_tag

  ARG ZEABUR_GIT_COMMIT_SHA
  ARG TARGETOS
  ARG TARGETARCH

  RUN set -eu; \
      VERSION="$(cat /tmp/version_tag)"; \
      COMMIT="unknown"; \
      if [ -n "${ZEABUR_GIT_COMMIT_SHA:-}" ]; then COMMIT="$(printf '%s' "${ZEABUR_GIT_COMMIT_SHA}" | cut -c1-7)";
  fi; \
      BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
      GOOS="${TARGETOS:-linux}"; \
      GOARCH="${TARGETARCH:-$(go env GOARCH)}"; \
      CGO_ENABLED=0 GOOS="${GOOS}" GOARCH="${GOARCH}" go build \
        -buildvcs=false \
        -trimpath \
        -tags=jsoniter \
        -ldflags="-s -w -X github.com/bestruirui/octopus/internal/conf.Version=${VERSION} -X
  github.com/bestruirui/octopus/internal/conf.Commit=${COMMIT} -X
  github.com/bestruirui/octopus/internal/conf.BuildTime=${BUILD_TIME} -X
  github.com/bestruirui/octopus/internal/conf.Author=bestrui" \
        -o /out/octopus .

  FROM alpine:3.20

  ENV TZ=Asia/Shanghai

  WORKDIR /app

  RUN apk add --no-cache ca-certificates tzdata && \
      addgroup -S app && adduser -S -G app app && \
      mkdir -p /app/data && \
      chown -R app:app /app

  COPY --from=backend-builder /out/octopus /app/octopus

  USER app

  EXPOSE 8080

  VOLUME ["/app/data"]

  CMD ["./octopus", "start"]
