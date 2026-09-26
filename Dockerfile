FROM node:22-bookworm-slim

ARG RUNNER_VERSION=2.328.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gosu \
        jq \
        libicu72 \
        tar \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN npm install --global n

RUN useradd --create-home --home-dir /home/runner --shell /bin/bash runner

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "${arch}" in \
        amd64) runner_arch="x64" ;; \
        arm64) runner_arch="arm64" ;; \
        *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /home/runner/actions-runner; \
    curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz" \
      | tar -xz -C /home/runner/actions-runner; \
    /home/runner/actions-runner/bin/installdependencies.sh; \
    chown -R runner:runner /home/runner

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
