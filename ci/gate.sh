#!/usr/bin/env bash
# The merge gate. The only writer of main.
#
#   ci/gate.sh <contribution-id>        run all ten conditions, merge if all pass
#   ci/gate.sh --dry-run <id>           run all ten, never merge
#   ci/gate.sh --check <name> [<id>]    run one condition
#   ci/gate.sh --veto <id> [--reason R] BDFL veto
#   ci/gate.sh --selftest               prove the gate's integrity properties
#   ci/gate.sh --list                   list the ten conditions
#
# This script is deliberately not an agent. It does not reason, cannot be
# persuaded, cannot be prompt-injected, and behaves identically on the ten
# thousandth contribution as on the first. Every judgement in this project is
# made by something that can be argued with; every enforcement is made by
# something that cannot. See governance/SEPARATION_OF_POWERS.md.
#
# Ten conditions. All mandatory. There is no --force, and adding one would
# defeat the purpose of the file.
#
# Exit 0 if merged (or dry-run passed), 1 if refused, 2 on usage error.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT" || die "cannot enter repo root"

CONST="$REPO_ROOT/constitution.toml"
FORGE_DIR="$REPO_ROOT/.forge/contributions"
LEDGER="$REPO_ROOT/.provenance/ledger.jsonl"
DRY_RUN=0

# ---------------------------------------------------------------------------
# Contribution record
# ---------------------------------------------------------------------------

contribution_dir() { echo "$FORGE_DIR/$1"; }

