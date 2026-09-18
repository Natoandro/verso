# syntax=docker/dockerfile:1

FROM node:22-bookworm-slim AS frontend-dependencies

WORKDIR /src/web-editor

COPY web-editor/package.json web-editor/pnpm-lock.yaml ./
RUN corepack enable \
    && corepack install --global pnpm@10.34.1 \
    && printf 'allowBuilds:\n  esbuild: true\n' > pnpm-workspace.yaml \
    && pnpm install --frozen-lockfile

FROM node:22-bookworm-slim AS builder

ARG TARGETARCH
ARG ZIG_VERSION=0.16.0

RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates curl git unzip xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && case "${TARGETARCH}" in \
        amd64) zig_arch=x86_64 ;; \
        arm64) zig_arch=aarch64 ;; \
        *) echo "Unsupported Docker architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl --fail --silent --show-error --location \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
        --output /tmp/zig.tar.xz \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && ln -s "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}" /opt/zig \
    && rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

WORKDIR /src

COPY --from=frontend-dependencies /src/web-editor/node_modules ./web-editor/node_modules
COPY . .

RUN mkdir --parents /src/zig-pkg
# Seed the SQLite wrapper's pinned nested archive dependency for clean builds.
RUN mkdir --parents /src/zig-pkg/N-V-__8AAH-mpwB7g3MnqYU-ooUBF1t99RP27dZ9addtMVXD /tmp/sqlite-amalgamation \
    && curl --fail --silent --show-error --location \
        https://www.sqlite.org/2025/sqlite-amalgamation-3490200.zip \
        --output /tmp/sqlite-amalgamation.zip \
    && unzip -q /tmp/sqlite-amalgamation.zip -d /tmp/sqlite-amalgamation \
    && cp /tmp/sqlite-amalgamation/sqlite-amalgamation-3490200/* \
        /src/zig-pkg/N-V-__8AAH-mpwB7g3MnqYU-ooUBF1t99RP27dZ9addtMVXD/ \
    && rm -rf /tmp/sqlite-amalgamation /tmp/sqlite-amalgamation.zip
RUN zig build -Doptimize=ReleaseSafe -Dstrip=true

FROM debian:bookworm-slim AS runtime

RUN groupadd --system --gid 10001 verso \
    && useradd --system --uid 10001 --gid verso --home-dir /app --no-create-home verso \
    && mkdir --parents /app/data \
    && chown --recursive verso:verso /app

WORKDIR /app

COPY --from=builder /src/zig-out/bin/verso /usr/local/bin/verso
COPY --from=builder /src/zig-out/migrations /app/migrations

ENV VERSO_RUNTIME_ENVIRONMENT=development \
    VERSO_SERVER_HOST=0.0.0.0 \
    VERSO_SERVER_PORT=8080 \
    VERSO_SITE_BASE_URL=http://localhost:8080 \
    VERSO_DATABASE_URL=./data/verso.db \
    VERSO_STORAGE_FS_PATH=./data/assets \
    VERSO_CACHE_PATH=./data/cache

EXPOSE 8080
VOLUME ["/app/data"]

USER verso
ENTRYPOINT ["verso"]
CMD ["serve"]
