FROM ghcr.io/openclaw/openclaw:latest

USER root
RUN mkdir -p /home/node/.openclaw && chown node:node /home/node/.openclaw
COPY openclaw.json /home/node/.openclaw/openclaw.json
RUN chown node:node /home/node/.openclaw/openclaw.json
USER node

# Skills are deployed to /var/lib/dd/shared/skills by the host.
# OpenClaw reads DD_SKILLS_DIR env var to find them.

EXPOSE 18789
CMD ["openclaw", "gateway", "run"]
