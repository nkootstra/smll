FROM ubuntu:24.04

ARG RTK_REF=v0.42.3
ARG ZIG_VERSION=0.16.0
ARG TIKTOKEN_VERSION=0.13.0
ARG RUST_VERSION=1.96.0

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/root/.cargo/bin:/opt/bench-venv/bin:/usr/local/bin:/usr/bin:/bin"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        libssl-dev \
        pkg-config \
        python3 \
        python3-venv \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/bench-venv \
    && /opt/bench-venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/bench-venv/bin/pip install --no-cache-dir "tiktoken==${TIKTOKEN_VERSION}"

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) zig_arch="x86_64" ;; \
        arm64) zig_arch="aarch64" ;; \
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    tar -C /opt -xf /tmp/zig.tar.xz; \
    ln -s "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz; \
    zig version

RUN curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain "${RUST_VERSION}" \
    && rm /tmp/rustup-init.sh \
    && rustc --version \
    && cargo --version

RUN git clone https://github.com/rtk-ai/rtk.git /opt/rtk-src \
    && cd /opt/rtk-src \
    && git checkout --detach "$RTK_REF" \
    && cargo build --release --locked \
    && mkdir -p /opt/rtk \
    && cp target/release/rtk /opt/rtk/rtk \
    && /opt/rtk/rtk --version

RUN mkdir -p /opt/tiktoken-cache \
    && TIKTOKEN_CACHE_DIR=/opt/tiktoken-cache python3 - <<'PY'
import tiktoken

for encoding in ("o200k_base", "cl100k_base"):
    tiktoken.get_encoding(encoding)
PY

ENV TIKTOKEN_CACHE_DIR=/opt/tiktoken-cache

WORKDIR /tmp
