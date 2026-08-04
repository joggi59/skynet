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
        #
        # The comment exclusion matches after the `path:lineno:` prefix that
        # `grep -rnF` emits, not at the start of the line. Anchoring it with
        # '^\s*//' matched nothing at all, so every comment mentioning a
        # forbidden construct was reported as a violation (RFC-0001, O-6).
        local hits
        hits=$(grep -rnF -- "$construct" kernel/src 2>/dev/null \
               | grep -v "^$hal_dir/" \
               | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
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
# Architectural preconditions the linker will not enforce.
#
# Not a constitutional invariant — a class of defect that links silently and
# fails catastrophically at runtime. reviewer-safety asked for this by name after
# C-0004: "the two .align directives are the only thing between this table and
# silently vectoring into _start, and nothing in the repository checks either."
#
# VBAR_EL1's low eleven bits are RES0. A vector table that is not 2 KiB aligned
# does not fail to link, does not warn, and does not fault — the processor simply
# truncates the address and vectors somewhere else, which on this image is the
# middle of _start.
# ---------------------------------------------------------------------------
check_vector_alignment() {
    heading "Vector table alignment"
    if ! kernel_exists; then
        pending "no kernel yet"
        return
    fi
    local bin; bin="$(kernel_binary)"
    if [ ! -f "$bin" ]; then
        pending "kernel not built — run ci/build.sh first"
        return
    fi
    if ! command -v readelf >/dev/null 2>&1; then
        pending "readelf not available"
        return
    fi

    # The SECTION address, not a symbol name.
    #
    # An earlier version of this check looked up `vector_table` with nm. The
    # contribution it was written for then dropped `#[no_mangle]` — for good
    # reasons, since the unmangled symbol let portable code link to the handler —
    # and the check went blind, reporting SKIP on an image that has a vector
    # table. A check that stops seeing the thing it checks is worse than no
    # check, because it reports success.
    #
    # The section address is what VBAR_EL1 is loaded with, and it does not depend
    # on how Rust chose to name anything.
    # Parsed relative to the PROGBITS marker, not by column position: readelf's
    # columns shift with the section name's length, and the two-line default
    # layout puts the SIZE where a column count expects the address. The first
    # version of this parse reported the size as the address and failed a
    # correctly aligned table.
    local addr
    addr=$(readelf -SW "$bin" 2>/dev/null \
           | awk '/[. ]vectors/ { for (i = 1; i <= NF; i++) if ($i == "PROGBITS") { print $(i+1); exit } }')
    if [ -z "$addr" ]; then
        skip "no .vectors section in the image yet"
        return
    fi

    if python3 -c "import sys; sys.exit(0 if int('$addr',16) % 2048 == 0 else 1)"; then
        pass "vector table section at 0x$addr is 2 KiB aligned"
    else
        fail "vector table section at 0x$addr is NOT 2 KiB aligned"
        detail "VBAR_EL1's low 11 bits are RES0 — the processor will truncate this"
        detail "address and vector somewhere else, silently, with no fault and no warning"
    fi
}

# ---------------------------------------------------------------------------
# Invariant 1, the part that can be checked before M4 — where authority is minted.
#
# Three consecutive cycles closed one route into the failure module and revealed
# another: pub constructors, then pub fail_stop, then pub fault_stop, then a
# link_name route to the mangled symbol. Each fix was correct and each was
# discovered by a reviewer compiling the counter-example, because nothing
# mechanical was watching.
#
# reviewer-constitution named the shape of the problem — "the ratchet has no
# detent" — and wrote this check to demonstrate it was buildable. It was right
# that it was, and right that it should have existed already.
#
# This does not enforce invariant 1. Invariant 1 needs capabilities, which arrive
# at M4. What it enforces is narrower and useful now: authority is minted only
# where the design says it is, and a new site has to be argued for rather than
# discovered later by someone writing a probe.
# ---------------------------------------------------------------------------
check_minting_sites() {
    heading "Invariant 1 (partial) — where authority is minted"
    if ! kernel_exists; then
        pending "no kernel yet; the full invariant is enforced from M4"
        return
    fi

    # The constructors that hand out authority over a device.
    local minters='BootConsole::new|PowerControl::new'
    # The files the design permits to call them, and why.
    local allowed='kernel/src/arch/aarch64/(boot|fail)\.rs'

    local hits violations=0
    hits=$(grep -rnE "($minters)" kernel/src --include='*.rs' 2>/dev/null \
           | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|///|\*)' \
           | grep -vE "^$allowed:" || true)

    if [ -n "$hits" ]; then
        fail "authority minted outside boot.rs and fail.rs"
        while IFS= read -r h; do detail "$h"; done <<< "$hits"
        detail "the design permits exactly two: the boot path, and the failure path"
        violations=1
    fi

    # Count them, so a site appearing inside an allowed file is visible too. A
    # number that changes without an RFC saying why is the ratchet turning.
    local n
    n=$(grep -rnE "($minters)" kernel/src --include='*.rs' 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|///|\*)' | grep -c . || true)

    if [ "$violations" -eq 0 ]; then
        pass "authority minted only in boot.rs and fail.rs — $n call site(s)"
        detail "a change to that count belongs in an RFC before it belongs in a diff"
    fi
}

# ---------------------------------------------------------------------------
# The kernel reaches main only through the gate.
#
# governance/roles.toml says main has exactly one writer. Nothing checked it.
# A reviewer measured that thirty-two commits on main this session were not the
# gate's — all infrastructure, none kernel, but nothing distinguished the two.
#
# This is the constraint with teeth on the orchestrator role: it may write ci/,
# governance/, roadmap/, rfcs/ and forge/ directly, and it may not put a byte of
# kernel/ on main except by merging a contribution the gate approved.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# No judge is named next to a verdict in anything a judge reads.
#
# governance/SEPARATION_OF_POWERS.md states this rule and lists the artefacts it
# covers. It has now been broken three times, twice after being written down:
# commit messages naming a verdict while the rest of the panel was still
# deliberating, and a task file carrying "guardian-1 rejected C-0005 over it" in
# a comment beside the field it explained.
#
# Every instance was caught by a judge. None was caught by anything mechanical,
# and a rule enforced only by the party it constrains is a preference.
#
# The check is deliberately narrow. It looks at contribution-scoped artefacts —
# task files, and the commit messages on a contribution branch — because those
# are what a judge reads ABOUT THE CONTRIBUTION IT IS RULING ON. Governance
# documents and the ledger name judges and verdicts constantly, and must: the
# ledger IS the published record, and this file's own comment above would trip a
# broader rule. Scope, not vocabulary, is what separates the record from the leak.
# ---------------------------------------------------------------------------
check_panel_leak() {
    heading "No judge named beside a verdict in a contribution's own artefacts"

    local judges='guardian-[0-9]+|reviewer-(safety|conformance|constitution)'
    # Vocabulary, and the reason it is this wide.
    #
    # The first version matched approv|reject|refus|dissent|verdict|blocking
    # finding, and PASSED on a branch carrying seven attributions — because the
    # messages wrote bare severity labels: "BLOCKING, from reviewer-constitution
    # and independently from guardian-3", "MAJOR, from reviewer-safety". None of
    # those words appear. A two-word phrase like "blocking finding" is a
    # near-miss waiting to happen; the word alone is the signal.
    #
    # Two judges found the seven lines this missed. The check reported PASS.
    local verdicts='approv|reject|refus|dissent|verdict|blocking|major|minor|finding|flagged|raised'
    local found=0

    # 1. Task files AND kernel source — every versioned artefact a judge reads
    #    while ruling on a contribution.
    #
    #    Kernel source was outside this check until a reviewer found an
    #    attribution in link.ld and a second one added, in the same file, by the
    #    commit that claimed to have removed the last of them. The author's own
    #    verification had grepped `--include='*.rs'`; the linker script sits in
    #    the same directory and is not Rust. An absence read as the thing being
    #    checked, in the check written to stop that.
    local hits
    hits=$(grep -rniE "($judges)" tasks/ kernel/ 2>/dev/null \
           | grep -v '^kernel/target/' | grep -iE "($verdicts)" || true)
    if [ -n "$hits" ]; then
        fail "a task file or kernel source names a judge beside a verdict"
        while IFS= read -r h; do detail "$h"; done <<< "$hits"
        found=1
    fi

    # 2. Commit messages on contribution branches. The first instance of this
    #    leak was here, and `git log` is the first thing a judge runs.
    local br
    for br in $(git for-each-ref --format='%(refname:short)' 'refs/heads/task/*' 2>/dev/null); do
        local msgs
        msgs=$(git log --format='%h %s%n%b' "main..$br" 2>/dev/null \
               | grep -niE "($judges)" | grep -iE "($verdicts)" || true)
        [ -n "$msgs" ] || continue
        fail "commit messages on $br name a judge beside a verdict"
        while IFS= read -r m; do detail "$m"; done <<< "$msgs"
        found=1
    done

    if [ "$found" -eq 0 ]; then
        pass "no judge attributed in a task file or a contribution branch's history"
        detail "the record belongs in .provenance/ledger.jsonl, where every judge is named on purpose"
    else
        detail "describe the defect; do not attribute it. SEPARATION_OF_POWERS.md — the repository is inside the room"
    fi
}

check_kernel_provenance() {
    heading "The kernel reaches main only through the gate"
    if ! git rev-parse --verify main >/dev/null 2>&1; then
        skip "no main branch"
        return
    fi

    # The empty tree, for the root commit — which has no parent, so `$h^` does not
    # resolve and `git diff-tree` fails. The first version of this check read that
    # failure as "the kernel changed" and flagged the genesis commit, which touches
    # no kernel file at all.
    #
    # That is the same defect three reviewers have now found in three different
    # checks: an absence read as the thing being checked. It is recorded here
    # rather than quietly fixed, because it happened in the check written to
    # constrain the role that keeps producing it.
    local empty; empty=$(git hash-object -t tree /dev/null)

    local bad=0 n=0
    while IFS='|' read -r h subj; do
        [ -z "$h" ] && continue
        local parent
        parent=$(git rev-parse --verify --quiet "$h^" 2>/dev/null) || parent="$empty"
        # Did this first-parent step change kernel/ at all?
        git diff-tree --quiet "$parent" "$h" -- kernel 2>/dev/null && continue
        n=$((n+1))
        case "$subj" in
            *"merged by gate (contribution "*) ;;
            *)  fail "kernel changed on main outside a gate merge"
                detail "$h  $subj"
                bad=1 ;;
        esac
    done < <(git log --first-parent main --format='%h|%s' 2>/dev/null)

    if [ "$bad" -eq 0 ]; then
        pass "every kernel change on main came from a gate merge ($n merge(s))"
    fi
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
        # Validated against the schema for its OWN event type — see
        # ci/ledger-schema.py for why one field list made the ledger less true.
        if ! echo "$line" | python3 "$REPO_ROOT/ci/ledger-schema.py" >/tmp/.prov_err 2>&1; then
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
    check_vector_alignment
    check_minting_sites
    check_kernel_provenance
    check_panel_leak
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
                vector-alignment) check_vector_alignment ;;
                minting-sites)   check_minting_sites ;;
                kernel-provenance) check_kernel_provenance ;;
                panel-leak)      check_panel_leak ;;
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
