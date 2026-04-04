#!/bin/bash
# Start ollama in the background (serves the fallback model)
ollama serve &
OLLAMA_PID=$!

# Wait for ollama to be ready
for i in $(seq 1 30); do
  curl -s http://localhost:11434/api/tags >/dev/null 2>&1 && break
  sleep 1
done

echo "openclaw: ollama ready (fallback model: qwen2.5-coder:7b)"

# Start openclaw gateway
exec openclaw gateway run
