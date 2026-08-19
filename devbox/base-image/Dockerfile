# A prebaked base image for bay boxes.
#
# Why: bay's own Dockerfile takes ARG BASE_IMAGE and leaves the toolchain to
# mise and post-create.sh, which run inside EVERY fresh container. Measured on a
# 2-vcpu Ubicloud VM, that cost about 330s per box, and a warm machine saved
# nothing. Baking the toolchain and the gems here moves that work to image build
# time, where it happens once.
#
#   build:  docker build -t ubicloud-bay-base:latest \
#             --build-arg RUBY=4.0.5 --build-arg NODE=24.12.0 --build-arg GO=1.24.0 .
#   use:    bay.toml -> [box] baseImage = "ubicloud-bay-base:latest"
#
# Rebuild it when mise.toml or Gemfile.lock move. A stale bundle is not a
# problem: bundle install then only fetches the difference.
FROM debian:trixie-slim

ARG RUBY=4.0.5
ARG NODE=24.12.0
ARG GO=1.24.0
ARG VICTORIA=v1.148.0
ENV DEBIAN_FRONTEND=noninteractive

# What bay's Dockerfile installs, plus what Clover's native gems need. Keeping
# these here means bay's layer finds them already satisfied.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git gnupg locales nano \
      openssh-server procps ripgrep sudo tmux tzdata unzip \
      libffi-dev libyaml-dev libssl-dev zlib1g-dev \
      libpq-dev libreadline-dev libncurses-dev libgdbm-dev \
      postgresql-client psmisc \
    && rm -rf /var/lib/apt/lists/*

# bay runs the box as "dev"; the toolchain must belong to that user or mise
# reinstalls it.
RUN useradd -m -s /bin/bash dev
USER dev
WORKDIR /home/dev

RUN curl -fsSL https://mise.run | sh
ENV PATH=/home/dev/.local/bin:/home/dev/.local/share/mise/shims:$PATH

# Precompiled, not built from source. ubicloud's mise.toml sets
# ruby.compile = true, which is what made each box spend minutes compiling
# Ruby. Here it is a one-time cost, and precompiled is enough for a dev box.
ENV MISE_RUBY_COMPILE=0
RUN mise use -g ruby@${RUBY} node@${NODE} go@${GO} victoria-metrics@${VICTORIA} \
    && mise install \
    && mise reshim

# Warm the gem cache from the current lockfile. The worktree is bind-mounted at
# runtime, so this only pre-populates GEM_HOME; bundler then resolves in seconds
# instead of installing 203 gems.
ARG GEMFILE_URL=https://raw.githubusercontent.com/ubicloud/ubicloud/main/Gemfile
ARG LOCK_URL=https://raw.githubusercontent.com/ubicloud/ubicloud/main/Gemfile.lock
RUN mkdir -p /tmp/warm && cd /tmp/warm \
    && curl -fsSL "$GEMFILE_URL" -o Gemfile \
    && curl -fsSL "$LOCK_URL" -o Gemfile.lock \
    && mise exec -- bundle config set --local without 'development' \
    && mise exec -- bundle install --jobs 4 || true \
    && rm -rf /tmp/warm

USER root
