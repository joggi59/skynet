#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build a provenance ledger entry from a contribution record.
#
# A separate file rather than a heredoc inside ci/gate.sh: bash reads a script
# lazily as it executes, so a rollback that rewrites ci/gate.sh mid-run can
# leave the interpreter reading from a stale offset in changed content. Keeping
# the logic out of the shell script removes that class of failure.
#
# Verdict text never passes through a shell. Only scalars arrive, via argv.

import glob
import json
import os
import sys

(cdir, cid, task, rfc, objective, weight, wsrc,
 agent, model, phash, digest, cver, out) = sys.argv[1:]


def verdicts(pattern, keys):
    got = []
    for f in sorted(glob.glob(os.path.join(cdir, "verdicts", pattern))):
        with open(f, encoding="utf-8") as fh:
            d = json.load(fh)
        got.append({k: d.get(k) for k in keys})
    return got


# The specification pins travel into the ledger too. reviewer-constitution noted
# they lived only in the gitignored contribution record, so a merged line still
# identified its spec by bare number — the weakness pinning existed to remove.
pins = {}
ctoml = os.path.join(cdir, "contribution.toml")
if os.path.exists(ctoml):
    import tomllib
    with open(ctoml, "rb") as fh:
        c = tomllib.load(fh)["contribution"]
    pins = {"rfc_sha256": c.get("rfc_sha256", ""),
            "task_sha256": c.get("task_sha256", "")}

entry = {
    "contribution_id": cid, "task": task, "rfc": rfc, "objective": objective,
    "objective_weight": int(weight), "weight_source": wsrc,
    "agent": agent, "model": model, "prompt_hash": phash,
    "reviewer_verdicts": verdicts(
        "reviewer-*.json", ["role", "verdict", "confidence", "findings", "reasoning"]),
    "guardian_verdicts": verdicts(
        "guardian-*.json", ["verdict", "confidence", "serves_common_good",
                            "within_non_goals", "findings", "reasoning"]),
    "evidence_digest": "sha256:" + digest,
    "constitution_version": int(cver),
    **pins,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(entry, fh)
