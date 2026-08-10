# syntax=docker/dockerfile:1
# opencode + agent-box tooling, baked into one image.
#
# The upstream opencode image is Alpine + the opencode binary only (no node,
# no git, no kubelogin). The MCP servers (kubernetes, ssh-manager, artifacthub)
# need node/npx; the workspace needs git/ssh; kubernetes MCP needs kubelogin.
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
FROM ghcr.io/anomalyco/opencode:1.0.196

ARG TARGETARCH

# node/npm for MCP servers, git/ssh/curl for the workspace
RUN apk add --no-cache nodejs npm git openssh-client curl

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

# upstream ENTRYPOINT is ["opencode"]; keep it
