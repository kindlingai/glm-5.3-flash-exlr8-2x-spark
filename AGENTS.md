# For agents: boot GLM-5.3-Flash on two DGX Sparks

You are booting this recipe for someone. This file has the steps, every knob, and how to check each step. It is taken
from README.md, `knobs.sh`, `.env.example`, `compose.yaml`, the `Dockerfile` and gr8 (the `gr8/` submodule). If this
file and `knobs.sh` or `compose.yaml` disagree, follow `knobs.sh` and `compose.yaml`, and tell the person. If you
cannot run a check yourself, ask the person to run it and paste the output. Do not skip it.

## 1. Check the two boxes

On both boxes:

- The box is a DGX Spark, or another GB10 box such as the ASUS GX10 (128 GB). The two boxes are joined by a 200G cable
  between their ConnectX ports (README.md, Clustering).
- Docker and the NVIDIA container toolkit are installed (both come with DGX OS): `docker info | grep -i nvidia` shows
  the `nvidia` runtime.
- Free disk where Docker keeps volumes: about 77 GB for this box's part of the model, the vision tower and the
  drafter (about 90 GB with `TUNE=quality`; switching between the two keeps both, about 130 GB), plus, only if the person turns on the compact expert
  copies (off by default, step 3), 73 GiB (about 78 GB; a `VARIANT=k4` size, the `bit349` size was not measured), plus up
  to 64 GB for the prompt cache. Check
  with `df -h "$(docker info --format '{{.DockerRootDir}}')"`. With compose, you can set `MODEL_CACHE_DIR` and
  `PROMPT_CACHE_DIR` to host directories owned by uid 1000 instead.
- The box can reach Hugging Face for the download: `curl -sI https://huggingface.co` answers.
- No other model runs on the box: `docker ps` shows no other model container, and `nvidia-smi` shows no GPU process.
  The weights take about 76 GB a box (86 GB with `TUNE=quality`), and gr8 does not start while another gr8 engine
  runs on the box.
- TCP ports 7340 and 7341 are open between the two boxes: no firewall blocks them. Check this before the boot, while
  nothing listens on those ports. `nc` may not be installed, so use `python3` and bash. On the second box, listen on
  one port:

  ```bash
  python3 -c 'import socket; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("", 7340)); s.listen(1); print("ACCEPTED from", s.accept()[1])'
  ```

  On the head, connect to it:

  ```bash
  timeout 5 bash -c 'exec 3<>/dev/tcp/<box2>/7340' && echo OPEN || echo BLOCKED
  ```

  The second box prints `ACCEPTED from` and the head's address, and the head prints `OPEN`. The listener stops after
  one connection, so start it again for each test. Repeat the test for port 7341. Run it once for each address of the
  second box: its `PEERS` address and, if you set them, its `IPS` and `IPS2` addresses. Then test once the other way:
  listen on the head and connect from the second box. `BLOCKED` means a firewall, a wrong address, or no listener on
  the other box.
- Proactive memory compaction is off: `sysctl vm.compaction_proactiveness` prints 0. If it prints another value, run
  this as root, once (README.md, What you need):

  ```bash
  echo 'vm.compaction_proactiveness = 0' > /etc/sysctl.d/90-gr8-no-proactive-compaction.conf
  sysctl -w vm.compaction_proactiveness=0
  ```

- The ConnectX addresses, one of two ways:
  - With `mentat` (README.md, Clustering) running on both boxes: `docker ps` shows the `mentat` container. Use
    `MENTAT=1` below and leave out `PEERS`, `IPS` and `IPS2`.
  - Without `mentat`: each box has one ConnectX address per PCIe root (README.md, Clustering, has a netplan example).
    `ip -br addr show enp1s0f0np0` and `ip -br addr show enP2p1s0f0np0` show them, and `ls /dev/infiniband` lists
    devices. You need both boxes' 10G LAN addresses (`PEERS`, head first), their root-1 ConnectX addresses (`IPS`) and
    their root-2 addresses (`IPS2`), each list in the same order.