load_contribution() {
    local id="$1" dir; dir="$(contribution_dir "$id")"
    [ -d "$dir" ] || die "no contribution record at ${dir#$REPO_ROOT/}"
    [ -f "$dir/contribution.toml" ] || die "no contribution.toml in ${dir#$REPO_ROOT/}"
    C_DIR="$dir"
    C_ID="$id"
    C_TASK=$(toml_get      "$dir/contribution.toml" "d['contribution']['task']")
    C_RFC=$(toml_get       "$dir/contribution.toml" "d['contribution'].get('rfc','')")
    C_OBJECTIVE=$(toml_get "$dir/contribution.toml" "d['contribution']['objective']")
    C_AGENT=$(toml_get     "$dir/contribution.toml" "d['contribution']['agent']")
    C_MODEL=$(toml_get     "$dir/contribution.toml" "d['contribution']['model']")
    C_BRANCH=$(toml_get    "$dir/contribution.toml" "d['contribution']['branch']")
    C_PROMPT_HASH=$(toml_get "$dir/contribution.toml" "d['contribution'].get('prompt_hash','')")
    C_BRANCH_SHA=$(toml_get "$dir/contribution.toml" "d['contribution'].get('branch_sha','')")
    C_SIGNATURE=$(toml_get "$dir/contribution.toml" "d['contribution'].get('signature','')")

    # Where the mechanical conditions must run.
    #
    # The gate judges the CONTRIBUTION, not the branch it would merge into.
    # Running the checks in the repository root evaluates main, where the
    # contribution's code does not exist — every condition then reports PENDING
    # and the gate refuses for a reason that has nothing to do with the patch.
    #
    # The checks run in the contribution's worktree, which carries its code and
    # its own copy of ci/ merged up to date. The worktree's ci/ is used
    # deliberately: a contribution must be judged by the checks as they will
    # exist after it lands, not by whatever the root happens to have.
    C_WORKTREE=$(git worktree list --porcelain 2>/dev/null \
        | awk -v b="refs/heads/$C_BRANCH" '
            /^worktree /  { wt = $2 }
            /^branch /    { if ($2 == b) { print wt; exit } }')
    if [ -z "${C_WORKTREE:-}" ]; then
        C_WORKTREE="$REPO_ROOT"
    fi
}

# ---------------------------------------------------------------------------
# Conditions 1-4: mechanical. Delegated to the scripts that own them.
# ---------------------------------------------------------------------------

cond_build()  { heading "1. Build";       _absorb ci/build.sh; }
cond_lint()   { heading "2. Lint";        _absorb ci/build.sh --lint; }
cond_tests()  { heading "3. Unit tests";  _absorb ci/build.sh --test; }
cond_boot()   { heading "4. Boot";        _absorb ci/boot-test.sh; }
cond_budgets(){ heading "5. Budgets";     _absorb ci/build.sh --size; }
cond_hal()    { heading "6. HAL boundary";_absorb ci/constitution-check.sh --check hal-boundary; }
cond_deps()   { heading "7. Dependencies";_absorb ci/constitution-check.sh --check no-kernel-deps; }

# Checks that existed and that nothing could fail a merge over.
#
# reviewer-constitution measured it: "--check minting-sites is invoked by nothing
# that can fail a merge", and separately that a committed rewrite of the ledger
# passes because the gate never runs the append-only check. A check the gate does
# not run is documentation.
cond_authority() { heading "6b. Authority minting";  _absorb ci/constitution-check.sh --check minting-sites; }
cond_ledger()    { heading "10b. Ledger append-only"; _absorb ci/constitution-check.sh --check provenance; }
cond_kprov()     { heading "10c. Kernel provenance";  _absorb ci/constitution-check.sh --check kernel-provenance; }
# A check nothing in the merge path runs is a check a judge has to be the
# enforcement for. panel-leak was written, widened three times, and never wired
# here — so the only thing between an attribution and main was a Guardian
# noticing. One did, on a commit message written one minute after this branch
# merged the check itself.
cond_leak()      { heading "8b. Panel independence"; _absorb ci/constitution-check.sh --check panel-leak; }

# Run a sub-check in the contribution's worktree, echo its per-check lines, and
# fold its tallies into ours. The sub-scripts already speak PASS/FAIL/PENDING;
# we count what they printed rather than re-deriving it, so there is exactly one
# place each condition is decided.
_absorb() {
    local script="$1"; shift
    local wt="${C_WORKTREE:-$REPO_ROOT}"
    local out; out="$(cd "$wt" && "./$script" "$@" 2>&1)"
    echo "$out" | grep -vE '^─{5,}|^(build|boot|check|constitution):' | sed '/^$/d' | sed 's/^/  /'
    local p f n
    p=$(echo "$out" | grep -c '^PASS')
    f=$(echo "$out" | grep -c '^FAIL')
    n=$(echo "$out" | grep -c '^PENDING')
    CHECKS_PASS=$((CHECKS_PASS+p))
    CHECKS_FAIL=$((CHECKS_FAIL+f))
    CHECKS_PENDING=$((CHECKS_PENDING+n))
}

# ---------------------------------------------------------------------------
# Condition 8: reviewer quorum
#
# Strict: any reviewer rejection blocks, and any blocking finding blocks,
# regardless of how the other two voted. Rejection is the safe direction, and
# this is a kernel intended to run in cars. A 2-of-3 majority is enough to
# proceed only when nobody found something disqualifying.
# ---------------------------------------------------------------------------

cond_reviewers() {
    heading "8. Reviewer quorum"
    local expected=(reviewer-safety reviewer-conformance reviewer-constitution)
    local approve=0 reject=0 abstain=0 missing=0 blocking=0

    for r in "${expected[@]}"; do
        local f="$C_DIR/verdicts/$r.json"
        if [ ! -f "$f" ]; then
            fail "missing verdict from $r"
            missing=$((missing+1)); continue
        fi
        local v b
        v=$(python3 -c "import json;print(json.load(open('$f'))['verdict'])" 2>/dev/null) || {
            fail "malformed verdict from $r"; missing=$((missing+1)); continue; }
        b=$(python3 -c "
import json
d=json.load(open('$f'))
print(sum(1 for x in d.get('findings',[]) if x.get('severity')=='blocking'))" 2>/dev/null)
        case "$v" in
            approve) approve=$((approve+1)); info "$r: approve" ;;
            reject)  reject=$((reject+1));   info "$r: REJECT" ;;
            abstain) abstain=$((abstain+1)); info "$r: abstain" ;;
            *)       fail "$r returned an unknown verdict '$v'"; missing=$((missing+1)) ;;
        esac
        if [ "${b:-0}" -gt 0 ]; then
            blocking=$((blocking+b))
            detail "$r reported $b blocking finding(s)"
        fi
    done

    [ "$missing" -gt 0 ] && return
    if [ "$reject" -gt 0 ]; then
        fail "$reject reviewer rejection(s) — any rejection blocks"
    elif [ "$blocking" -gt 0 ]; then
        fail "$blocking blocking finding(s) — a blocking finding requires reject"
    elif [ "$approve" -ge 2 ]; then
        pass "reviewer quorum reached ($approve approve, $abstain abstain, 0 reject)"
    else
        fail "reviewer quorum not reached ($approve approve, needs 2 of 3)"
    fi
}

