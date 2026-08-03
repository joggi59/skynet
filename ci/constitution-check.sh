#!/usr/bin/env bash
# Verify the constitutional invariants.
#
#   ci/constitution-check.sh                          run every check
#   ci/constitution-check.sh --check <id>             run one
#   ci/constitution-check.sh --list                   list checks and their state
#   ci/constitution-check.sh --simulate-amendment <invariant>
#                                                     show which amendment tier
#                                                     governs an invariant
#
# Exit 0 if nothing failed, 1 if something did, 2 on usage or environment error.
#
# PENDING is reported as PENDING. See ci/lib.sh for why that matters.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT" || die "cannot enter repo root"

CONST="$REPO_ROOT/constitution.toml"
PROSE="$REPO_ROOT/CONSTITUTION.md"
[ -f "$CONST" ] || die "missing constitution.toml"
[ -f "$PROSE" ] || die "missing CONSTITUTION.md"
have_python || die "python3 required (stdlib tomllib)"

# ---------------------------------------------------------------------------
# The two files must not drift. constitution.toml is authoritative for
# enforcement, CONSTITUTION.md for meaning; an invariant present in one and not
# the other means one of them is lying.
# ---------------------------------------------------------------------------
check_prose_sync() {
    heading "Prose and machine form agree"
    local ids titles missing=0
    ids=$(toml_get "$CONST" "[i['id'] for i in d['invariant']]")
    titles=$(toml_get "$CONST" "[i['title'] for i in d['invariant']]")

    while IFS= read -r title; do
        [ -z "$title" ] && continue
        if grep -qF "$title" "$PROSE"; then
            :
        else
            fail "invariant '$title' is in constitution.toml but has no section in CONSTITUTION.md"
            missing=1
        fi
    done <<< "$titles"

    local n_toml n_prose
    n_toml=$(echo "$ids" | grep -c .)
    n_prose=$(grep -cE '^### [0-9]+\. ' "$PROSE" || true)
    if [ "$n_toml" -ne "$n_prose" ]; then
        fail "constitution.toml declares $n_toml invariants, CONSTITUTION.md documents $n_prose"
        missing=1
    fi

    [ "$missing" -eq 0 ] && pass "$n_toml invariants, both forms in agreement"
}

# ---------------------------------------------------------------------------
# Invariant 6 — HAL boundary
# No architecture-specific construct outside kernel/src/arch/.
# ---------------------------------------------------------------------------
check_hal_boundary() {
    heading "Invariant 6 — HAL boundary"
    if ! kernel_exists; then
        pending "no kernel yet; enforced from M0"
        return
    fi

    local hal_dir forbidden violations=0
    hal_dir=$(toml_get "$CONST" "[i for i in d['invariant'] if i['id']=='hal_boundary'][0]['hal_dir']")
    forbidden=$(toml_get "$CONST" "[i for i in d['invariant'] if i['id']=='hal_boundary'][0]['forbidden_outside_hal']")

    while IFS= read -r construct; do
        [ -z "$construct" ] && continue
        # Search kernel sources outside the HAL directory only.
        local hits
        hits=$(grep -rnF -- "$construct" kernel/src 2>/dev/null \
               | grep -v "^$hal_dir/" | grep -v '^\s*//' || true)
        if [ -n "$hits" ]; then
            fail "architecture-specific construct '$construct' outside $hal_dir"
            while IFS= read -r h; do detail "$h"; done <<< "$hits"
            violations=1
        fi
    done <<< "$forbidden"

    [ "$violations" -eq 0 ] && pass "no architecture-specific construct outside $hal_dir"
}

