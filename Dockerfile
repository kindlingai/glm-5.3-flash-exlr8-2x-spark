# GLM-5.3-Flash on two GB10 boxes: gr8 (the gr8/ submodule) with only the engine this recipe runs, g6m4_flash-int4 at
# TP=2, plus the front end, the loader and the launcher. linux/arm64, CUDA 13, sm_121a. Both boxes run this image.
#
#   docker buildx build --platform linux/arm64 -t glm53f-2x-spark .      (compose.yaml builds it the same way)
#
# The stages are gr8's own Dockerfile cut down to one engine: gr8's builds every engine for every TP width, which takes
# far longer. Keep the two in step when the submodule moves (toolchain, Rust pin, XGrammar, runtime packages).
ARG CUDA_VERSION=13.0.1
ARG UBUNTU=ubuntu24.04

FROM nvidia/cuda:${CUDA_VERSION}-devel-${UBUNTU} AS toolchain
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends g++ binutils libibverbs-dev ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

FROM toolchain AS rust
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# gr8/frontend/g6front-rs/rust-toolchain.toml pins the compiler: keep RUST_VERSION equal to it
ARG RUST_VERSION=1.94.1
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION"
WORKDIR /src

FROM rust AS libs
COPY gr8/engine/knobs-rs engine/knobs-rs
COPY gr8/knobs knobs
COPY gr8/engine/loader-rs engine/loader-rs
COPY gr8/engine/Cargo.toml gr8/engine/Cargo.lock engine/
COPY gr8/engine/hostcore-rs engine/hostcore-rs
COPY gr8/engine/kvman-rs engine/kvman-rs
COPY gr8/engine/scheduler-rs engine/scheduler-rs
RUN mkdir -p /out \
 && cargo build --release --locked --manifest-path engine/loader-rs/Cargo.toml \
 && cargo build --release --locked --manifest-path engine/Cargo.toml \
 && cargo build --release --locked --features capi --manifest-path engine/knobs-rs/Cargo.toml \
 && cargo rustc --release --locked --features capi --lib --crate-type cdylib --manifest-path engine/knobs-rs/Cargo.toml \
 && cp engine/loader-rs/target/release/libg6load.a engine/loader-rs/target/release/g6load \
       engine/target/release/libg6host.a engine/target/release/kvman-remote \
       engine/knobs-rs/target/release/libgr8knobs.a engine/knobs-rs/target/release/libgr8knobs.so /out/ \
 && rm -rf engine/target engine/*/target

FROM rust AS front
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends cmake clang libclang-dev \
 && rm -rf /var/lib/apt/lists/*
COPY gr8/engine/knobs-rs engine/knobs-rs
COPY gr8/knobs knobs
COPY gr8/frontend/g6front-rs frontend/g6front-rs
WORKDIR /src/frontend/g6front-rs
RUN mkdir -p /out \
 && cargo build --release --locked \
 && cp target/release/g6front-rs /out/ \
 && rm -rf target \
 && cp -a "$(ls -d /opt/cargo/registry/src/*/xgrammar-*/thirdparty/xgrammar | head -1)" /out-xgrammar

