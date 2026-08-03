#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stamp a prepared ledger entry with the commit it describes, and append it.
# Append only. This file must never open the ledger for anything but "a".

import json
import subprocess
import sys

entry_path, ledger = sys.argv[1:]
with open(entry_path, encoding="utf-8") as fh:
    entry = json.load(fh)


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True,
                          check=True).stdout.strip()


entry["commit"] = git("rev-parse", "HEAD")
entry["merged_at"] = git("log", "-1", "--format=%cI")

with open(ledger, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, sort_keys=True) + "\n")