# ---------------------------------------------------------------------------
# Condition 9: Guardian quorum
#
# The Guardian may reject alone and may never approve alone. The second half of
# that is structural rather than arithmetic: an approval here is one of ten
# conditions, and this script requires all ten. There is no code path by which
# a Guardian approval merges anything on its own — see --selftest.
# ---------------------------------------------------------------------------

cond_guardian() {
    heading "9. Guardian quorum"
    local panel approve_quorum
    panel=$(toml_get          "$CONST" "[g for g in d['gate_condition'] if g['id']=='guardian'][0]['panel_size']")
    approve_quorum=$(toml_get "$CONST" "[g for g in d['gate_condition'] if g['id']=='guardian'][0]['approve_quorum']")

    local approve=0 reject=0 abstain=0 found=0
    for i in $(seq 1 "$panel"); do
        local f="$C_DIR/verdicts/guardian-$i.json"
        [ -f "$f" ] || continue
        found=$((found+1))
        local v
        v=$(python3 -c "import json;print(json.load(open('$f'))['verdict'])" 2>/dev/null) || {
            fail "malformed verdict from guardian-$i"; continue; }
        case "$v" in
            approve) approve=$((approve+1)); info "guardian-$i: approve" ;;
            reject)  reject=$((reject+1));   info "guardian-$i: REJECT" ;;
            abstain) abstain=$((abstain+1)); info "guardian-$i: abstain" ;;
            *)       fail "guardian-$i returned an unknown verdict '$v'" ;;
        esac
    done

    # The WHOLE panel must have ruled, not merely enough of it to reach quorum.
    #
    # The constitution grants a Guardian the power to reject alone. That power is
    # worthless if the gate proceeds before every member has spoken: a judge
    # still deliberating cannot exercise a veto over a merge that already
    # happened. This condition counted the verdicts that existed, so C-0003
    # merged on two of three while the third was still reading.
    #
    # approve_quorum is how many must APPROVE, not how many need to answer.
    if [ "$found" -lt "$panel" ]; then
        fail "only $found of $panel Guardian verdicts — the panel has not finished"
        detail "a Guardian may reject alone; that power requires waiting for it"
        return
    fi
    if [ "$reject" -gt 0 ]; then
        fail "$reject Guardian rejection(s) — the Guardian may reject alone"
        detail "reasoning is recorded in the contribution record and published"
        return
    fi
    if [ "$approve" -ge "$approve_quorum" ]; then
        pass "Guardian quorum reached ($approve approve, $abstain abstain, of panel $panel)"
    else
        fail "Guardian quorum not reached ($approve approve, needs $approve_quorum of $panel)"
    fi
}

# ---------------------------------------------------------------------------
# Condition 10: provenance
# ---------------------------------------------------------------------------

cond_provenance() {
    heading "10. Provenance"
    local ok=1

    # The verdicts describe a tree. If the branch moved after they were cast,
    # they describe something that no longer exists.
    #
    # A reviewer caught this happening — the worktree was being rewritten while
    # it measured — and defended itself by working from clean extractions of the
    # committed tree. A judge protecting itself from the party assembling its
    # brief is not a control, so this is one.
    if [ -n "${C_BRANCH_SHA:-}" ]; then
        local now; now=$(git rev-parse "$C_BRANCH" 2>/dev/null)
        if [ "$now" != "$C_BRANCH_SHA" ]; then
            fail "the branch moved after this contribution was submitted"
            detail "submitted: ${C_BRANCH_SHA:0:12}"
            detail "now:       ${now:0:12}"
            detail "every verdict was cast on a tree that no longer exists — resubmit"
            ok=0
        else
            info "branch unchanged since submission (${now:0:12})"
        fi
    else
        info "no branch pin — recorded before this check existed"
    fi
    for field in C_TASK C_OBJECTIVE C_AGENT C_MODEL C_BRANCH; do
        if [ -z "${!field:-}" ]; then
            fail "provenance field ${field#C_} is empty"
            ok=0
        fi
    done

    # The claimed objective must resolve to a real roadmap entry.
    local objfile
    objfile=$(ls "$REPO_ROOT/roadmap/${C_OBJECTIVE}-"*.toml 2>/dev/null | head -1)
    if [ -z "$objfile" ]; then
        fail "objective '$C_OBJECTIVE' does not resolve to any file in roadmap/"
        ok=0
    else
        local w src
        w=$(toml_get   "$objfile" "d['objective']['weight']")
        src=$(toml_get "$objfile" "d['objective']['weight_source']")
        info "objective $C_OBJECTIVE resolved — weight $w ($src)"
        [ "$src" = "bdfl-seed" ] && detail "seeded, not yet voted; recorded as such in the ledger"
    fi

    [ -z "${C_SIGNATURE:-}" ] && { info "unsigned — permitted only for internal forge roles before G4"; }

    [ "$ok" -eq 1 ] && pass "provenance record complete and well-formed"
}

