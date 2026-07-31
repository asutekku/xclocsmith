#!/bin/bash
# Reproduce the "Results on real projects" table in README.md.
#
#   Scripts/corpus.sh clone [dir]    shallow-clone the nine projects at the
#                                    commits the table was measured against
#   Scripts/corpus.sh run   [dir]    run check + scan on each and print the table
#   Scripts/corpus.sh all   [dir]    both
#
# Default directory is ./corpus, which is git-ignored. It is about 1.5 GB;
# apple-browsers alone is 345 MB.
#
# The commits are pinned because the table is a claim about specific numbers.
# Re-pin them when you refresh the table, and say in the commit message that
# you did — a number that moved because upstream changed is not a regression,
# and one that moved because this tool changed is the whole point.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${2:-$ROOT/corpus}"
XCLOCSMITH="$ROOT/.build/release/xclocsmith"

# name|repo|commit
PROJECTS='Whisky|https://github.com/Whisky-App/Whisky.git|fd5480a
Loop|https://github.com/MrKai77/Loop.git|3b632db
NetNewsWire|https://github.com/Ranchero-Software/NetNewsWire.git|5203000
IceCubesApp|https://github.com/Dimillian/IceCubesApp.git|9c05a72
mastodon-ios|https://github.com/mastodon/mastodon-ios.git|5ed5367
HSTracker|https://github.com/HearthSim/HSTracker.git|d3460c8
nimble-commander|https://github.com/mikekazakov/nimble-commander.git|1a5d23a
GoMap|https://github.com/bryceco/GoMap.git|40a7f78
apple-browsers|https://github.com/duckduckgo/apple-browsers.git|ba306ac3'

clone() {
    mkdir -p "$DIR"
    echo "$PROJECTS" | while IFS='|' read -r name repo commit; do
        if [ -d "$DIR/$name/.git" ]; then
            echo "$name: already cloned"
            continue
        fi
        echo "$name: cloning"
        # A shallow clone cannot check out an arbitrary commit, so fetch that
        # one object rather than the whole history.
        git init -q "$DIR/$name"
        git -C "$DIR/$name" remote add origin "$repo"
        git -C "$DIR/$name" fetch -q --depth 1 origin "$commit"
        git -C "$DIR/$name" checkout -q FETCH_HEAD
    done
}

run() {
    if [ ! -x "$XCLOCSMITH" ]; then
        echo "Build it first: swift build -c release" >&2
        exit 1
    fi
    printf '%-18s %6s %7s %9s %10s %8s %14s %10s %11s\n' \
        project format plural diverge hygiene project sentence duplicate unlocalized
    echo "$PROJECTS" | while IFS='|' read -r name repo commit; do
        [ -d "$DIR/$name" ] || { echo "$name: not cloned"; continue; }
        ( cd "$DIR/$name" && "$XCLOCSMITH" check --json >/tmp/corpus-check.json 2>/dev/null || true )
        ( cd "$DIR/$name" && "$XCLOCSMITH" scan --json >/tmp/corpus-scan.json 2>/dev/null || true )
        python3 - "$name" <<'PY'
import json, sys
name = sys.argv[1]
def load(path):
    try:
        with open(path) as handle: return json.load(handle)
    except Exception: return None
check, scan = load('/tmp/corpus-check.json'), load('/tmp/corpus-scan.json')
if check is None:
    print(f'{name:<18} check failed'); raise SystemExit
cats = check['catalogs']
fmt = sum(len(c['formatMismatches']) for c in cats)
plural = sum(len(c['pluralGaps']) for c in cats)
groups = [d for c in cats for d in c['duplicateSources']]
diverge = len([d for d in groups if d['divergences']])
dup = len(groups) + sum(len(c['similarKeys']) for c in cats)
hyg = [f for c in cats for f in c.get('hygiene', [])]
hygiene = f"{len([f for f in hyg if f['isFailure']])}/{len(hyg)}"
project = len(check.get('project', []))
sentence = [s for c in cats for s in c.get('sentenceKeys', [])]
risk = sum(s['translationsAtRisk'] for s in sentence)
sent = f"{len(sentence)}/{risk}"
unloc = len(scan['missingKeys']) if scan else '?'
print(f'{name:<18} {fmt:6} {plural:7} {diverge:9} {hygiene:>10} {project:8} {sent:>14} {dup:10} {unloc:>11}')
PY
    done
}

case "${1:-all}" in
    clone) clone ;;
    run) run ;;
    all) clone; run ;;
    *) echo "usage: $0 {clone|run|all} [dir]" >&2; exit 2 ;;
esac
