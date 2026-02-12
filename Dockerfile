# Stage 1: Build
ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.3.1
ARG DEBIAN_VERSION=bookworm-20260202-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS build

# Install build dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

# Install Node.js 24 for asset compilation
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config

# Copy compile-time config before compiling deps
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# Install npm dependencies for assets
COPY assets/package.json assets/package-lock.json ./assets/
RUN npm ci --prefix assets

# Copy application code
COPY priv priv
COPY lib lib
COPY assets assets

# Install esbuild and tailwind (runtime: :dev, so not in prod deps)
RUN mix assets.setup

# Compile the application
RUN mix compile

# Build assets
RUN mix assets.deploy

# Copy runtime config and release overlays
COPY config/runtime.exs config/
COPY rel rel

# Build the release
RUN mix release

# Stage 2: Runtime
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Create a non-root user
RUN groupadd --system app && useradd --system --gid app app

# Copy the release from the build stage
COPY --from=build --chown=app:app /app/_build/prod/rel/liteskill ./

USER app

EXPOSE 4000

CMD ["bin/server"]
