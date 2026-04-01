FROM eclipse-temurin:21-jre-noble

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

ARG SIGNAL_CLI_VERSION=0.14.1
RUN curl -fsSL "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz" \
    | tar xz -C /opt \
    && ln -s /opt/signal-cli-*/bin/signal-cli /usr/local/bin/signal-cli

ENTRYPOINT ["signal-cli"]