# ---------------------------------------------------------------------------
# The merge. Reached only when all ten conditions passed.
# ---------------------------------------------------------------------------

do_merge() {
    heading "Merge"
    if [ "$DRY_RUN" -eq 1 ]; then
        skip "dry run — not merging"
        return 0
    fi

    git rev-parse --verify "$C_BRANCH" >/dev/null 2>&1 || die "branch '$C_BRANCH' does not exist"

    local evidence_digest
    evidence_digest=$(find "$C_DIR" -type f -print0 2>/dev/null \
        | sort -z | xargs -0 cat 2>/dev/null | sha256sum | cut -d' ' -f1)

    local objfile weight wsrc cver
    objfile=$(ls "$REPO_ROOT/roadmap/${C_OBJECTIVE}-"*.toml 2>/dev/null | head -1)
    weight=$(toml_get "$objfile" "d['objective']['weight']")
    wsrc=$(toml_get   "$objfile" "d['objective']['weight_source']")
    cver=$(toml_get   "$CONST"   "d['meta']['version']")

    # Refuse to run against a branch already contained in main. `git merge
    # --no-ff` answers "Already up to date" and creates nothing, so the ledger
    # would record the pre-merge commit and claim it was the merge.
    if git merge-base --is-ancestor "$C_BRANCH" HEAD 2>/dev/null; then
        fail "$C_BRANCH is already contained in main — nothing to merge"
        detail "a ledger line here would name a commit that is not the merge"
        return 1
    fi

    # ---- 1. Build the ledger entry BEFORE touching main -------------------
    #
    # Ordering is correctness, not preference. Merging first and writing
    # provenance second leaves main carrying a commit with no ledger line
    # whenever anything in between fails — exactly what invariant 3 forbids, and
    # exactly what happened the first time this ran for real.
    local entry="$C_DIR/ledger-entry.json" perr="$C_DIR/ledger-error.txt"
    if ! python3 "$REPO_ROOT/ci/ledger-entry.py" \
            "$C_DIR" "$C_ID" "$C_TASK" "$C_RFC" "$C_OBJECTIVE" "$weight" \
            "$wsrc" "$C_AGENT" "$C_MODEL" "$C_PROMPT_HASH" \
            "$evidence_digest" "$cver" "$entry" 2>"$perr"; then
        fail "could not build the ledger entry — nothing was merged"
        sed 's/^/           /' "$perr" | tail -5
        return 1
    fi

    # ---- 2. Merge --------------------------------------------------------
    local before; before=$(git rev-parse HEAD)
    info "merging $C_BRANCH into main ..."
    if ! git merge --no-ff --no-edit -m "$C_TASK: merged by gate (contribution $C_ID)" "$C_BRANCH" >/dev/null 2>&1; then
        git merge --abort >/dev/null 2>&1 || true
        fail "merge failed — conflict or dirty tree"
        return 1
    fi
    local merged; merged=$(git rev-parse HEAD)
    if [ "$merged" = "$before" ]; then
        fail "the merge produced no commit — refusing to record one"
        return 1
    fi

    # ---- 3. Append the ledger, as its own commit --------------------------
    #
    # Never --amend. Amending rewrites the merge commit's SHA, and the ledger
    # line has already recorded the SHA it describes, so the record ends up
    # naming a commit that no longer exists.
    mkdir -p "$(dirname "$LEDGER")"
    if ! python3 "$REPO_ROOT/ci/ledger-append.py" "$entry" "$LEDGER" 2>"$perr"; then
        fail "could not append to the ledger — undoing the merge"
        sed 's/^/           /' "$perr" | tail -5
        git reset --hard "$before" >/dev/null 2>&1
        detail "main must never carry a commit without a provenance line"
        return 1
    fi

    git add "$LEDGER"
    if ! git commit -q -m "ledger: record $C_ID ($C_TASK)"; then
        git reset --hard "$before" >/dev/null 2>&1
        fail "could not commit the ledger — the merge was undone"
        return 1
    fi
    pass "merged as $(git rev-parse --short "$merged"), ledger appended as $(git rev-parse --short HEAD)"
}

