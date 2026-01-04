# Multi-stage Dockerfile for Octopus
# https://github.com/bestruirui/octopus

# Stage 1: Build Frontend
FROM node:20-alpine AS frontend-builder

WORKDIR /build

RUN corepack enable && corepack prepare pnpm@latest --activate

COPY web/package.json web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY web/ ./
RUN pnpm build

# Stage 2: Build Backend
FROM golang:1.24-alpine AS backend-builder

WORKDIR /build

RUN apk add --no-cache git

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN rm -rf ./static/out
COPY --from=frontend-builder /build/out ./static/out

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o octopus .

# Stage 3: Runtime
FROM alpine:latest

ENV TZ=Asia/Shanghai

RUN apk add --no-cache ca-certificates tzdata su-exec && \
    cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone && \
    mkdir -p /app/data

WORKDIR /app

COPY --from=backend-builder /build/octopus /app/octopus

RUN chmod +x /app/octopus

EXPOSE 8080

VOLUME ["/app/data"]

CMD ["./octopus", "start"]
