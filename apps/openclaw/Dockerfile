FROM ghcr.io/openclaw/openclaw:latest

USER root

# Install ollama
RUN curl -fsSL https://ollama.com/install.sh | sh

# Pull the fallback model during build (ollama needs its server running)
RUN ollama serve & \
    sleep 3 && \
    ollama pull qwen2.5-coder:7b && \
    kill %1 2>/dev/null || true

# Configure openclaw
RUN mkdir -p /home/node/.openclaw && chown -R node:node /home/node/.openclaw
COPY openclaw.json /home/node/.openclaw/openclaw.json
RUN chown node:node /home/node/.openclaw/openclaw.json

# Entrypoint starts ollama in background, then openclaw
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER node
EXPOSE 18789
CMD ["/usr/local/bin/entrypoint.sh"]
