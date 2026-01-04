# Multi-stage Dockerfile for Octopus
# https://github.com/bestruirui/octopus

# Stage 1: Build Backend (first, to get version from git)
FROM golang:1.24-alpine AS backend-builder

WORKDIR /build

RUN apk add --no-cache git

COPY .git .git
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Get version from git tag
RUN VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "dev") && \
    echo "${VERSION}" > /tmp/version

# Remove placeholder and prepare for frontend
RUN rm -rf ./static/out && mkdir -p ./static/out

# Stage 2: Build Frontend
FROM node:20-alpine AS frontend-builder

WORKDIR /build/web

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY web/package.json web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY web/ ./
COPY --from=backend-builder /tmp/version /tmp/version

RUN VERSION=$(cat /tmp/version) && \
    NEXT_PUBLIC_APP_VERSION=${VERSION} pnpm build && ls -la out/

# Stage 3: Final Backend Build
FROM backend-builder AS final-builder

COPY --from=frontend-builder /build/web/out/ ./static/out/

# Verify frontend files
RUN ls -la ./static/out/ && test -f ./static/out/index.html

# Build with version info from git
RUN VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "dev") && \
    COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown") && \
    BUILD_TIME=$(date -u '+%Y-%m-%d %H:%M:%S') && \
    CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w \
    -X 'github.com/bestruirui/octopus/internal/conf.Version=${VERSION}' \
    -X 'github.com/bestruirui/octopus/internal/conf.Commit=${COMMIT}' \
    -X 'github.com/bestruirui/octopus/internal/conf.BuildTime=${BUILD_TIME}'" \
    -o octopus .

# Stage 4: Runtime
FROM alpine:latest

ENV TZ=Asia/Shanghai

RUN apk add --no-cache ca-certificates tzdata su-exec && \
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone && \
    mkdir -p /app/data

WORKDIR /app

COPY --from=final-builder /build/octopus /app/octopus

RUN chmod +x /app/octopus

EXPOSE 8080

VOLUME ["/app/data"]

CMD ["./octopus", "start"]