# ---------------------------------------------------------------------------
# Self-test: prove the gate's integrity properties on synthetic records.
# ---------------------------------------------------------------------------

selftest() {
    heading "Gate self-test"
    info "Each scenario constructs a contribution record and asserts the gate refuses it."
    echo

    local tmp; tmp="$REPO_ROOT/.forge/selftest"
    rm -rf "$tmp"; mkdir -p "$tmp"
    local failures=0

    _scenario() {
        local name="$1" want="$2"; shift 2
        local id="selftest-$name"
        local dir="$FORGE_DIR/$id"
        rm -rf "$dir"; mkdir -p "$dir/verdicts"
        cat > "$dir/contribution.toml" <<EOF
[contribution]
task = "T-0000"
objective = "0001"
agent = "selftest"
model = "none"
branch = "HEAD"
EOF
        "$@" "$dir"

        local out rc=0
        out=$(DRY_RUN=1 run_conditions_quiet "$id") || rc=$?

        if [ "$want" = "refuse" ] && [ "$rc" -ne 0 ]; then
            pass "$name -> refused, as required"
        elif [ "$want" = "allow" ] && [ "$rc" -eq 0 ]; then
            pass "$name -> allowed, as required"
        else
            fail "$name -> expected $want, got rc=$rc"
            failures=$((failures+1))
        fi
        rm -rf "$dir"
    }

    _verdict() { # file, role, verdict
        cat > "$1" <<EOF
{"role":"$2","contribution_id":"selftest","verdict":"$3","confidence":"high","findings":[],"reasoning":"selftest"}
EOF
    }

    # 1. The Guardian approves unanimously and no reviewer has ruled.
    _scenario "guardian-approves-alone" refuse _s_guardian_only
    # 2. Every reviewer approves and one Guardian rejects.
    _scenario "guardian-rejects-alone" refuse _s_guardian_rejects
    # 3. Everyone approves but a reviewer filed a blocking finding.
    _scenario "blocking-finding" refuse _s_blocking
    # 4. Everyone approves and the claimed objective does not exist.
    _scenario "unresolvable-objective" refuse _s_bad_objective

    echo
    if [ "$failures" -eq 0 ]; then
        info "The gate cannot be merged past by a Guardian alone, by a Guardian"
        info "overruling reviewers, by a blocking finding, or by an unmandated objective."
    fi
    rm -rf "$tmp"
    return "$failures"
}

_s_guardian_only()    { local d="$1"; for i in 1 2 3; do _verdict "$d/verdicts/guardian-$i.json" guardian approve; done; }
_s_guardian_rejects() { local d="$1"
    for r in safety conformance constitution; do _verdict "$d/verdicts/reviewer-$r.json" "reviewer-$r" approve; done
    _verdict "$d/verdicts/guardian-1.json" guardian approve
    _verdict "$d/verdicts/guardian-2.json" guardian approve
    _verdict "$d/verdicts/guardian-3.json" guardian reject; }
_s_blocking()         { local d="$1"
    for r in conformance constitution; do _verdict "$d/verdicts/reviewer-$r.json" "reviewer-$r" approve; done
    cat > "$d/verdicts/reviewer-safety.json" <<'EOF'
{"role":"reviewer-safety","contribution_id":"selftest","verdict":"approve","confidence":"low",
 "findings":[{"severity":"blocking","file":"x.rs","line":1,"issue":"unsound","why_it_matters":"selftest"}],
 "reasoning":"approve with a blocking finding — internally inconsistent, must not merge"}
EOF
    for i in 1 2 3; do _verdict "$d/verdicts/guardian-$i.json" guardian approve; done; }
_s_bad_objective()    { local d="$1"
    sed -i 's/objective = "0001"/objective = "9999"/' "$d/contribution.toml"
    for r in safety conformance constitution; do _verdict "$d/verdicts/reviewer-$r.json" "reviewer-$r" approve; done
    for i in 1 2 3; do _verdict "$d/verdicts/guardian-$i.json" guardian approve; done; }