# ---------------------------------------------------------------------------
# Invariant 7 — no kernel dependencies
# ---------------------------------------------------------------------------
check_no_kernel_deps() {
    heading "Invariant 7 — no kernel dependencies"
    if ! kernel_exists; then
        pending "no kernel yet; enforced from M0"
        return
    fi

    local deps
    deps=$(python3 -c "
import tomllib
d = tomllib.load(open('kernel/Cargo.toml','rb'))
names = []
for section in ('dependencies','build-dependencies','dev-dependencies'):
    names += list(d.get(section,{}).keys())
print(' '.join(names))
" 2>/dev/null)

    if [ -n "$deps" ]; then
        fail "kernel declares dependencies: $deps"
        detail "invariant 7 requires an empty tree — write it instead"
        return
    fi

    # Cargo.lock is the real evidence: a manifest can be clean while the lock
    # is not, if the workspace pulled something in.
    if [ -f kernel/Cargo.lock ]; then
        local n
        n=$(grep -c '^\[\[package\]\]' kernel/Cargo.lock || true)
        if [ "$n" -gt 1 ]; then
            fail "kernel/Cargo.lock resolves $n packages; exactly 1 (the kernel) is permitted"
            grep -A1 '^\[\[package\]\]' kernel/Cargo.lock | grep '^name' | while read -r l; do detail "$l"; done
            return
        fi
    fi

    pass "kernel dependency tree is empty"
}

# ---------------------------------------------------------------------------
# Invariant 3 — total provenance
# The ledger must be well-formed and append-only.
# ---------------------------------------------------------------------------
check_provenance() {
    heading "Invariant 3 — total provenance"
    local ledger=".provenance/ledger.jsonl"

    if [ ! -f "$ledger" ]; then
        pending "ledger not created yet"
        return
    fi

    local bad=0 n=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        n=$((n+1))
        if ! echo "$line" | python3 -c "
import json,sys
required = ['contribution_id','task','objective','agent','model',
            'reviewer_verdicts','guardian_verdicts','evidence_digest','merged_at']
try:
    e = json.loads(sys.stdin.read())
except Exception as ex:
    print(f'not valid JSON: {ex}'); sys.exit(1)
missing = [f for f in required if f not in e]
if missing:
    print('missing fields: ' + ', '.join(missing)); sys.exit(1)
" >/tmp/.prov_err 2>&1; then
            fail "ledger line $n malformed: $(cat /tmp/.prov_err)"
            bad=1
        fi
    done < "$ledger"
    rm -f /tmp/.prov_err

    # Append-only: no committed ledger line may ever be modified or removed.
    if git rev-parse --verify HEAD >/dev/null 2>&1 && git ls-files --error-unmatch "$ledger" >/dev/null 2>&1; then
        local prev
        prev=$(git show "HEAD:$ledger" 2>/dev/null || true)
        if [ -n "$prev" ]; then
            local prev_lines
            prev_lines=$(echo "$prev" | grep -c . || true)
            if ! head -n "$prev_lines" "$ledger" | diff -q - <(echo "$prev") >/dev/null 2>&1; then
                fail "ledger is not append-only: existing lines were modified or removed"
                detail "rewriting provenance destroys the only property that makes this project meaningful"
                bad=1
            fi
        fi
    fi

    [ "$bad" -eq 0 ] && pass "$n ledger entries, well-formed and append-only"
}

# ---------------------------------------------------------------------------
# Invariant 10 — English repository (advisory)
# ---------------------------------------------------------------------------
check_english() {
    heading "Invariant 10 — English repository (advisory)"
    local hints="$REPO_ROOT/ci/data/non-english-hints.txt"
    local files hits=0
    files=$(git ls-files '*.md' '*.rs' '*.toml' '*.sh' '*.js' '*.html' 2>/dev/null \
            | grep -v '^LICENSE' | grep -v '^ci/data/' || true)
    [ -z "$files" ] && { skip "no tracked text files yet"; return; }

    # Signal 1: non-ASCII LETTERS. Typographic punctuation is excluded — em
    # dashes, curly quotes, arrows and box drawing are ordinary English
    # typography, and flagging them made this check fire on every file in the
    # repository. A check that flags everything is a check that gets ignored,
    # which is worse than no check at all.
    local typography='\x{2014}\x{2013}\x{2018}\x{2019}\x{201C}\x{201D}\x{201E}\x{2026}\x{00B0}\x{00B2}\x{00D7}\x{00B7}\x{2192}\x{2190}\x{2191}\x{2193}\x{2264}\x{2265}\x{2260}\x{2022}\x{00A0}\x{2500}-\x{257F}\x{2588}\x{25B8}\x{25BC}\x{2713}\x{2717}'

    # Signal 2: unambiguous non-English words, from ci/data/non-english-hints.txt.
    local words
    words=$(grep -v '^#' "$hints" 2>/dev/null | grep -v '^[[:space:]]*$' | sort -u | paste -sd'|' -)

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local flagged=0

        local nonascii
        nonascii=$(grep -nP "[^\x00-\x7F${typography}]" "$f" 2>/dev/null | head -3 || true)
        if [ -n "$nonascii" ]; then
            info "non-ASCII letters in $f"
            while IFS= read -r l; do detail "${l:0:110}"; done <<< "$nonascii"
            flagged=1
        fi

        if [ -n "$words" ]; then
            local fr
            fr=$(grep -nEiw "($words)" "$f" 2>/dev/null | head -3 || true)
            if [ -n "$fr" ]; then
                info "non-English words in $f"
                while IFS= read -r l; do detail "${l:0:110}"; done <<< "$fr"
                flagged=1
            fi
        fi

        [ "$flagged" -eq 1 ] && hits=$((hits+1))
    done <<< "$files"

    if [ "$hits" -eq 0 ]; then
        pass "no non-English text detected"
    else
        # Advisory by constitutional design: no script detects language
        # reliably, so this never fails a build. Binding in review.
        pass "$hits file(s) flagged for reviewer judgement (advisory, never blocking)"
    fi
}

# ---------------------------------------------------------------------------
# Invariants awaiting their milestone.
# ---------------------------------------------------------------------------
check_pending_invariant() {
    local id="$1" num="$2" from="$3" what="$4"
    heading "Invariant $num — $id"
    if milestone_reached "$from"; then
        fail "milestone $from reached but no check is implemented for '$id'"
        detail "an invariant past its milestone with no enforcement is the worst state to be in"
    else
        pending "enforced from $from — until then, enforced by reviewer-constitution"
        detail "$what"
    fi
}

# ---------------------------------------------------------------------------
# Amendment simulation.
# Demonstrates that entrenched clauses cannot be changed by ordinary vote —
# including the amendment procedure itself.
# ---------------------------------------------------------------------------
simulate_amendment() {
    local target="$1"
    heading "Amendment simulation: '$target'"

    local known
    known=$(toml_get "$CONST" "[i['id'] for i in d['invariant']] + ['amendment','roadmap_priorities']")
    if ! echo "$known" | grep -qx "$target"; then
        die "unknown invariant '$target'. Known: $(echo "$known" | tr '\n' ' ')"
    fi

    local entrenched
    entrenched=$(toml_get "$CONST" "'$target' in d['amendment']['tier_entrenched']['applies_to']")

    if [ "$entrenched" = "true" ]; then
        local frac cycles
        frac=$(toml_get   "$CONST" "d['amendment']['tier_entrenched']['supermajority_fraction']")
        cycles=$(toml_get "$CONST" "d['amendment']['tier_entrenched']['cycles_required']")
        fail "REFUSED — '$target' is entrenched"
        detail "requires: $(python3 -c "print(int(float('$frac')*100))")% supermajority AND BDFL assent"
        detail "requires: $cycles cycles, never the cycle in which it was proposed"
        detail "an ordinary vote cannot change this clause"
        [ "$target" = "amendment" ] && \
            detail "note: the amendment procedure entrenches itself — without that, a captured majority amends this in one cycle and everything else in the next"
        return 1
    else
        pass "PERMITTED by ordinary vote — '$target' is not entrenched"
        detail "requires: majority, 1 cycle, no BDFL assent"
        return 0
    fi
}

# ---------------------------------------------------------------------------

list_checks() {
    heading "Constitutional invariants"
    python3 -c "
import tomllib
d = tomllib.load(open('$CONST','rb'))
reached = set(d['milestones']['reached'])
for i in d['invariant']:
    state = 'enforced' if i['enforced_from'] in reached else 'pending  '
    ent = 'entrenched' if i['entrenched'] else '          '
    print(f\"  {i['number']:2}. {i['id']:26} {ent}  {state}  from {i['enforced_from']}  ({i['enforcement']})\")
"
}

run_all() {
    check_prose_sync
    check_provenance
    check_hal_boundary
    check_no_kernel_deps
    check_english
    check_pending_invariant "no_ambient_authority" 1 "M4" \
        "capability confinement cannot be tested before capabilities exist"
    check_pending_invariant "user_sovereignty" 2 "M5" \
        "see/revoke/refuse cannot be tested before the ledger and veto exist in the kernel"
    check_pending_invariant "zero_telemetry" 5 "M6" \
        "no outbound path can be verified absent before a network stack exists"
    check_pending_invariant "agents_do_not_vote" 9 "G3" \
        "no ballots exist until the vote opens"
    summary "constitution:"
}

main() {
    case "${1:-}" in
        "")                    run_all ;;
        --list|-l)             list_checks ;;
        --simulate-amendment)  [ $# -ge 2 ] || die "usage: $0 --simulate-amendment <invariant>"
                               simulate_amendment "$2" ;;
        --check|-c)
            [ $# -ge 2 ] || die "usage: $0 --check <id>"
            case "$2" in
                prose-sync)      check_prose_sync ;;
                provenance)      check_provenance ;;
                hal-boundary)    check_hal_boundary ;;
                no-kernel-deps)  check_no_kernel_deps ;;
                english)         check_english ;;
                zero-telemetry)  check_pending_invariant "zero_telemetry" 5 "M6" \
                                     "no outbound path can be verified absent before a network stack exists" ;;
                electorate)      check_pending_invariant "agents_do_not_vote" 9 "G3" \
                                     "no ballots exist until the vote opens" ;;
                *) die "unknown check '$2' (try --list)" ;;
            esac
            summary "check:" ;;
        --help|-h)
            sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
}

main "$@"
