#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Validate one ledger entry against the schema for its own event type.
#
# Reads one JSON object on stdin. Exits 0 if well-formed, 1 with a reason if not.
#
# ---------------------------------------------------------------------------
# Why this is not one field list
#
# It was, and the ledger paid for it. Every entry — merge, correction, defect
# report — had to carry `task`, `objective`, `model`, `reviewer_verdicts` and
# `guardian_verdicts` or the check failed it. So every entry carried them, and
# the ones with nothing to put there invented it: line 8 records a correction
# that concerns no objective at all and states `objective: "0001"`.
#
# That is a false statement, in an append-only file, written to satisfy a check.
# The ledger's entire worth is that it is true; a check that makes it less true
# is worse than no check. Padding is not a formatting issue.
#
# ---------------------------------------------------------------------------
# Why it is versioned
#
# The ledger is append-only, and it existed before this schema did. Tightening
# the rules retroactively leaves exactly two options: rewrite history so it
# complies, or refuse the file forever. The first is forbidden — it is the one
# thing no role in this project may do — and the second is a check nobody can
# ever make pass, which becomes a check everybody learns to skip.
#
# So entries declare their schema. Lines written before it existed carry no
# `schema` field and are held to V0: the properties that were actually true of
# them, and that still matter. `ci/ledger-append.py` stamps `schema: 1` on
# everything from now on, and V1 is strict.
#
# The version is a floor, not a wall. Raising it constrains future entries only,
# which is the only direction an append-only log can be tightened in.
#
# ---------------------------------------------------------------------------
# Why an unknown event fails
#
# The obvious shape — look up the event, validate if known, pass otherwise —
# means inventing an event name skips validation entirely. That is the defect
# three reviewers have found in three different checks in this repository: an
# absence read as the thing being checked. A new event type is a schema change,
# and it belongs here before it belongs in the ledger.

import json
import sys

CURRENT = 1

# What was true of every entry written before the schema existed, and is worth
# keeping true: it says who wrote it, points at its evidence, is dated, and
# explains itself in prose a human can read.
V0_COMMON = ["agent", "evidence_digest", "merged_at"]
V0_PROSE = ["explanation", "what_happened"]

# V1. `commit` is common because every entry now names the commit it describes;
# `agent_role` because "who wrote this" was ambiguous exactly once, and the role
# that produced the ambiguity is the one with the least mechanical constraint.
V1_COMMON = ["agent", "agent_role", "evidence_digest", "merged_at", "commit"]

# Per event, on top of the common set. A merge is the heaviest because it is the
# only event that changes main, and every field is something a reader would need
# to reconstruct why.
V1_EVENT = {
    "merge": ["contribution_id", "task", "objective", "model",
              "reviewer_verdicts", "guardian_verdicts"],
    "genesis": ["contribution_id", "objective", "explanation"],
    # A verdict that arrived after the gate ruled. Names the contribution and the
    # verdicts, and nothing about a model or a task that it does not know.
    "late-verdict": ["contribution_id", "corrects", "guardian_verdicts",
                     "explanation"],
    # A statement in an earlier entry that was wrong. Must name the entry it
    # contradicts, or it is an assertion floating free of what it corrects.
    "correction": ["corrects", "what_happened"],
    # A failure of the process rather than of the code. No contribution need be
    # involved, and often the point is that none was.
    "governance-defect": ["defect", "what_happened", "remedy"],
}

EVENTS = set(V1_EVENT)


def fail(msg):
    print(msg)
    sys.exit(1)


try:
    entry = json.loads(sys.stdin.read())
except Exception as exc:  # noqa: BLE001 — the reason is the whole output
    fail(f"not valid JSON: {exc}")

if not isinstance(entry, dict):
    fail("not a JSON object")

# An entry with no `event` is a merge: that was the only kind when the ledger
# started, and adding the field to those lines is what append-only forbids.
event = entry.get("event", "merge")
if event not in EVENTS:
    fail(f"unknown event type {event!r} — a new event type is a schema change; "
         f"add it to ci/ledger-schema.py first (known: {', '.join(sorted(EVENTS))})")

version = entry.get("schema", 0)
if not isinstance(version, int) or version < 0:
    fail(f"schema must be a non-negative integer, got {version!r}")
if version > CURRENT:
    fail(f"entry declares schema {version}, but this checker knows up to "
         f"{CURRENT} — it cannot validate what it does not understand")

if version == 0:
    required = list(V0_COMMON)
    if event == "merge":
        # The shape the gate wrote from the first merge, and still writes.
        required += ["contribution_id", "task", "objective", "model",
                     "reviewer_verdicts", "guardian_verdicts"]
    missing = [f for f in required if f not in entry]
    if missing:
        fail(f"event {event!r} (schema 0) missing fields: " + ", ".join(missing))
    if event != "merge" and not any(f in entry for f in V0_PROSE):
        fail(f"event {event!r} (schema 0) explains itself nowhere: expected one of "
             + ", ".join(V0_PROSE))
    # A MERGE may not claim that nobody reviewed and nobody judged.
    #
    # Omitting `schema` opted an entry into this branch, which checked presence
    # and not content — so a merge declaring `reviewer_verdicts: []` and
    # `guardian_verdicts: []` validated with exit 0. That is the single worst
    # thing this file could accept, and review demonstrated it accepting it twice.
    #
    # Scoped to merges and to the two verdict lists, because a wider check does
    # break history and the first attempt at it did: the genesis line carries an
    # empty `merged_at` and empty verdict lists, and lines 4 through 8 carry the
    # empty verdict lists this schema was written to stop being demanded of them.
    # A merge is the only event for which those lists are a claim rather than
    # padding. That was measured against the file before this comment was written,
    # which is not how the previous version of this comment got made.
    if event == "merge":
        hollow = [f for f in ("reviewer_verdicts", "guardian_verdicts")
                  if not entry.get(f)]
        if hollow:
            fail("a merge entry claims nobody reviewed or nobody judged: "
                 + ", ".join(hollow) + " is empty")
    sys.exit(0)

missing = [f for f in V1_COMMON + V1_EVENT[event] if f not in entry]
if missing:
    fail(f"event {event!r} (schema {version}) missing fields: " + ", ".join(missing))

# A field carried but empty is the padding this schema exists to stop, one step
# subtler: it satisfies a presence check and says nothing.
empty = [f for f in V1_EVENT[event] if entry[f] in ("", [], {}, None)]
if empty:
    fail(f"event {event!r} has empty required fields: " + ", ".join(empty)
         + " — an empty field is padding, not a record")