## 2. Pick the settings

Set the same values on both boxes, in `.env` (compose) or with `docker run -e`.

`TUNE` picks what to prioritize. Use the default unless the person asks for another value.

| `TUNE` | the settings it sets (`knobs.sh`) | what it gives |
|---|---|---|
| `speed` (default) | `VARIANT=bit349`, `SESS=8`, `CAP=2097152`, `MAX_MODEL_LEN=262144` | the settings of README.md's card: eight requests at once, each up to 262,144 tokens |
| `context` | the same as `speed`, with `MAX_MODEL_LEN=1048576` and `GR8_CP=1` added to `EXTRA_ENV` (context-parallel KV) | one request up to 1,048,576 tokens, with more memory free on each box. Decode at short context and prefill are a little slower |
| `quality` | `VARIANT=k4`, `SESS=4`, `CAP=262208`, `MAX_MODEL_LEN=262144` | the release's widest width (K4), four requests at once, each up to 262,144 tokens |

What else `knobs.sh` does:

- Any other `TUNE` value stops the boot.
- When the person sets `VARIANT`, `SESS`, `CAP` or `MAX_MODEL_LEN`, their value wins over the `TUNE`. With
  `TUNE=context`, a `GR8_CP` already in `EXTRA_ENV` keeps its value, and any other `EXTRA_ENV` stays, with `GR8_CP=1`
  added at the end.
- Image input is on: `GR8_GLM53F_VISION=1` is added to the end of `EXTRA_ENV`, unless `EXTRA_ENV` already names
  `GR8_GLM53F_VISION`. `GR8_GLM53F_VISION=0` in `EXTRA_ENV` turns it off. Any other `EXTRA_ENV` stays.
- With `MENTAT=0` (the default), `PEERS` must name two addresses, or the boot stops.

Every knob:

