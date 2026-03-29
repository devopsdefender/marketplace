FROM ghcr.io/openclaw/openclaw:latest

# Pre-bake config for LAN binding (required for Cloudflare tunnel access)
USER root
RUN mkdir -p /home/node/.openclaw && chown node:node /home/node/.openclaw
COPY openclaw.json /home/node/.openclaw/openclaw.json
RUN chown node:node /home/node/.openclaw/openclaw.json
USER node
