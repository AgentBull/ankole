FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG USERNAME=vscode

COPY tools/devkit/scripts/env-setup.sh /tmp/ankole-env-setup.sh

RUN bash /tmp/ankole-env-setup.sh --no-docker --no-rust --no-elixir --no-bun \
  && rm -rf /var/lib/apt/lists/*

USER ${USERNAME}

RUN bash /tmp/ankole-env-setup.sh --no-system-packages --no-docker

USER root

RUN rm -f /tmp/ankole-env-setup.sh

USER ${USERNAME}
