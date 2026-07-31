#!/bin/bash
# Translate what a project is missing, with a model, and refuse to keep an
# answer the linter rejects.
#
#   Examples/translate.sh ja de fr
#
# The loop:
#
#   check --out   writes one fill-in template per catalog and language
#   $TRANSLATOR   fills it in
#   add           merges it into the catalog, never flattening a plural
#   check         runs again — and this is the step that makes the rest safe
#
# A model that drops a %@, or answers a Russian plural with one string, has
# produced something Xcode compiles and ships. So when the re-check fails, the
# findings go back to the translator together with the payload it wrote, once.
# If the second answer is still wrong the run stops and says which language it
# stopped on, rather than committing it and reporting success.
#
# TRANSLATOR is any command that reads a template on stdin and writes a filled
# template on stdout: a model, a script, a translation API. It defaults to
# Claude Code in headless mode. STATE is the translation state to write —
# `translated` by default, `needs_review` if machine output should queue for a
# human. WORK is where the templates are kept, so you can read what the model
# was asked and what it said.

set -uo pipefail

XCLOCSMITH="${XCLOCSMITH:-xclocsmith}"
WORK="${WORK:-.xclocsmith-work}"
STATE="${STATE:-translated}"

if [ $# -eq 0 ]; then
    echo "usage: $0 <language> [language ...]" >&2
    echo "  e.g. $0 ja de fr        TRANSLATOR=./my-translator.sh $0 ja" >&2
    exit 2
fi

command -v "$XCLOCSMITH" >/dev/null || { echo "not on PATH: $XCLOCSMITH" >&2; exit 2; }

PROMPT='You are translating an Xcode String Catalog. The JSON on stdin is a
fill-in template: replace every "TODO" with a translation into the language
named by the "language" field, and return the same JSON with nothing else
around it — no prose, no code fence.

Rules that are not style preferences:
- Every format specifier in the source (%@, %lld, %1$@, %#@name@) must appear
  in the translation, the same number of times. Reorder them with positional
  forms (%1$@, %2$@) if the language needs a different word order.
- A "plural" object must have every category it lists filled in. They are the
  categories this language actually requires; do not add or drop any.
- "source" and "comment" are context. Do not translate them and do not return
  them changed.
- Keep the placeholders, punctuation class and trailing whitespace of the
  source. Translate the text, not the markup: leave Markdown, HTML tags and
  ^[...](inflect: true) markup structurally intact.'

# Fill one template. Reads the template on stdin, writes the filled one on
# stdout. A model that wraps its answer in a code fence is a fact of life.
translate() {
    if [ -n "${TRANSLATOR:-}" ]; then
        eval "$TRANSLATOR"
    else
        claude -p --output-format text "$PROMPT"
    fi | sed '/^[[:space:]]*```/d'
}

failed_languages=()

for language in "$@"; do
    echo "── $language ─────────────────────────────────────────────"
    rm -rf "$WORK/$language" && mkdir -p "$WORK/$language"

    # Templates are written per catalog and per language, so a project with
    # several catalogs gets several files, named after the catalog.
    "$XCLOCSMITH" check --lang "$language" --out "$WORK/$language/work.json" >/dev/null 2>&1
    templates=("$WORK/$language"/*.json)
    if [ ! -e "${templates[0]}" ]; then
        echo "nothing missing"
        continue
    fi

    for template in "${templates[@]}"; do
        filled="${template%.json}.filled.json"
        echo "translating $(basename "$template")"
        if ! translate < "$template" > "$filled" || [ ! -s "$filled" ]; then
            echo "  the translator produced nothing" >&2
            failed_languages+=("$language")
            continue
        fi
        if ! "$XCLOCSMITH" add "$filled" --state "$STATE"; then
            echo "  the payload would not apply" >&2
            failed_languages+=("$language")
        fi
    done

    # The point of the whole script. Everything above trusted the model.
    if report=$("$XCLOCSMITH" check --lang "$language" 2>&1); then
        echo "$language: clean"
        continue
    fi

    echo "$language: the linter rejected the translation, asking again"
    echo "$report" | sed -n '/FAIL/,/^$/p' | sed 's/^/  /'
    original_prompt="$PROMPT"
    PROMPT="$original_prompt

You returned this payload and the localization linter rejected it. Fix exactly
what it reports, leave everything else as you wrote it, and return the whole
corrected payload:

$report"
    for template in "$WORK/$language"/*.filled.json; do
        [ -e "$template" ] || continue
        retry="${template%.filled.json}.retry.json"
        translate < "$template" > "$retry"
        [ -s "$retry" ] && "$XCLOCSMITH" add "$retry" --state "$STATE"
    done
    PROMPT="$original_prompt"

    if "$XCLOCSMITH" check --lang "$language"; then
        echo "$language: clean on the second attempt"
    else
        echo "$language: still failing — left in the catalog for a human to look at" >&2
        failed_languages+=("$language")
    fi
done

if [ ${#failed_languages[@]} -gt 0 ]; then
    echo
    echo "unresolved: ${failed_languages[*]}" >&2
    exit 1
fi