# XGrammar, for the engine's request grammars (gr8/engine/runtime/grammar.h): the sources the front end's crate pins
FROM toolchain AS xgrammar
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends cmake \
 && rm -rf /var/lib/apt/lists/*
COPY gr8/engine/runtime/xgrammar_build.sh /xgrammar_build.sh
COPY --from=front /out-xgrammar /opt/xgrammar
RUN /xgrammar_build.sh /opt/xgrammar /xb && mkdir -p /out && cp /xb/libxgrammar.a /out/ && rm -rf /xb

# g6m4_flash-int4: GLM-5.3-Flash with the 4-bit KV latent row, TP=2 only
FROM toolchain AS engine
WORKDIR /src
COPY gr8/engine engine
COPY gr8/tools/health/gpuprobe.cu tools/health/gpuprobe.cu
COPY gr8/scripts/build.sh scripts/build.sh
COPY --from=libs /out/libg6load.a engine/loader-rs/target/release/libg6load.a
COPY --from=libs /out/libg6host.a engine/target/release/libg6host.a
COPY --from=libs /out/libgr8knobs.a engine/knobs-rs/target/release/libgr8knobs.a
COPY --from=front /out-xgrammar /opt/xgrammar
COPY --from=xgrammar /out/libxgrammar.a /opt/xgrammar-lib/libxgrammar.a
ENV GR8_XGRAMMAR=/opt/xgrammar GR8_XGRAMMAR_LIB=/opt/xgrammar-lib/libxgrammar.a
RUN MODEL=flash KV_FORMAT=int4 GR8_WIDTHS=2 scripts/build.sh /out/bin \
 && find /out/bin -mindepth 1 -maxdepth 1 ! -name g6m4_flash-int4 -exec rm -rf {} +

FROM nvidia/cuda:${CUDA_VERSION}-runtime-${UBUNTU} AS runtime
# python3 for the launcher and the shim (python3-yaml for the KV store file), curl + jq for the smoke test.
# libibverbs1 and ibverbs-providers (libmlx5) for the ConnectX fabric between the two boxes.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends libibverbs1 ibverbs-providers python3 python3-yaml curl jq \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/gr8
COPY gr8/ .
COPY --from=engine /out/bin/g6m4_flash-int4 bin/
COPY --from=libs /out/g6load /out/kvman-remote bin/
COPY --from=libs /out/libgr8knobs.so bin/lib/
COPY --from=front /out/g6front-rs bin/
COPY kv-store.yaml /etc/gr8/kv-store.yaml
COPY entrypoint.sh knobs.sh /opt/glm53f-2x/
COPY bin/gr8 /opt/glm53f-2x/bin/gr8
# The container runs as uid 1000 on a read-only image. Its writable state is three volumes (compose.yaml): the model
# cache, the prompt cache and GR8_WORK_DIR, which docker fills from these empty, uid-1000 directories on first use.
RUN mkdir -p /var/lib/gr8/home /var/lib/gr8/cache /var/lib/gr8/prompts \
 && chown 1000:1000 /var/lib/gr8/home /var/lib/gr8/cache /var/lib/gr8/prompts
ENV PATH=/opt/glm53f-2x/bin:/opt/gr8/bin:$PATH PYTHONPATH=/opt/gr8/frontend HOME=/tmp GR8_CONTAINER=1 GR8_MODEL=glm53f \
    GR8_WORK_DIR=/var/lib/gr8/home MODEL_CACHE=/var/lib/gr8/cache PY=/usr/bin/python3 FRONT_BIN=/opt/gr8/bin/g6front-rs
# The recipe's knobs (README.md, "Knobs"). Set any of them in .env, or with docker run -e, to override.
#   CAP            the KV pool in tokens, shared by the sessions (about 5 KB of memory a token)
#   MAX_MODEL_LEN  the longest single request, prompt and output together
#   DFLASH         1: a request alone drafts with the DFlash2 drafter (fetched and converted on the first boot); 0: MTP only
#   MENTAT         0: the two boxes in PEERS; 1: find each other through mentat (knobs.sh)
ENV CAP=262208 MAX_MODEL_LEN=262144 DFLASH=1 MENTAT=0
# The rest of the recipe, as gr8's launcher options (gr8/KNOBS.md)
#   MODEL, DRAFTER: pinned to the Hugging Face commits measured here. The model cache is keyed by commit, so a new
#   commit on either repo (even a README edit) changes nothing until these move.
#   SESS:    four requests decode at once; a request alone drafts with DFlash2
#   VARIANT: the release's K4 width, about 78 GB of experts a box
# PEERS (and IPS, IPS2) have no default: they name the two boxes (knobs.sh, .env.example).
ENV TP=2 SESS=4 GROUP=gr8-glm53f-2x VARIANT=k4 KV_FORMAT=int4 FLASH_CACHE=aligned KV_STORE=@/etc/gr8/kv-store.yaml \
    MODEL=https://huggingface.co/kindlingai/glm-5.3-flash-exlr8-k2-k3-k4@867580abd28d142bb4c56218bb81a752b7dea988 \
    DRAFTER=https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2@bf582e4eacc1810f76656d1811693ff6c6737d2a
USER 1000:1000
ENTRYPOINT ["/opt/glm53f-2x/entrypoint.sh"]
