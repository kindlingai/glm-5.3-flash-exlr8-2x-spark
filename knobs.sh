# The recipe's TUNE and MENTAT knobs as gr8's options, sourced by entrypoint.sh and bin/gr8 so every gr8 command sees
# the same.
#   TUNE=speed (default), context or quality: all three boot the settings measured in README.md (the release's K4
#             width, int4 KV, CAP=262208). context has no settings of its own on two boxes yet: no CAP above 262,208
#             has been run on two. quality has none to have: K4 has the most bits per weight of the release's widths,
#             and the image builds only the int4 KV engine.
#   MENTAT=0 (default): the two boxes from PEERS (their LAN addresses, head first) and, if set, IPS and IPS2 (each box's
#             fabric address on the first and second ConnectX root, in PEERS order). Nothing is announced.
#   MENTAT=1: find the other box through the host's mentat daemon (gr8's MENTAT=localhost) and announce the API in the
#             mentat cluster, in group GROUP (gr8-glm53f-2x by default, so the pair never joins another Flash cluster).
case "${TUNE:-speed}" in
  speed|context|quality) ;;
  *) echo "TUNE=$TUNE: want speed (the default), context or quality (README.md, \"Pick what to prioritize\")" >&2; exit 2 ;;
esac
case "${MENTAT:-0}" in
  0) unset MENTAT
     n=$(tr , '\n' <<< "${PEERS:-}" | grep -c .) || true
     [ "$n" = 2 ] || { echo "PEERS=${PEERS:-}: want the two boxes' LAN addresses, head first, the same on both boxes (or MENTAT=1)" >&2; exit 2; } ;;
  1) unset PEERS; export MENTAT=localhost ;;
  localhost) unset PEERS ;;
  *) echo "MENTAT=$MENTAT: want 0 (the boxes in PEERS) or 1 (register with the mentat cluster)" >&2; exit 2 ;;
esac