| knob | values | default |
|---|---|---|
| `PEERS` | the two boxes' 10G LAN addresses, comma-separated, head first, the same list on both boxes | none: required unless `MENTAT=1` |
| `IPS`, `IPS2` | each box's ConnectX address on PCIe root 1 and root 2, in `PEERS` order | none |
| `TUNE` | `speed`, `context`, `quality` | `speed` |
| `VARIANT` | the release's width manifest: `bit349` (K3 with K4 where it lowers KL most, about 3.49 bits a routed weight), `k4`, or another of the release's manifests | `TUNE`'s: `bit349`, or `k4` for `quality` |
| `SESS` | the requests that decode at once, 1 to 8 | `TUNE`'s: `8`, or `4` for `quality` |
| `CAP` | the KV pool in tokens, shared by the sessions, a multiple of 64; about 5 KB of memory a token. Every box holds the whole pool | `TUNE`'s: `2097152`, or `262208` for `quality` |
| `MAX_MODEL_LEN` | the longest single request, prompt and output together: at most `CAP` less the guard rows, and at most 1,048,576 | `TUNE`'s: `262144`, or `1048576` for `context` |
| `DFLASH` | `1`: a request alone drafts with the DFlash2 drafter (licence CC BY-NC-ND 4.0), downloaded and converted on the first boot. `0`: MTP only, nothing downloaded | `1` |
| `MENTAT` | `0`: the two boxes in `PEERS`. `1`: the boxes find each other and their ConnectX addresses through the host's `mentat` daemon, and register the API, in group `GROUP` | `0` |
| `GROUP` | the `mentat` group, with `MENTAT=1` | `gr8-glm53f-2x` |
| `GR8_GLM53F_VISION` (in `EXTRA_ENV`) | `1`: image input. Every box loads the vision tower (about 1.6 GiB of memory) and downloads it on the first boot (about 1.1 GB). `0`: text only, nothing downloaded for it. Set it in `EXTRA_ENV`, the same on both boxes; `knobs.sh` adds `GR8_GLM53F_VISION=1` when `EXTRA_ENV` does not name it | `1` |
| `DEFAULT_MAX_TOKENS` | `max_tokens` for a request that sends none, capped by the room the context leaves. `0`: the front end sizes it from gr8's `SHARE_LIMIT` (32,768 less the prompt, at least 8,192) | `32768` |
| `DEFAULT_THINK_END_BOOST` | the `</think>` logit gains `per1k` a thousand thinking tokens past `start`, up to `max` (gr8 frontend/README.md, soft thinking budget). `start` is a token count `N`, a share of the request's `max_tokens` written `Fx`, or `N\|Fx` for whichever comes first. Empty turns it off | `start=16384,per1k=4,max=10` |
| `DEFAULT_THINKING_BUDGET` | the hard thinking budget in tokens for a request that sets none, in the same forms; `0` = no limit. A request with `logprobs` gets none | `28672` |
| `DEFAULT_PRESENCE_PENALTY` | inside the think block 0.5 for every request; on the reply 0.2 for greedy requests only. The format is in gr8/KNOBS.md; `0` turns it off | `greedy=0.2,greedy.thinking=0.5,nongreedy.thinking=0.5` |
| `UNDECLARED_TOOL_CALLS` | `emit`: a call to an undeclared tool name comes back in `tool_calls` (the client answers it with its own error); `text`: it stays in `content`, `finish_reason: stop` | `emit` |
| `MODEL_CACHE_DIR`, `PROMPT_CACHE_DIR`, `GR8_HOME_DIR` | compose only: host directories in place of compose's volumes, owned by uid 1000 | compose's volumes |
| `IMAGE` | compose only: a pinned image, e.g. `ghcr.io/kindlingai/glm-5.3-flash-exlr8-2x-spark:sha-<commit>` | `:latest` |
| `MODEL` | the release, `https://huggingface.co/<org>/<repo>@<commit>` | the commit README.md's numbers were measured with |
| `DRAFTER` | the drafter, `https://huggingface.co/<org>/<repo>@<commit>` | the commit README.md's numbers were measured with |
| `HF_TOKEN` | sent only to Hugging Face, for a gated or private repo | none |
| `EXTRA_ENV` | `NAME=VALUE` pairs for the engine, separated by spaces, the same on both boxes. `.env.example` has `GR8_LOAD_COMPACT=/var/lib/gr8/cache/compact-tp2 GR8_LOAD_MERGE_KB=1` commented out: off by default, step 3 turns it on | none; `knobs.sh` adds `GR8_GLM53F_VISION=1` (and `GR8_CP=1` with `TUNE=context`) |

Any other gr8 launcher option works too (gr8/KNOBS.md).

## 3. Boot

The commands below use `TUNE=speed`: replace it with the value you picked. Replace `<head>` and `<box2>` with the two
boxes' 10G LAN addresses, head first, the same on both boxes. The `IPS` and `IPS2` values are the addresses of the
netplan example (README.md, Clustering): replace them with yours. With `mentat`, replace
`-e PEERS=... -e IPS=... -e IPS2=...` with `-e MENTAT=1`. With `MENTAT=1` the head is the box with the lowest address.

1. Optional, on both boxes: print the settings the boot will use. Compare the `CAP=` and `MAX_MODEL_LEN=` lines under
   "cluster options" with the `TUNE` table above. Without `mentat`, the last line gives this box's rank: rank 0 is
   the head.

   ```bash
   docker run --rm --network host -e PEERS=<head>,<box2> -e TUNE=speed \
     ghcr.io/kindlingai/glm-5.3-flash-exlr8-2x-spark:latest show-config --no-check
   ```

