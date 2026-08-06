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
# Invariant 6, second half — reach by name
#
# RFC-0002 O-12. check_hal_boundary above greps for seven spellings of "this
# code is architecture-specific": core::arch::, asm!, naked_asm!, global_asm!
# and three more. A `#[link_name]` extern contains none of them, so a portable
# file can bind any symbol in the image and call it, and that check stays
# green. Measured on three separate images built for the purpose, plus a
# fourth reaching the vector table on main: each printed to the PL011 or
# powered the machine off, from a file with no asm, no core::arch, no
# target_arch, no cfg and no constructor. hal-boundary passed all four.
#
# That is O-10 one check over — a check standing in for a fact about ADDRESSES
# by matching TEXT — which is what makes it a class rather than a gap.
#
# The remedy RFC-0002 asks for is an intersection: the symbols a portable
# translation unit references, against the symbols defined in arch/. THAT IS
# NOT WHAT THIS CHECKS, and the difference is worth stating rather than
# blurring. Rust compiles this crate as one translation unit — the profile
# pins `lto = true` and `codegen-units = 1`, and `--emit=obj` yields a single
# object even at `-C codegen-units=16` — so there is no portable object file
# to take undefined symbols from. Measured, not assumed.
#
# What is checkable is the mechanism instead of the intent, and it happens to
# be closed rather than a list: binding a name at link time from safe portable
# Rust requires an `extern` block. There is no second spelling. So the rule is
# that a portable file declares none — which is the state of the tree today,
# on main and on the branch, in all three portable files, and which every one
# of the four demonstrated reach-arounds had to break to work.
#
# WHAT THIS DOES NOT CATCH, stated because an unstated limit is how the check
# above came to be trusted for something it never did: a raw address cast.
# Nothing stops portable code writing `(0x4008_0000 as *const fn())`, and
# nothing here would see it. That is not a symbol reach and closing it needs
# capabilities, which is M4. This bounds the named route only.
check_reach_around() {
    heading "Invariant 6 — reach by name"
    if ! kernel_exists; then
        pending "no kernel yet; enforced from M0"
        return
    fi

    local hal_dir portable hits=0
    hal_dir=$(toml_get "$CONST" "[i for i in d['invariant'] if i['id']=='hal_boundary'][0]['hal_dir']")
    portable=$(find kernel/src -name '*.rs' -not -path "$hal_dir/*" | sort)
    if [ -z "$portable" ]; then
        fail "no portable kernel sources found outside $hal_dir — the check cannot have passed"
        return
    fi

    local f decls
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        # Declarations only. A comment line mentioning one is a mention, and
        # the exclusion is anchored after grep's `path:lineno:` prefix — the
        # same mistake the check above documents having made.
        decls=$(grep -nE '^[[:space:]]*(unsafe[[:space:]]+)?extern[[:space:]]+"' "$f" \
                | grep -vE '^[0-9]+:[[:space:]]*(//|\*|/\*)' || true)
        if [ -n "$decls" ]; then
            fail "$f declares an extern block — a portable file must bind no symbol by name"
            # Every line. No ceiling: the exemption list in this file printed
            # three of four once, and a truncated violation list is worse.
            while IFS= read -r d; do detail "$f:$d"; done <<< "$decls"
            hits=$((hits+1))
        fi
    done <<< "$portable"

    if [ "$hits" -eq 0 ]; then
        pass "no portable kernel file binds a symbol by name ($(echo "$portable" | grep -c .) file(s) checked)"
        detail "bounds the named route only — a raw address cast is not visible here, and needs M4"
    else
        detail "RFC-0002 section 5: the design bounds effect, not reach. Do not add a second route"
    fi
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
# The instant from which unnamed attributions became a failure rather than a
# report. A date, not a commit: a branch's commits are not ancestors of main, so
# a commit-range baseline excludes none of them. Widening a rule cannot retroactively condemn what was written before
# it — see the note in the loop below.
LEAK_BASELINE_DATE="2026-08-05T09:30:03+04:00"

check_panel_leak() {
    heading "No judge named beside a verdict in a contribution's own artefacts"

    # Named judges, and UNNAMED ones.
    #
    # De-naming is not de-attributing. Three judges reported, separately, that
    # this check is blind to "four judges found it independently", "a reviewer
    # reproduced exactly that", "three Guardians approved" — none of which
    # contains a name, all of which tell the next judge how an earlier panel
    # ruled. SEPARATION_OF_POWERS.md forbids carrying another judge's "verdict,
    # direction, or reasoning", and a count is a direction.
    #
    # The second alternation is deliberately narrow: a quantifier or article
    # immediately before a role word. "review found" and "review measured" stay
    # legal, because a finding with no agent attached is the form this project
    # wants — the defect described, the finder not.
    local _leak_mentions; _leak_mentions=$(mktemp)
    local judges='guardian-[0-9]+|reviewer-(safety|conformance|constitution)'
    judges="$judges"'|(a|an|the|one|two|three|four|five|six|both|all|every|several|multiple|independent) (judges?|reviewers?|guardians?|panel)'

    # A role word beside a finding verb is an attribution ON ITS OWN, and needs
    # no verdict word to pair with. "Two judges found it independently" sat green
    # past the baseline for exactly that reason: `found` was in this pattern and
    # not in the verdict one, so there was nothing for it to match against.
    # Sentences of this shape are matched separately, below.
    # Use versus mention.
    #
    # Review tested this rather than arguing it: an asserted attribution failed
    # (right), the same string quoted and framed as a removal failed, a commit
    # message quoting a line it had deleted failed, and only class-only
    # description or plain paraphrase passed. So the practice this repository
    # adopted — describe the class, never the text — was not a choice. It was the
    # only form this check permitted, and the check was stricter than the rule it
    # enforces: SEPARATION_OF_POWERS.md asks for description without attribution,
    # not for silence about what was removed.
    #
    # A rule stricter than its own statement is a rule nobody can reason about.
    # Quoted spans are therefore removed before matching, so that recording what
    # was deleted is possible — and the mention branch is REPORTED, because a
    # quotation is still a place a leak can hide and an unread exemption is how
    # every fail-open in this repository began.
    # Fails LOUDLY, and reports what it exempted.
    #
    # The first version discarded stderr and was called with `2>/dev/null`, so an
    # unavailable interpreter turned two real failures into a silent PASS — review
    # measured exactly that. An absence read as the thing being checked, in the
    # file that names that defect three times, introduced by the commit that named
    # it. And backticks were stripped as mentions, so a leak wrapped in code
    # quotes was exempt: only double quotes frame a mention now.
    _strip_mentions() {
        command -v python3 >/dev/null 2>&1 || {
            echo "ci/constitution-check.sh: python3 unavailable — the mention" \
                 "stripper cannot run, and this check will not pass by default" >&2
            exit 70
        }
        python3 -c '
import re, sys
t = sys.stdin.read()
mentioned = []
def take(m):
    mentioned.append(m.group(0))
    return " [quoted] "
t = re.sub(r"\"[^\"\n]{0,200}\"", take, t)
sys.stdout.write(t)
for q in mentioned:
    sys.stderr.write(q + "\n")
'
    }

    local selfstanding='(a|an|the|one|two|three|four|five|six|both|all|every|several|multiple|independent) +(judges?|reviewers?|guardians?|panel(list)?s?) +(found|reported|measured|noted|flagged|refused|approved|rejected|verified|agreed|caught|raised|said|demonstrated|disagreed)'
    selfstanding="$selfstanding"'|(judges?|reviewers?|guardians?|panel(list)?s?) +(found|reported|measured|refused|approved|rejected|demonstrated|disagreed) +(it|that|this|the)'
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

    # 1. Task files and kernel source — but only what a contribution ADDS.
    #
    #    Two lessons are folded in here. Kernel source was outside this check
    #    entirely until an attribution turned up in link.ld, a file the author's
    #    own verification had missed by grepping `--include='*.rs'`. And the
    #    first version that did reach it failed on a task file's acceptance
    #    criterion — the criterion that asks for attributions to be REMOVED,
    #    which cannot be written without quoting the thing it forbids. A rule
    #    that condemns its own statement is a rule nobody can obey.
    #
    #    So this half judges added lines, not files: what is already in the tree
    #    is main's to answer for, and a contribution answers for what it brings.
    #    Pre-existing matches are reported so they do not vanish.
    local hits pre
    if git rev-parse --verify --quiet main >/dev/null 2>&1 && [ -n "${SKYNET_BASE:-main}" ]; then
        # Added lines, joined per hunk for the same reason as above: an
        # attribution split across two added lines is one sentence, not two.
        hits=$(git diff "${SKYNET_BASE:-main}...HEAD" -- tasks/ kernel/ 2>/dev/null \
               | grep -E '^(\+|@@)' | grep -v '^+++' | sed 's/^+//' \
               | awk '/^@@/ { if (buf!="") print buf; buf=""; next } { buf = buf " " $0 } END { if (buf!="") print buf }' \
               | grep -niE "($judges)" | grep -iE "($verdicts)" || true)
        pre=$(grep -rniE "($judges)" tasks/ kernel/ 2>/dev/null \
              | grep -v '^kernel/target/' | grep -iE "($verdicts)" | grep -c . || true)
    else
        hits=""
        pre=$(grep -rniE "($judges)" tasks/ kernel/ 2>/dev/null \
              | grep -v '^kernel/target/' | grep -iE "($verdicts)" | grep -c . || true)
    fi
    [ "${pre:-0}" -gt 0 ] && info "$pre line(s) already in the tree — reported, not failed"
    if [ -n "$hits" ]; then
        fail "this contribution ADDS a judge attribution to a task file or kernel source"
        while IFS= read -r h; do detail "$h"; done <<< "$hits"
        found=1
    fi

    # 2. Commit messages on contribution branches, from LEAK_BASELINE forward.
    #
    #    The baseline exists for the same reason ci/ledger-schema.py is versioned.
    #    Widening this pattern to catch unnamed attributions — "four judges found
    #    it", "three Guardians approved" — immediately reddened commit messages
    #    written before the rule existed, on a branch already under review. There
    #    are two dishonest ways out: hold the check until it is convenient, or
    #    rewrite the history it flags. Rewriting has already destroyed thirteen
    #    messages on one branch, and holding a rule until it costs nothing is the
    #    manoeuvre this whole project exists to prevent.
    #
    #    So the rule binds forward. Older messages are reported and do not fail;
    #    they are history, and history is not editable here.
    local br
    for br in $(git for-each-ref --format='%(refname:short)' 'refs/heads/task/*' 2>/dev/null); do
        local old
        old=$(git log --until="$LEAK_BASELINE_DATE" --format='%h %s%n%b' "main..$br" 2>/dev/null \
              | grep -niE "($judges)" | grep -iE "($verdicts)" || true)
        if [ -n "$old" ]; then
            local n; n=$(printf '%s\n' "$old" | grep -c . || true)
            info "$br: $n line(s) predate LEAK_BASELINE — reported, not failed"
        fi
        local msgs
        # Joined into paragraphs before matching, not read line by line.
        #
        # A judge found "Two judges found it independently" sitting past the
        # baseline and green, because the role word and the verdict word landed
        # on either side of a line break and both greps are per-line. Three
        # earlier misses have the same cause. Prose wraps; the rule is about the
        # sentence, so the text is unwrapped before the rule is applied.
        msgs=$(git log --since="$LEAK_BASELINE_DATE" --format='%h %s%n%b%n@@' "main..$br" 2>/dev/null \
               | awk '{ if ($0=="@@") { print buf; buf="" } else { buf = buf " " $0 } } END { print buf }' \
               | _strip_mentions 2>>"$_leak_mentions" | grep -niE "($judges)" | grep -iE "($verdicts)" || true)
        msgs="$msgs
$(git log --since="$LEAK_BASELINE_DATE" --format='%h %s%n%b%n@@' "main..$br" 2>/dev/null \
  | awk '{ if ($0=="@@") { print buf; buf="" } else { buf = buf " " $0 } } END { print buf }' \
  | _strip_mentions 2>>"$_leak_mentions" | grep -niE "($selfstanding)" || true)"
        msgs=$(printf '%s\n' "$msgs" | grep -v '^$' || true)
        [ -n "$msgs" ] || continue
        fail "commit messages on $br name a judge beside a verdict"
        while IFS= read -r m; do detail "$m"; done <<< "$msgs"
        found=1
    done

    local _mentions; _mentions=$(grep -c . "$_leak_mentions" 2>/dev/null || echo 0)
    if [ "${_mentions:-0}" -gt 0 ]; then
        info "$_mentions quoted span(s) exempted as mentions — an unread exemption is how every fail-open here began"
        # Every exemption, or the count of what is being withheld and why.
        #
        # This printed `head -3` under a comment three hundred lines above
        # promising it "reports what it exempted". At four exemptions the fourth
        # was invisible: the check announced a number and showed less than the
        # number, which is the unread exemption the sentence beside it warns
        # about, in the branch that wrote the sentence.
        #
        # There is no ceiling now. A silent truncation of the exemption list is
        # the one output in this file that must never be shortened for tidiness —
        # if it is ever bounded again, the bound has to print what it dropped.
        while IFS= read -r q; do detail "exempt: $(printf '%s' "$q" | cut -c1-90)"; done < "$_leak_mentions"
    fi
    rm -f "$_leak_mentions"
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
    check_reach_around
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
                reach-around)    check_reach_around ;;
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
