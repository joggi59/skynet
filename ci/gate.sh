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

    if [ "$found" -eq 0 ]; then
        fail "no Guardian verdicts — the panel has not ruled"
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

    local reviewers guardians
    # Findings are recorded, not only reasoning.
    #
    # The ledger previously kept the prose and discarded the findings array. For
    # invariants that are not yet mechanically enforced — capability confinement
    # until M4, user sovereignty until M5 — the reviewers ARE the enforcement,
    # and their findings are the only record that anyone examined the question.
    # Dropping them meant every such judgement between G0 and M4 was thrown away
    # at the moment it became permanent. Found by reviewer-constitution on the
    # first contribution, which had to write its whole argument into the prose
    # field to survive.
    reviewers=$(python3 -c "
import json,glob,os
out=[]
for f in sorted(glob.glob('$C_DIR/verdicts/reviewer-*.json')):
    d=json.load(open(f))
    out.append({'role':d['role'],'verdict':d['verdict'],
                'confidence':d.get('confidence'),
                'findings':d.get('findings',[]),
                'reasoning':d.get('reasoning','')})
print(json.dumps(out))")
    guardians=$(python3 -c "
import json,glob
out=[]
for f in sorted(glob.glob('$C_DIR/verdicts/guardian-*.json')):
    d=json.load(open(f))
    out.append({'verdict':d['verdict'],'confidence':d.get('confidence'),
                'serves_common_good':d.get('serves_common_good'),
                'within_non_goals':d.get('within_non_goals'),
                'findings':d.get('findings',[]),
                'reasoning':d.get('reasoning','')})
print(json.dumps(out))")

    local objfile weight wsrc
    objfile=$(ls "$REPO_ROOT/roadmap/${C_OBJECTIVE}-"*.toml 2>/dev/null | head -1)
    weight=$(toml_get "$objfile" "d['objective']['weight']")
    wsrc=$(toml_get   "$objfile" "d['objective']['weight_source']")

    info "merging $C_BRANCH into main ..."
    if ! git merge --no-ff --no-edit -m "$C_TASK: merged by gate (contribution $C_ID)" "$C_BRANCH" >/dev/null 2>&1; then
        git merge --abort >/dev/null 2>&1 || true
        fail "merge failed — conflict or dirty tree"
        return 1
    fi

    local commit; commit=$(git rev-parse HEAD)

    mkdir -p "$(dirname "$LEDGER")"
    python3 -c "
import json,sys,subprocess
entry = {
  'contribution_id': '$C_ID',
  'task':            '$C_TASK',
  'rfc':             '$C_RFC',
  'objective':       '$C_OBJECTIVE',
  'objective_weight': $weight,
  'weight_source':   '$wsrc',
  'agent':           '$C_AGENT',
  'model':           '$C_MODEL',
  'prompt_hash':     '$C_PROMPT_HASH',
  'reviewer_verdicts': json.loads('''$reviewers'''),
  'guardian_verdicts': json.loads('''$guardians'''),
  'evidence_digest': 'sha256:$evidence_digest',
  'constitution_version': $(toml_get "$CONST" "d['meta']['version']"),
  'commit':          '$commit',
  'merged_at':       subprocess.run(['git','log','-1','--format=%cI'],capture_output=True,text=True).stdout.strip(),
}
with open('$LEDGER','a') as f:
    f.write(json.dumps(entry, sort_keys=True) + '\n')
" || { fail "could not append to the ledger"; return 1; }

    git add "$LEDGER"
    git commit -q --amend --no-edit
    pass "merged as $(git rev-parse --short HEAD), ledger appended"
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
    cond_budgets; cond_hal; cond_deps
    cond_reviewers; cond_guardian; cond_provenance

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
                        deps) cond_deps ;; reviewers) cond_reviewers ;;
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
