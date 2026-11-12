# KindlingAI: GLM-5.3-Flash EXLR8 on two DGX Sparks

If you are an agent booting this for someone, read [AGENTS.md](AGENTS.md) first, then the Quickstart.

_**Join our discord to learn more about KindlingAI and `gr8`: https://discord.gg/8EAvYPV2rE**_

GLM-5.3-Flash on two DGX Sparks (GB10, 128 GB each) at TP=2, served by [gr8](https://github.com/kindlingai/gr8) from
the `bit349` manifest of [kindlingai/glm-5.3-flash-exlr8-k2-k3-k4](https://huggingface.co/kindlingai/glm-5.3-flash-exlr8-k2-k3-k4).
One box serves GLM-5.3-Flash with [glm-5.3-flash-exlr8-1x-spark](https://github.com/kindlingai/glm-5.3-flash-exlr8-1x-spark).

![GLM-5.3-Flash on two GB10s: decode, prefill and concurrency](docs/card.png)

![Four requests decoding at once on two GB10s, at 2x speed](docs/concurrency-4.gif)

## What you need

- Two Sparks joined by a 200G cable between their ConnectX ports (see Clustering).
- Docker and the NVIDIA container toolkit on each box (both come with DGX OS).
- No other model running on either box: the weights take about 76 GB a box (86 GB with `TUNE=quality`).
- A LAN between the two boxes, with TCP ports 7340 and 7341 open.
- Proactive memory compaction off on each box, once, as root (it holds across reboots):

  ```bash
  echo 'vm.compaction_proactiveness = 0' > /etc/sysctl.d/90-gr8-no-proactive-compaction.conf
  sysctl -w vm.compaction_proactiveness=0
  ```

## Clustering

Give each box one address per PCIe root. The Spark's ConnectX card shows each physical port twice, once on each PCIe
root, and the engines use both. Run `ip -br link` on each box to list your port names; the names in the example below
(`enp1s0f0np0` and `enP2p1s0f0np0`) are the example's, so use yours. `mtu: 9000` (jumbo frames) must be set on both
boxes, and a switch between them must pass it. For a cable on the first port, with netplan:

```yaml
# /etc/netplan/60-connectx.yaml on the first box. On the second box: 10.0.0.2 and 10.0.1.2.
network:
  version: 2
  ethernets:
    enp1s0f0np0:        # the first port on PCIe root 1
      addresses: [10.0.0.1/24]
      mtu: 9000
    enP2p1s0f0np0:      # the same port on PCIe root 2
      addresses: [10.0.1.1/24]
      mtu: 9000
```

Then run `sudo netplan apply` on each box.

Two kinds of address are used below:

- The 10G LAN address is the box's address on your network (the Spark's 10G Ethernet port). `PEERS` holds the two
  boxes' 10G LAN addresses, head first, and the head serves the API on its LAN address.
- The ConnectX addresses are the ones you gave the ConnectX ports in the netplan file (`10.0.0.x` on PCIe root 1,
  `10.0.1.x` on PCIe root 2 in the example). `IPS` holds the two boxes' root-1 addresses and `IPS2` their root-2
  addresses.

With [`mentat`](https://github.com/kindlingai/mentat) running on each box, the recipe finds the other box and its
ConnectX addresses by itself. On each box:

```bash
docker run -d --name mentat --network host --restart unless-stopped ghcr.io/kindlingai/mentat:0.27.0
```

Then start the recipe with `MENTAT=1` in place of `PEERS`, `IPS` and `IPS2`.

Without `mentat`, set the two boxes' 10G LAN addresses in `PEERS` (head first), and the matching ConnectX addresses in
`IPS` (PCIe root 1) and `IPS2` (PCIe root 2), in the same order. In `.env.example` these three lines are commented
out, with placeholders: edit them and remove the `#` from each.

## Quickstart

Run the published image on both boxes with the same settings. Without `mentat`, replace `<head>` and `<box2>` with the
two boxes' 10G LAN addresses, the same list on both boxes. The head is the first box in `PEERS`: it serves the API on
port 8100. `IPS` and `IPS2` are the ConnectX addresses from the netplan example above: use yours.

```bash
docker run -d --name glm53f-2x-spark --gpus all --network host --pid host --device /dev/infiniband \
  --ulimit memlock=-1 --ulimit core=0 --cap-drop ALL --cap-add IPC_LOCK \
  --security-opt no-new-privileges --read-only --tmpfs /tmp:size=1g,mode=1777 --init --oom-score-adj 1000 \
  -e PEERS=<head>,<box2> -e IPS=10.0.0.1,10.0.0.2 -e IPS2=10.0.1.1,10.0.1.2 \
  -v glm53f-2x-cache:/var/lib/gr8/cache -v glm53f-2x-prompts:/var/lib/gr8/prompts -v glm53f-2x-home:/var/lib/gr8/home \
  ghcr.io/kindlingai/glm-5.3-flash-exlr8-2x-spark:latest
docker logs -f glm53f-2x-spark     # on the head: ready at "serving: http://..."
```

With `mentat` running, replace the `PEERS`, `IPS` and `IPS2` settings with `-e MENTAT=1`. The head is then the box
with the lowest address.

The first boot downloads each box's part from Hugging Face into the `glm53f-2x-cache` volume (about 77 GB, the model,
the vision tower and the drafter) and converts the drafter. The download time depends on your link, and this recipe has no measured
first-boot time yet. The boxes wait up to 600 s (10 minutes) for each other, so start both within that time.

The API is OpenAI's on the head's port 8100, and the model's name is `glm-5.3-flash` (`glm53f` also works):

```bash
curl -s localhost:8100/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "glm-5.3-flash",
  "messages": [{"role": "user", "content": "Write a haiku about a small computer."}],
  "max_tokens": 4096
}'
```

The model thinks before it answers. The thinking comes back in `message.reasoning` and counts toward `max_tokens`.

The model also reads images. Send each one inline as an `image_url` content part with a `data:` URL (base64), up to 16
images a request; the API does not fetch URLs:

```bash
curl -s localhost:8100/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "glm-5.3-flash",
  "messages": [{"role": "user", "content": [
    {"type": "text", "text": "What is in this picture?"},
    {"type": "image_url", "image_url": {"url": "data:image/png;base64,<base64 of the PNG>"}}]}],
  "max_tokens": 4096
}'
```

```bash
docker exec glm53f-2x-spark gr8 glm53f smoke   # on the head: 14 checks against the API
docker stop glm53f-2x-spark && docker rm glm53f-2x-spark   # on both boxes
```

`:latest` is main. Each commit is also published as `sha-<commit>`, and each tag under its name.

## Run it with compose

`compose.yaml` runs the same image with the same settings and reads `PEERS` and the knobs from `.env`. On both boxes:

```bash
git clone --recurse-submodules https://github.com/kindlingai/glm-5.3-flash-exlr8-2x-spark
cd glm-5.3-flash-exlr8-2x-spark
cp .env.example .env          # edit PEERS, IPS and IPS2 and remove their #: the same file on both boxes
docker compose up -d
docker compose logs -f
```

`docker compose up -d --build` builds the image on the box instead.

## Knobs

Set these in `.env` next to `compose.yaml` (see `.env.example`), or with `docker run -e`, the same on both boxes:

| knob | default | |
|---|---|---|
| `TUNE` | `speed` | What to prioritize, see below. It sets the defaults of `VARIANT`, `SESS`, `CAP` and `MAX_MODEL_LEN`. Any other value stops the boot. |
| `PEERS` | none | The two boxes' 10G LAN addresses, head first. Required unless `MENTAT=1`. |
| `IPS`, `IPS2` | none | Each box's ConnectX address on PCIe root 1 and root 2, in `PEERS` order. |
| `VARIANT` | `bit349` (`k4` with `TUNE=quality`) | The release's width manifest, such as `bit349` or `k4`. A width not in the cache yet downloads at boot. |
| `SESS` | `4` (`8` with `TUNE=context`) | The requests that decode at once, 1 to 8. |
| `CAP` | `2097152` (`262208` with `TUNE=quality`) | The KV pool in tokens, shared by the sessions. Each request reserves its prompt + `max_tokens` from it. |
| `MAX_MODEL_LEN` | `262144` (`1048576` with `TUNE=context`) | The longest single request, prompt and output together. At most 1,048,576. |
| `DFLASH` | `1` | `1` drafts with [DFlash2](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2) (CC BY-NC-ND 4.0) when a request runs alone, downloaded on the first boot. `0` uses MTP only and downloads nothing. |
| `MENTAT` | `0` | `1` finds the other box and the ConnectX addresses through the host's `mentat` daemon, and registers the API in group `GROUP` (`gr8-glm53f-2x`). |
| `GR8_GLM53F_VISION` in `EXTRA_ENV` | `1` | Image input. Each box loads the vision tower (about 1.6 GiB of memory) and downloads it on the first boot (about 1.1 GB). The recipe adds `GR8_GLM53F_VISION=1` to `EXTRA_ENV` unless `EXTRA_ENV` already names it: to turn image input off, set `EXTRA_ENV="GR8_GLM53F_VISION=0"` (with anything else `EXTRA_ENV` holds) on both boxes. |
| `DEFAULT_MAX_TOKENS` | `32768` | `max_tokens` for a request that sends none, or the room the context leaves if that is less. |
| `DEFAULT_THINK_END_BOOST` | `start=16384,per1k=4,max=10` | After 16,384 thinking tokens, makes the end of thinking a little more likely with each token, so a long think ends where the model is ready to stop. Empty turns it off. |
| `DEFAULT_THINKING_BUDGET` | `28672` | The most thinking tokens a request gets, after which its thinking is closed and it answers. `0` means no limit. |
| `DEFAULT_PRESENCE_PENALTY` | `greedy=0.2,greedy.thinking=0.5,nongreedy.thinking=0.5` | A presence penalty on thinking tokens (0.5) to stop the model repeating its own reasoning, plus 0.2 on the reply for greedy requests (temperature 0). The reply of a sampled request gets none. `0` turns it off. |
| `UNDECLARED_TOOL_CALLS` | `emit` | A call to a tool the request did not declare comes back as a tool call, so your agent can answer it with an unknown-tool error. `text` leaves it in the reply's text. |

The image pins the weights to fixed Hugging Face commits. Set `MODEL` or `DRAFTER` in `.env` to change them
(`https://huggingface.co/<org>/<repo>@<commit>`). With a `MODEL` that follows a branch, set `VARIANT` to the
manifest's path.

[gr8/KNOBS.md](https://github.com/kindlingai/gr8/blob/db6f2c17c7b05303b69ce667e416d10340aeb9b7/KNOBS.md) lists the
advanced `gr8` options, which you can also set in `.env`.

## Pick what to prioritize

`TUNE` picks one of three settings. When you set `VARIANT`, `SESS`, `CAP` or `MAX_MODEL_LEN` yourself, your value wins.

| `TUNE` | sets |
|---|---|
| `speed` (default) | `VARIANT=bit349`, `SESS=4`, `CAP=2097152`, `MAX_MODEL_LEN=262144` |
| `context` | `VARIANT=bit349`, `SESS=8`, `CAP=2097152`, `MAX_MODEL_LEN=1048576`, and context-parallel KV (`GR8_CP=1`, experimental) |
| `quality` | `VARIANT=k4` (the release's widest width), `SESS=4`, `CAP=262208`, `MAX_MODEL_LEN=262144` |

With shared waterfill MTP=3 drafting (`S2_SHARED_WATERFILL=1`, `MTP=3`), `TUNE=speed` defaults to `SESS=4` (max concurrent 4), leaving 8.9-9.2 GiB of post-capture memory free per box (25 s warm boot; 55.1 / 70.3 / 82.9 tok/s at 1 / 2 / 4 streams, against 56.0 / 63.9 / 78.5 tok/s on the prior `SESS=8` `MTP=1` build). `SESS=8` with `MTP=3` without context-parallel KV leaves 6.4-6.9 GiB free; `TUNE=context` runs `SESS=8` with `GR8_CP=1` (8.7-9.1 GiB free, 29 s warm boot, 53.0 / 69.2 / 79.8 / 97.4 tok/s at 1 / 2 / 4 / 8 streams). `TUNE=quality` runs `SESS=4` with `MTP=3` (9.4-9.6 GiB free, 53.3 / 65.3 / 78.3 tok/s at 1 / 2 / 4 streams vs 53.1 / 58.7 / 72.4 tok/s with `GR8_S2_SHARED_WATERFILL=0`).

## Compact expert copies

Optional, and off by default. `GR8_LOAD_COMPACT` and `GR8_LOAD_MERGE_KB=1` in `EXTRA_ENV` make the loader read dense
per-rank copies of its expert ranges in place of the release's sparse files. The bytes it loads are the same, and a
switch into this recipe was faster in our runs. The numbers below are `VARIANT=k4` numbers, not the default `bit349`'s:
see the label under the table.

To turn it on, on both boxes: remove the `#` from the `EXTRA_ENV` line in `.env` (`.env.example` has it commented out),
write the copies once, then start or restart the recipe. Write the copies before the first boot or with the recipe
stopped (`prepare` writes files and starts no engine). With compose:

```bash
docker compose run --rm gr8 prepare               # on both boxes
docker compose run --rm gr8 prepare --rank 0      # with MENTAT=1 instead: the rank is only decided at boot, so name it
                                                  # (rank 0 on the head, rank 1 on the other box)
```

`prepare` first fetches and checks the model and the drafter as a boot does. It then writes this box's expert ranges to
`/var/lib/gr8/cache/compact-tp2` (the cache volume), reads every copy back through the loader's map and checks it. A
directory that already exists is checked and reused, never overwritten. A boot never writes or refreshes copies.

- **If the line is on and `prepare` has not run**, the loader finds no copies and reads the release as before, except
  `GR8_LOAD_MERGE_KB=1` still merges nearby reads: it reads ranges of one file that are at most 1 KB apart with one
  read, gaps included. We have no numbers for that without the copies.
- **Disk:** 73 GiB (about 78 GB) a box: 43 copy files and their maps, with `VARIANT=k4`; the `bit349` size was not
  measured. They sit beside the release, which stays. Run `prepare` on a disk with room: copies written onto a nearly
  full disk can fragment and read slower.
- **A different `VARIANT`** (`TUNE=quality` uses `k4`), TP size or release needs its own directory: set
  `GR8_LOAD_COMPACT` to a new path in `EXTRA_ENV` on both boxes and run `prepare` again.
- **Both boxes** need the same `EXTRA_ENV`. With `docker run`, pass
  `-e EXTRA_ENV="GR8_LOAD_COMPACT=/var/lib/gr8/cache/compact-tp2 GR8_LOAD_MERGE_KB=1"` to the `prepare` command (the
  `docker run ... prepare` command is in AGENTS.md, step 3 of "Boot") and add it to the boot command in the Quickstart,
  on both boxes: the copies are read only with it.
- **To turn it off again,** comment out the `EXTRA_ENV` line in `.env` on both boxes and restart. The copies stay in the
  volume. To free the 73 GiB, delete the `compact-tp2` directory in the cache volume.

Measured on 2026-11-07 (Pacific time) on two DGX Sparks, GLM-5.3-Flash at TP=2, a local build of this recipe on gr8
`d21ddaa`, copies written by `prepare` on both boxes (73 GiB a box: 43 copy files and their maps). On GLM-5.3-Flash the
copies pay only together with `GR8_LOAD_MERGE_KB=1`. Two experiments, each with its own stock runs, each in the order
stock, knob, knob, stock. The total is the whole switch from GLM-5.3 to GLM-5.3-Flash, until `/health` reports ready; the
read time is the loader's own for one rank:

| Switch GLM-5.3 to GLM-5.3-Flash | Stock, total (n=2) | With the knob, total (n=2) | A rank's read, stock / knob |
|---|---|---|---|
| `GR8_LOAD_COMPACT` alone | 34.2 / 32.8 s | 31.4 / 33.0 s | 19.6-19.9 s / 19.4-19.7 s |
| `GR8_LOAD_COMPACT` with `GR8_LOAD_MERGE_KB=1` | 33.5 / 33.5 s | 26.9 / 25.2 s | 19.5-19.9 s / 12.6-12.9 s |

With both knobs, the switches into the pair (two runs each) took 25.8 / 25.5 s from GLM-5.3 and 22.9 / 24.1 s from
DeepSeek-V4.1-Flash. Earlier the same day, without the copies and on the recipe's previous build, the same switches took
33.4 / 33.5 s and 30.7 / 29.5 s. The same 8 fixed prompts gave the same text and token counts as the stock arm, 8 of 8.
([gr8's docs/SWITCHING.md](https://github.com/kindlingai/gr8/blob/main/docs/SWITCHING.md#compact-copies-on-the-pair)
has the runs.)

Every number above, and the 73 GiB and 43 files, was measured with `VARIANT=k4` on release pin
`867580abd28d142bb4c56218bb81a752b7dea988` (kindlingai/glm-5.3-flash-exlr8-k2-k3-k4), the pin before this recipe's
`bit349` default (PR #14, `8f1992b`; the current pin is `901ad084f0afd2400820504910d3e684133ce183`). `bit349` (the
default, `TUNE=speed`) was not measured.

## Run another model

A box runs one model at a time. To switch, stop and remove this recipe's container on both boxes:

```bash
docker stop glm53f-2x-spark && docker rm glm53f-2x-spark   # compose: docker compose down
```

Each box's part stays in its `glm53f-2x-cache` volume, so a later start downloads nothing. To free the disk (about
77 GB a box, about 130 GB after `TUNE=quality` boots too, up to 73 GiB (about 78 GB) of compact copies (a `VARIANT=k4` size) if
you wrote them, and up to 64 GB of prompt checkpoints), remove the volumes on both boxes:

```bash
docker volume rm glm53f-2x-cache glm53f-2x-prompts glm53f-2x-home   # compose: docker compose down -v
```

[gr8's Recipes](https://github.com/kindlingai/gr8#recipes) lists the other models and the number of boxes each one
needs.

## Help

Ask on Discord (https://discord.gg/8EAvYPV2rE) or open an issue in this repo
(https://github.com/kindlingai/glm-5.3-flash-exlr8-2x-spark/issues). Include the command you ran and the end of
`docker logs glm53f-2x-spark`. Remove addresses and hostnames before you post.
