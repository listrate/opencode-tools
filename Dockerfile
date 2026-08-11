# syntax=docker/dockerfile:1
# opencode + agent-box tooling, baked into one image.
#
# The upstream opencode image is Alpine + the opencode binary only (no node,
# no git, no kubelogin). The MCP servers (kubernetes, ssh-manager, artifacthub)
# need node/npx; the workspace needs git/ssh; kubernetes MCP needs kubelogin.
#
# The entrypoint runs BOTH `opencode serve` (HTTP API) and an ACP listener
# over TCP (socat bridging stdio -> TCP, since `opencode acp` is stdio-only).
#
# No secrets, no credentials, no private info are baked in. Public sources
# only. Runtime secrets are injected separately at deploy time.

# Stage 1: build artifacthub-mcp (stdio MCP server, source build — no docker
# needed at runtime)
FROM node:22-alpine AS artifacthub-builder
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 https://github.com/alexw00/artifacthub-mcp . \
    && npm ci \
    && npm run build

# Stage 2: opencode + tools
FROM ghcr.io/anomalyco/opencode:1.18.16

ARG TARGETARCH

# node/npm for MCP servers, git/ssh/curl for the workspace, socat for the
# stdio->TCP bridge that exposes `opencode acp` over the network
RUN apk add --no-cache nodejs npm git openssh-client curl socat

# kubelogin (OIDC exec plugin for the kubernetes MCP) + kubectl client
RUN ARCH=${TARGETARCH:-amd64} \
    && curl -fsSL -o /tmp/kubelogin.zip \
         https://github.com/int128/kubelogin/releases/download/v1.34.0/kubelogin_linux_${ARCH}.zip \
    && unzip -o /tmp/kubelogin.zip -d /usr/local/bin \
    && rm /tmp/kubelogin.zip \
    && curl -fsSL -o /usr/local/bin/kubectl \
         https://dl.k8s.io/release/v1.36.3/bin/linux/${ARCH}/kubectl \
    && chmod +x /usr/local/bin/kubectl

# artifacthub-mcp (stdio, from source build above)
COPY --from=artifacthub-builder /src/dist /usr/local/share/artifacthub-mcp/dist

# mise (polyglot runtime/tool version manager) — Alpine is musl, so use the
# musl static binary from the official release tarball. The tarball nests the
# binary under mise/bin/, so extract then move both `mise` and its `mise.d`
# companion into /usr/local/bin.
ARG MISE_VERSION=v2026.8.4
RUN ARCH=${TARGETARCH:-amd64} \
    && MISE_ARCH=$( [ "$ARCH" = "amd64" ] && echo x64 || echo arm64 ) \
    && curl -fsSL -o /tmp/mise.tar.gz \
         https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${MISE_ARCH}-musl.tar.gz \
    && tar -xzf /tmp/mise.tar.gz -C /tmp \
    && mv /tmp/mise/bin/mise /tmp/mise/bin/mise.d /usr/local/bin/ \
    && rm -rf /tmp/mise /tmp/mise.tar.gz \
    && mise --version

# entrypoint: runs `opencode serve` + the ACP-over-TCP listener (see entrypoint.sh)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
