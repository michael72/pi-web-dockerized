# Use Debian slim as lightweight Linux base
# Note: We only install Docker CLI to use host's Docker daemon via mounted socket
FROM debian:bookworm-slim

# Parameterize tool versions for easier updates
ARG NVM_VERSION=v0.40.1
ENV JAVA_VERSION=21.0.11-tem \
    JAVA_HOME=/opt/java/openjdk \
    PATH="/opt/java/openjdk/bin:$PATH"

# Install base dependencies and useful CLI tools for coding agents
# build-essential is needed by pi-web's native node-pty module
RUN apt-get update && apt-get install -y \
    git \
    curl \
    bash \
    ca-certificates \
    sudo \
    zip \
    unzip \
    wget \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    build-essential \
    ripgrep \
    fd-find \
    jq \
    tree \
    less \
    procps \
    tmux \
    lsof \
    tzdata \
    p11-kit \
    fontconfig \
    locales \
    binutils \
    bc \
    tini \
    xz-utils \
    bzip2 \
    graphviz \
    xxd \
    && rm -rf /var/lib/apt/lists/*
# graphviz and xxd needed by plantuml

RUN update-locale

# Install Docker CLI only (uses host Docker daemon via mounted socket)
# We don't need docker-ce (daemon) or containerd.io since we use the host's Docker
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user
# Note: Docker socket group membership is handled dynamically in entrypoint.sh
# based on the host's actual Docker socket GID
RUN useradd -m -s /bin/bash -u 1000 coder && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install SDKMAN and Java as coder user
USER coder
WORKDIR /home/coder
RUN curl -s "https://get.sdkman.io" | bash && \
    bash -c "source /home/coder/.sdkman/bin/sdkman-init.sh && \
    sdk install java ${JAVA_VERSION} && \
    sdk default java ${JAVA_VERSION} && \
    sdk install sbt && \
    sdk install scala 2.13.18"

# Install NVM and Node.js LTS as coder user
# Pi and pi-web require Node.js >= 22.19
ENV NVM_DIR="/home/coder/.nvm"
RUN curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash && \
    bash -c "source $NVM_DIR/nvm.sh && \
    nvm install --lts && \
    nvm alias default node && \
    nvm use default && \
    ln -sf \$(dirname \$(which node)) $NVM_DIR/default"

# Install uv (Python package manager) as coder user
# See: https://docs.astral.sh/uv/getting-started/installation/
ENV UV_PROJECT_ENVIRONMENT=/home/coder/.venv
ENV LOCAL_BIN=/home/coder/.local/bin
ENV PATH="${UV_PROJECT_ENVIRONMENT}/bin:$LOCAL_BIN:$PATH"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN uv python install && \
    uv venv ${UV_PROJECT_ENVIRONMENT}
RUN uv pip install pytest

# Install ast-grep for AST-aware code search/replace
# The npm package @ast-grep/cli provides the 'ast-grep' and 'sg' binaries
# See: https://ast-grep.github.io/
RUN bash -c "source $NVM_DIR/nvm.sh && npm install -g @ast-grep/cli"

# Add nvm, node, sdkman and uv to PATH
# Node.js is available via the NVM default symlink created above
ENV PATH="$NVM_DIR/default:/home/coder/.sdkman/candidates/java/current/bin:$PATH"
ENV JAVA_HOME="/home/coder/.sdkman/candidates/java/current"

# install pumlsrv-server + pumlcli for plantuml diagram handling
ENV PUMLSRV_PORT=8380
RUN curl -sSL https://raw.githubusercontent.com/michael72/pumlsrv/master/get.sh | bash

# Pi is updated by rebuilding the image, so the pi.dev version check is pointless
ENV PI_SKIP_VERSION_CHECK=1

# Everything below this ARG is refreshed by './pi-web-dockerized.sh update'
# (cache-busting rebuild); a regular 'build' reuses the layers above and below.
ARG PI_BUILD_TIME=0

# Install the Pi coding agent globally
# --ignore-scripts is what the Pi documentation recommends for global installs
# See: https://github.com/earendil-works/pi/tree/main/packages/coding-agent
RUN bash -c "source $NVM_DIR/nvm.sh && \
    npm install -g --ignore-scripts @earendil-works/pi-coding-agent"

# Install pi-web, the browser UI for Pi sessions (started by 'pi-web-dockerized.sh web').
# Scripts must run for node-pty, which compiles a native module.
# See: https://github.com/jmfederico/pi-web
RUN bash -c "source $NVM_DIR/nvm.sh && \
    npm install -g @jmfederico/pi-web --allow-scripts=node-pty"

# graphify builds the per-project knowledge graph that the graphify-pi package queries
# See: https://pypi.org/project/graphifyy/
RUN uv tool install graphifyy

# Switch back to root for entrypoint setup
USER root

# Create necessary directories with proper permissions
# ~/.pi/agent is bind-mounted from the host at runtime (see config-lib.sh)
RUN mkdir -p /home/coder/.pi/agent && \
    mkdir -p /home/coder/.config/pi-web && \
    mkdir -p /home/coder/.pi-web && \
    mkdir -p /home/coder/.gradle && \
    mkdir -p /home/coder/.npm && \
    mkdir -p /home/coder/.m2 && \
    chown -R coder:coder /home/coder

# Default working directory (overridden at runtime by --workdir)
WORKDIR /

# Copy entrypoint scripts
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY web-entry.sh /usr/local/bin/pi-web-run
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/pi-web-run

# Set the entrypoint (runs as root, then switches to coder)
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default command is to run pi
CMD ["pi"]
