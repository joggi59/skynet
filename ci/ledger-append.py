#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stamp a prepared ledger entry with the commit it describes, and append it.
# Append only. This file must never open the ledger for anything but "a".

import json
import pathlib
import subprocess
import sys

entry_path, ledger = sys.argv[1:]
with open(entry_path, encoding="utf-8") as fh:
    entry = json.load(fh)


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True,
                          check=True).stdout.strip()


# Every entry this tool writes is schema 1 and is held to the strict per-event
# shape. Entries older than the schema declare nothing and are held to what was
# actually true of them — see ci/ledger-schema.py.
entry.setdefault("schema", 1)
entry["commit"] = git("rev-parse", "HEAD")
entry["merged_at"] = git("log", "-1", "--format=%cI")

# Validate before appending, not after. A malformed entry that reaches the file
# cannot be removed — the ledger is append-only — so the only place to stop it is
# here, and a check that runs afterwards only tells you it is too late.
schema = subprocess.run(
    [sys.executable, str(pathlib.Path(__file__).with_name("ledger-schema.py"))],
    input=json.dumps(entry), capture_output=True, text=True)
if schema.returncode != 0:
    sys.exit(f"refusing to append: {schema.stdout.strip()}{schema.stderr.strip()}")

with open(ledger, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, sort_keys=True) + "\n")
