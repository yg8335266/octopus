# Stage 1: Build frontend
FROM node:20-alpine AS frontend-builder

WORKDIR /build

# Install pnpm
RUN corepack enable && corepack prepare pnpm@latest --activate

# Copy entire project
COPY . .

WORKDIR /build/web

# Install dependencies
RUN pnpm install --frozen-lockfile

# Build frontend
RUN pnpm run build

# Stage 2: Build backend
FROM golang:1.24-alpine AS backend-builder

WORKDIR /build

# Install git for version info
RUN apk add --no-cache git

# Copy entire project
COPY . .

# Download dependencies
RUN go mod download

# Copy frontend build output
COPY --from=frontend-builder /build/web/out ./static/out

# Build binary with version info
RUN GIT_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "dev") && \
    GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown") && \
    BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) && \
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