2. Optional, on both boxes: `check` runs the boot's own checks on the box without booting: the model's files in the
   cache, no other engine running, `/dev/infiniband`, free memory. It prints a `FAIL` line for each problem, ends with
   `check: N failed`, and exits 1 if N is not 0. Before the first boot it lists this box's part of the model as not in
   the cache yet and the drafter as not converted yet: the first boot downloads and converts them. Any other `FAIL`
   line is a problem to fix before step 4. With `mentat` it cannot check the model's files: a box learns its rank only
   at boot. Tell the person the `check` output before you change anything on the box.

   ```bash
   docker run --rm --gpus all --network host --pid host --device /dev/infiniband \
     -e PEERS=<head>,<box2> -e IPS=10.0.0.1,10.0.0.2 -e IPS2=10.0.1.1,10.0.1.2 -e TUNE=speed \
     -v glm53f-2x-cache:/var/lib/gr8/cache -v glm53f-2x-prompts:/var/lib/gr8/prompts -v glm53f-2x-home:/var/lib/gr8/home \
     ghcr.io/kindlingai/glm-5.3-flash-exlr8-2x-spark:latest check
   ```

3. Optional, off by default: the compact expert copies. Skip this step unless the person wants them. Skipped, `EXTRA_ENV`
   has no `GR8_LOAD_COMPACT` (`.env.example` has the line commented out) and the boot reads the release as before. To
   use them, on both boxes: set `EXTRA_ENV="GR8_LOAD_COMPACT=/var/lib/gr8/cache/compact-tp2 GR8_LOAD_MERGE_KB=1"` (in
   `.env` for compose, by removing the `#` from the line of `.env.example`; with `docker run`, `-e EXTRA_ENV=...` on the
   `prepare` command below and on the boot command in step 4), then write the copies once, before the first boot or with
   the container stopped. `prepare` first fetches and checks the model and the drafter as a boot does, then writes this
   box's copies to `/var/lib/gr8/cache/compact-tp2`, reads every copy back and checks it. It needs 73 GiB free beside
   the model (on a nearly full disk the copies can fragment and read slower), starts no engine, and reuses a directory
   that already holds good copies. Tell the person the numbers behind this are `VARIANT=k4` measurements on release pin
   `867580abd28d142bb4c56218bb81a752b7dea988` (the pin before this recipe's `bit349` default, PR #14, `8f1992b`) and that
   `bit349`, the default `TUNE=speed`, was not measured (README.md, "Compact expert copies"). If the line is on and
   `prepare` has not run, the boot still works: the loader finds no copies and reads the release as before, except
   `GR8_LOAD_MERGE_KB=1` still merges nearby reads (ranges at most 1 KB apart, gaps included); there is no number for
   that. Tell the person which it is.

   ```bash
   docker compose run --rm gr8 prepare            # compose, on both boxes
   docker run --rm --network host -e PEERS=<head>,<box2> -e TUNE=speed \
     -e EXTRA_ENV="GR8_LOAD_COMPACT=/var/lib/gr8/cache/compact-tp2 GR8_LOAD_MERGE_KB=1" \
     -v glm53f-2x-cache:/var/lib/gr8/cache \
     ghcr.io/kindlingai/glm-5.3-flash-exlr8-2x-spark:latest prepare     # docker run, on both boxes
   ```

   With `MENTAT=1` a box learns its rank only at boot, so add `--rank 0` on the head (the box with the lowest address)
   and `--rank 1` on the other box. A different `VARIANT`, a different TP size or a new release needs a new directory
   in `GR8_LOAD_COMPACT` and a new `prepare`; the copies of another `VARIANT` do not match. To turn the copies off
   again, comment out `EXTRA_ENV` (or remove `GR8_LOAD_COMPACT` and `GR8_LOAD_MERGE_KB` from it) on both boxes and
   restart; delete the directory to free the disk.

4. Start the container on both boxes within 10 minutes of each other. gr8's `JOIN_TIMEOUT` (600 s) limits how long
   the second box waits for the head to answer and, with `mentat`, how long the group takes to fill.

   ```bash
   docker run -d --name glm53f-2x-spark --gpus all --network host --pid host --device /dev/infiniband \
     --ulimit memlock=-1 --ulimit core=0 --cap-drop ALL --cap-add IPC_LOCK \
     --security-opt no-new-privileges --read-only --tmpfs /tmp:size=1g,mode=1777 --init --oom-score-adj 1000 \
     -e PEERS=<head>,<box2> -e IPS=10.0.0.1,10.0.0.2 -e IPS2=10.0.1.1,10.0.1.2 \
     -e TUNE=speed \
     -v glm53f-2x-cache:/var/lib/gr8/cache -v glm53f-2x-prompts:/var/lib/gr8/prompts -v glm53f-2x-home:/var/lib/gr8/home \
     ghcr.io/kindlingai/glm-5.3-flash-exlr8-2x-spark:latest
   ```

   If you wrote the copies (step 3), add `-e EXTRA_ENV="GR8_LOAD_COMPACT=/var/lib/gr8/cache/compact-tp2 GR8_LOAD_MERGE_KB=1"`
   to this command on both boxes; the copies are read only with it. (With compose, `.env` carries the line.)

   The first boot downloads each box's part from Hugging Face into the `glm53f-2x-cache` volume (about 77 GB, the
   model, the vision tower and the drafter) and converts the drafter.

   Or with compose, on both boxes:

   ```bash
   git clone --recurse-submodules https://github.com/kindlingai/glm-5.3-flash-exlr8-2x-spark
   cd glm-5.3-flash-exlr8-2x-spark
   cp .env.example .env          # edit PEERS, IPS and IPS2 and remove their # (or set MENTAT=1), and set TUNE: the same file on both boxes
   docker compose up -d
   ```

   Compose keeps the model in its own volumes, not in the `glm53f-2x-*` volumes of `docker run`, so the first compose
   boot downloads the model even after a `docker run` boot.

