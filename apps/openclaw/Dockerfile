FROM ghcr.io/openclaw/openclaw:latest

USER root
RUN mkdir -p /home/node/.openclaw && chown node:node /home/node/.openclaw
COPY openclaw.json /home/node/.openclaw/openclaw.json
RUN chown node:node /home/node/.openclaw/openclaw.json
USER node

EXPOSE 18789
CMD ["openclaw", "gateway", "run"]
