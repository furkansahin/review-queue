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

# Do NOT create the dev user here. bay's own Dockerfile runs
#   groupadd --gid 1000 dev && useradd --uid 1000 --gid 1000 -m ...
# unconditionally, and it fails with exit 9 if the user already exists.
#
# So build the home directory and own it by the numeric ids bay will use. The
# later useradd then adopts it, and the toolchain is already the dev user's.
ARG USER_UID=1000
ARG USER_GID=1000
RUN mkdir -p /home/dev/.local/share/mise /home/dev/.local/bin /home/dev/.claude \
    && chown -R ${USER_UID}:${USER_GID} /home/dev
USER ${USER_UID}:${USER_GID}
WORKDIR /home/dev
ENV HOME=/home/dev

RUN curl -fsSL https://mise.run | sh
ENV PATH=/home/dev/.local/bin:/home/dev/.local/share/mise/shims:$PATH

# Precompiled, not built from source. ubicloud's mise.toml sets
# ruby.compile = true, which is what made each box spend minutes compiling
# Ruby. Here it is a one-time cost, and precompiled is enough for a dev box.
ENV MISE_RUBY_COMPILE=0
RUN mise use -g ruby@${RUBY} node@${NODE} go@${GO} victoria-metrics@${VICTORIA} \
    && mise install \
    && mise reshim

# Warm the caches. What can and cannot be baked is decided by the bind mount:
# bay mounts the worktree at /workspace at runtime, so anything written inside
# the repository is masked. Only paths OUTSIDE it survive.
#
#   gems       -> GEM_HOME under mise's ruby   -> survives, baked below
#   ~/.npm     -> npm's download cache         -> survives, baked below
#   node_modules, vendor/bundle, built CSS     -> inside the repo, masked
#
# So `bundle install` and `npm ci` still run in the box, but resolve from local
# caches instead of fetching 203 gems and the npm tree over the network.
ARG RAW=https://raw.githubusercontent.com/ubicloud/ubicloud/main
RUN mkdir -p /tmp/warm && cd /tmp/warm \
    && curl -fsSL "$RAW/Gemfile" -o Gemfile \
    && curl -fsSL "$RAW/Gemfile.lock" -o Gemfile.lock \
    && mise exec -- bundle install --jobs 4 \
    && curl -fsSL "$RAW/package.json" -o package.json \
    && curl -fsSL "$RAW/package-lock.json" -o package-lock.json \
    && mise exec -- npm ci --prefer-offline --no-audit --no-fund \
    && rm -rf /tmp/warm

USER root