5. To change `TUNE` or any other knob later: stop and remove the container on both boxes, then start it again with the
   new value on both (compose: `docker compose down`, edit `.env`, `docker compose up -d`). The boxes refuse to join
   unless they have the same cluster options. A change of `TUNE` or `MAX_MODEL_LEN` alone downloads nothing: each
   box's part stays in its cache volume. A new `MODEL` or `DRAFTER` commit, or `DFLASH=1` after boots with
   `DFLASH=0`, downloads what the cache does not have yet. A new `CAP` starts the prompt cache empty.

## 4. Check that it serves

Wait for `serving:` in the head's log, then run the other checks below.

- On the head, `docker logs -f glm53f-2x-spark` (compose: `docker compose logs -f`) prints `serving: http://...` when
  the cluster serves.
- On both boxes, `docker exec glm53f-2x-spark gr8 glm53f health` exits 0 when that box serves. With compose,
  `docker compose ps` shows the container as `healthy` once this check passes.
- On the head, the API's `/health` answers 200 once the cluster serves. Before that it returns another status code, or
  does not answer: `curl -s -o /dev/null -w '%{http_code}\n' localhost:8100/health`.
- `docker exec glm53f-2x-spark gr8 glm53f status` shows both boxes' state, engine and free memory.
- On the head, `docker exec glm53f-2x-spark gr8 glm53f smoke` runs gr8's smoke test, 14 checks against the API. It
  ends with `14/14 passed` and exits 0 when every check passes.
- On the head, `docker exec glm53f-2x-spark gr8 glm53f bench --hosts ''` runs gr8's bench against the API. Without
  `--hosts ''` it stops with `FileNotFoundError: 'ssh'`. The bench reaches each box over ssh to cool and sample its
  GPU, and the image has no ssh. With `--hosts ''` the bench does not cool the GPUs between stages.
