FROM node:22-slim

RUN npm install -g @anthropic-ai/claude-code

# Claude Code uses ANTHROPIC_API_KEY or OPENROUTER_API_KEY at runtime
ENV TERM=xterm-256color

ENTRYPOINT ["claude"]
