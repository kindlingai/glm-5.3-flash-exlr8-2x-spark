# GLM-5.3-Flash on two GB10 boxes: gr8 (the gr8/ submodule) with only the engine this recipe runs, g6m4_flash-int4 at
# TP=2, plus the front end, the loader and the launcher. linux/arm64, CUDA 13, sm_121a. Both boxes run this image.
#
#   docker buildx build --platform linux/arm64 -t glm53f-2x-spark .      (compose.yaml builds it the same way)
#
# The stages are gr8's own Dockerfile cut down to one engine: gr8's builds every engine for every TP width, which takes
# far longer. Keep the two in step when the submodule moves (toolchain, Rust pin, XGrammar, runtime packages).
#
# ENGINE_SRC says where the binaries come from:
#   build  (the default) the stages below compile them from the gr8/ submodule
#   image  they are copied from GR8_IMAGE, gr8's published image of the same commit (ghcr.io/kindlingai/gr8@sha256:...),
#          and nothing compiles. Its g6m4_flash-int4 runs TP widths 1 to 4, with the same kernels at each width as a
#          one-width build. CI takes this path when gr8 publishes an image of the submodule's commit
#          (.github/workflows/image.yml)
# Either way the runtime stage gets the same files at the same paths, from the bins stage.
ARG CUDA_VERSION=13.0.1
ARG UBUNTU=ubuntu24.04
ARG ENGINE_SRC=build
# scratch stands in when ENGINE_SRC=build, which never reads it
ARG GR8_IMAGE=scratch

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
# The compile cache (gr8/docs/BUILD-CACHE.md) is a cache mount, which CI keeps between runs (image.yml), so a
# rebuild compiles only what changed. When gr8's nvcc_cache.sh sets an entry's time on a hit, the entries this build did
# not read are deleted after it, so the cache holds one build; an older gr8 keeps them all.
ENV GR8_NVCC_CACHE_DIR=/var/cache/gr8-nvcc
RUN --mount=type=cache,id=gr8-nvcc-flash-int4-w2,target=/var/cache/gr8-nvcc \
    touch "$GR8_NVCC_CACHE_DIR/.start" \
 && MODEL=flash KV_FORMAT=int4 GR8_WIDTHS=2 scripts/build.sh /out/bin \
 && if grep -qF 'touch -c "$C"' engine/runtime/nvcc_cache.sh; then \
      find "$GR8_NVCC_CACHE_DIR" -type f ! -newer "$GR8_NVCC_CACHE_DIR/.start" -delete; fi \
 && find /out/bin -mindepth 1 -maxdepth 1 ! -name g6m4_flash-int4 -exec rm -rf {} +

# The binaries the runtime stage copies, at the paths it copies them from: built above, or from gr8's image
FROM scratch AS bins-build
COPY --from=engine /out/bin/g6m4_flash-int4 /bin/
COPY --from=libs /out/g6load /out/kvman-remote /bin/
COPY --from=libs /out/libgr8knobs.so /bin/lib/
COPY --from=front /out/g6front-rs /bin/

FROM ${GR8_IMAGE} AS gr8-image

FROM scratch AS bins-image
COPY --from=gr8-image /opt/gr8/bin/g6m4_flash-int4 /opt/gr8/bin/g6load /opt/gr8/bin/kvman-remote /opt/gr8/bin/g6front-rs /bin/
COPY --from=gr8-image /opt/gr8/bin/lib/libgr8knobs.so /bin/lib/

FROM bins-${ENGINE_SRC} AS bins

FROM nvidia/cuda:${CUDA_VERSION}-runtime-${UBUNTU} AS runtime
# python3 for the launcher and the shim (python3-yaml for the KV store file), curl + jq for the smoke test.
# libibverbs1 and ibverbs-providers (libmlx5) for the ConnectX fabric between the two boxes.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends libibverbs1 ibverbs-providers python3 python3-yaml curl jq \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/gr8
COPY gr8/ .
COPY --from=bins /bin/ bin/
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
#   TUNE           speed, context or quality: sets VARIANT, SESS, CAP and MAX_MODEL_LEN unless set (knobs.sh), and
#                  context-parallel KV for context
#   CAP            the KV pool in tokens, shared by the sessions: 2,097,152 for speed and context, 262,208 for quality
#   MAX_MODEL_LEN  the longest single request, prompt and output together: 262,144, or 1,048,576 for context
#   SESS           the requests that decode at once: 8, or 4 for quality
#   VARIANT        the release's width manifest: bit349 (about 3.49 bits a routed weight), or k4 for quality
#   DFLASH         1: a request alone drafts with the DFlash2 drafter (fetched and converted on the first boot); 0: MTP only
#   MENTAT         0: the two boxes in PEERS; 1: find each other through mentat (knobs.sh)
#   EXTRA_ENV      engine variables; knobs.sh adds GR8_GLM53F_VISION=1 (image input) unless it already names it
ENV TUNE=speed DFLASH=1 MENTAT=0
# The rest of the recipe, as gr8's launcher options (gr8/KNOBS.md)
#   MODEL, DRAFTER: pinned to the Hugging Face commits measured here. The model cache is keyed by commit, so a new
#   commit on either repo (even a README edit) changes nothing until these move. The fetch hard-links unchanged files
#   from a cached commit.
# PEERS (and IPS, IPS2) have no default: they name the two boxes (knobs.sh, .env.example).
ENV TP=2 GROUP=gr8-glm53f-2x KV_FORMAT=int4 FLASH_CACHE=aligned KV_STORE=@/etc/gr8/kv-store.yaml \
    MODEL=https://huggingface.co/kindlingai/glm-5.3-flash-exlr8-k2-k3-k4@901ad084f0afd2400820504910d3e684133ce183 \
    DRAFTER=https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2@bf582e4eacc1810f76656d1811693ff6c6737d2a
# Reply and thinking length, as the one-box recipe. A request with no max_tokens gets 32,768 (or the room the context
# leaves, if less). With no limit, GLM-5.3-Flash at T=1 and maximum effort can think until max_tokens on a large agent
# task and never answer. From the 16,384th thinking token, the </think> logit gains 4 a thousand tokens, up to 10, so a
# long think ends where the model is ready to stop. The hard budget closes the thinking at 28,672 tokens, a backstop for
# a request the boost does not end, and leaves 4,096 of the default 32,768 to answer. Both count thinking tokens only.
# A request's own max_tokens, think_end_boost or thinking_budget wins.
ENV DEFAULT_MAX_TOKENS=32768 DEFAULT_THINK_END_BOOST="start=16384,per1k=4,max=10" DEFAULT_THINKING_BUDGET=28672
USER 1000:1000
ENTRYPOINT ["/opt/glm53f-2x/entrypoint.sh"]