- The API is OpenAI-compatible, on the head's port 8100, with the model name `glm-5.3-flash` (`glm53f` also works).
  Send one chat:

  ```bash
  curl -s localhost:8100/v1/chat/completions -H 'Content-Type: application/json' -d '{
    "model": "glm-5.3-flash",
    "messages": [{"role": "user", "content": "Write a haiku about a small computer."}],
    "max_tokens": 4096
  }'
  ```

  The reply is JSON with a `choices` list. The model thinks before it answers: the thinking comes back in
  `message.reasoning` and counts toward `max_tokens`. With a small `max_tokens`, the reply can stop during the
  thinking, with `message.content` empty.
- Image input: send a small picture inline, as an `image_url` content part with a `data:` URL (base64), and ask what
  it shows. The API takes only inline images, up to 16 a request.
- To stop, on both boxes: `docker stop glm53f-2x-spark && docker rm glm53f-2x-spark` (compose: `docker compose down`).

## 5. When a step fails

| what you see | what to do |
|---|---|
| `TUNE=...: want speed (the default), context or quality ...` | use one of the three values |
| `PEERS=...: want the two boxes' LAN addresses, head first, the same on both boxes (or MENTAT=1)` | set `PEERS` to two addresses, the same list on both boxes, or `MENTAT=1` |
| `MENTAT=...: want 0 (the boxes in PEERS) or 1 (register with the mentat cluster)` | use `MENTAT=0` or `MENTAT=1` |
| `gr8: --max-model-len ...: more than CAP ..., the KV pool a request comes from` | set `MAX_MODEL_LEN` to at most `CAP` less the guard rows, or raise `CAP` |
| `gr8: memlock is limited ...` | `--ulimit memlock=-1` with `docker run`, `ulimits.memlock: -1` in compose |
| `gr8: ... is not writable by uid 1000 ...` | run `chown 1000:1000` on the host directory you set as `GR8_HOME_DIR` |
| `an engine is already running` or `a g6m4 --rank process is running` | ask the person, then stop the other model (README.md, Run another model) |
| `handshake refused: join: the head ... did not answer within 600s` | start both boxes within 600 s; check that `PEERS` is the same on both, head first, and that ports 7340 and 7341 are open (step 1) |
| `handshake refused: checks` | a box failed its checks: the lines below it name the box and each problem. Fix them, then start both boxes again |
| any other `handshake refused: ...`, such as `member list` | the message names what differs between the boxes: use the same `.env` or `-e` values and the same image on both, then start both boxes again |
| the image does not pull | build the image on each box, in a clone with its submodule. `docker compose build` tags it `ghcr.io/kindlingai/glm-5.3-flash-exlr8-2x-spark:latest`. Without compose, `docker buildx build --platform linux/arm64 -t glm53f-2x-spark .`, then use the tag `glm53f-2x-spark` |

The container's exit status is the launcher's: 0 after a stop, 1 when a rank failed or the boxes did not join, 2 for
bad options, 4 when the boxes' handshake refused the boot. `docker inspect -f '{{.State.ExitCode}}' glm53f-2x-spark`
prints it.

On the box that failed, read its log:

- After the container exits: `docker logs glm53f-2x-spark` (compose: `docker compose logs`). It has the launcher's
  output, and it is there until you remove the container.
- While the container runs: `docker exec glm53f-2x-spark gr8 glm53f logs supervisor` (or `shim` or `front`; with no
  name after `logs`, the engine's log).

If a step fails for a reason not listed here, ask on the KindlingAI Discord (the link is at the top of README.md).

## 6. Not measured yet: tell the person

This list is the recipe's checklist of what is still to be measured. If the person measures one of these, ask them to
post the numbers on Discord or in an issue (https://github.com/kindlingai/glm-5.3-flash-exlr8-2x-spark/issues).

- The release card's KL against BF16 (`bit349` 0.397, `k4` 0.384) was not measured through gr8 at TP=2. Neither
  width has been scored against BF16 here.
- `TUNE=context` with several long requests at once: the measured runs had one long prompt beside short requests.
