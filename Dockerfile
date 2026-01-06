# Stage 0: Fetch upstream version tag (no .git available on Zeabur)
FROM alpine:3.20 AS version-fetcher

RUN apk add --no-cache curl

# Copy and execute version fetch script
COPY scripts/fetch-version.sh /fetch-version.sh
RUN chmod +x /fetch-version.sh && /fetch-version.sh > /version_tag

# Stage 1: Build frontend
FROM node:20-alpine AS frontend-builder

WORKDIR /build/web
ENV NEXT_TELEMETRY_DISABLED=1

RUN corepack enable && corepack prepare pnpm@latest --activate

# Copy package files first for better layer caching
COPY web/package.json web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

# Copy rest of frontend source
COPY web/ ./
COPY --from=version-fetcher /version_tag /tmp/version_tag

# Build with version from GitHub API
RUN APP_VERSION=$(cat /tmp/version_tag) && \
    NEXT_PUBLIC_APP_VERSION="${APP_VERSION}" pnpm run build

# Stage 2: Build backend
FROM golang:1.24-alpine AS backend-builder

WORKDIR /build

# Copy go mod files first for better layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Copy frontend build output
COPY --from=frontend-builder /build/web/out ./static/out

# Copy version tag
COPY --from=version-fetcher /version_tag /tmp/version_tag

# Zeabur provides commit SHA during build
ARG ZEABUR_GIT_COMMIT_SHA

# Build binary with version info
RUN VERSION=$(cat /tmp/version_tag) && \
    COMMIT="unknown" && \
    if [ -n "${ZEABUR_GIT_COMMIT_SHA:-}" ]; then COMMIT=$(echo "${ZEABUR_GIT_COMMIT_SHA}" | cut -c1-7); fi && \
    BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) && \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -tags=jsoniter \
      -ldflags="-s -w \
        -X github.com/bestruirui/octopus/internal/conf.Version=${VERSION} \
        -X github.com/bestruirui/octopus/internal/conf.Commit=${COMMIT} \
        -X github.com/bestruirui/octopus/internal/conf.BuildTime=${BUILD_TIME} \
        -X github.com/bestruirui/octopus/internal/conf.Author=bestrui" \
      -o /octopus .

# Stage 3: Runtime
FROM alpine:3.20

ENV TZ=Asia/Shanghai

WORKDIR /app

RUN apk add --no-cache ca-certificates tzdata && \
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone && \
    mkdir -p /app/data

COPY --from=backend-builder /octopus /app/octopus

RUN chmod +x /app/octopus

EXPOSE 8080

VOLUME ["/app/data"]

CMD ["./octopus", "start"]
