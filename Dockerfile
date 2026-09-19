# syntax=docker/dockerfile:1
#
# Multi-stage build: compile an Elixir release, then copy it onto slim Debian.
#   docker build -t arc .

ARG ELIXIR_IMAGE=elixir:1.18.4-otp-27-slim
ARG RUNNER_IMAGE=debian:bookworm-slim

FROM ${ELIXIR_IMAGE} AS build

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
RUN mix assets.setup && mix compile && mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8 MIX_ENV=prod

WORKDIR /app
RUN useradd --system --home /app arc && chown arc /app
COPY --from=build --chown=arc:root /app/_build/prod/rel/arc ./
USER arc

EXPOSE 4000
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s CMD curl -fs http://127.0.0.1:${PORT:-4000}/health/ready || exit 1

CMD ["/app/bin/entrypoint"]