# Run only the judgement conditions (8, 9, 10) quietly, for the self-test.
run_conditions_quiet() {
    ( CHECKS_PASS=0; CHECKS_FAIL=0; CHECKS_PENDING=0
      load_contribution "$1"
      cond_reviewers >/dev/null 2>&1
      cond_guardian  >/dev/null 2>&1
      cond_provenance >/dev/null 2>&1
      [ "$CHECKS_FAIL" -eq 0 ] )
}

# ---------------------------------------------------------------------------

do_veto() {
    local id="$1" reason="${2:-}"
    heading "BDFL veto"
    load_contribution "$id"
    mkdir -p "$(dirname "$LEDGER")"
    python3 -c "
import json,subprocess
entry={'contribution_id':'$id','task':'$C_TASK','objective':'$C_OBJECTIVE',
       'agent':'$C_AGENT','model':'$C_MODEL','reviewer_verdicts':[],'guardian_verdicts':[],
       'evidence_digest':'sha256:vetoed','event':'veto','vetoed_by':'bdfl',
       'reason':'''$reason''','merged_at':subprocess.run(['git','log','-1','--format=%cI'],
       capture_output=True,text=True).stdout.strip()}
open('$LEDGER','a').write(json.dumps(entry,sort_keys=True)+'\n')"
    fail "contribution $id vetoed"
    [ -n "$reason" ] && detail "reason: $reason" || detail "no reason given — permitted, and recorded as such"
    info "recorded in the ledger; a veto is a public act"
    return 1
}

list_conditions() {
    heading "The ten conditions"
    python3 -c "
import tomllib
d=tomllib.load(open('$CONST','rb'))
for g in d['gate_condition']:
    print(f\"  {g['number']:2}. {g['id']:12} {g['description']}\")
"
    echo
    info "All mandatory. There is no --force."
}

run_all() {
    local id="$1"
    load_contribution "$id"
    heading "Gate — contribution $C_ID"
    info "task $C_TASK   objective $C_OBJECTIVE   agent $C_AGENT   model $C_MODEL"
    info "branch $C_BRANCH"

    cond_build; cond_lint; cond_tests; cond_boot
    cond_budgets; cond_hal; cond_deps; cond_authority
    cond_reviewers; cond_leak; cond_guardian; cond_provenance; cond_ledger; cond_kprov

    echo
    if [ "$CHECKS_FAIL" -gt 0 ]; then
        printf '%sREFUSED%s  %d condition(s) failed. Nothing was merged.\n' "$C_FAIL" "$C_RESET" "$CHECKS_FAIL"
        summary "gate:"
        return 1
    fi
    if [ "$CHECKS_PENDING" -gt 0 ]; then
        printf '%sREFUSED%s  %d check(s) pending — a pending check is not a passing check.\n' \
            "$C_PEND" "$C_RESET" "$CHECKS_PENDING"
        info "install the missing toolchain, or land the milestone the check needs"
        summary "gate:"
        return 1
    fi
    do_merge || { summary "gate:"; return 1; }
    summary "gate:"
}

main() {
    case "${1:-}" in
        --list|-l)   list_conditions ;;
        --selftest)  selftest; summary "selftest:" ;;
        --dry-run)   [ $# -ge 2 ] || die "usage: $0 --dry-run <contribution-id>"
                     DRY_RUN=1; run_all "$2" ;;
        --veto)      [ $# -ge 2 ] || die "usage: $0 --veto <contribution-id> [--reason R]"
                     local reason=""; [ "${3:-}" = "--reason" ] && reason="${4:-}"
                     do_veto "$2" "$reason" ;;
        --check|-c)  [ $# -ge 2 ] || die "usage: $0 --check <name> [<contribution-id>]"
                     [ -n "${3:-}" ] && load_contribution "$3"
                     case "$2" in
                        build) cond_build ;; lint) cond_lint ;; tests) cond_tests ;;
                        boot) cond_boot ;; budgets) cond_budgets ;; hal) cond_hal ;;
                        deps) cond_deps ;; authority) cond_authority ;;
                        ledger) cond_ledger ;; kernel-provenance) cond_kprov ;;
                        panel-leak) cond_leak ;;
                        reviewers) cond_reviewers ;;
                        guardian) cond_guardian ;; provenance) cond_provenance ;;
                        *) die "unknown condition '$2' (try --list)" ;;
                     esac
                     summary "gate:" ;;
        --help|-h)   sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
        "")          die "usage: $0 <contribution-id>   (try --help)" ;;
        -*)          die "unknown option '$1' (try --help)" ;;
        *)           run_all "$1" ;;
    esac
}

main "$@"
