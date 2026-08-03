# The Constitution

This document defines what this system is for, and what may never be done to it.

It is not a manifesto. Every invariant below is paired with a mechanical check in
[`constitution.toml`](constitution.toml), run by [`ci/constitution-check.sh`](ci/constitution-check.sh)
on every contribution. An invariant that cannot fail a merge is decoration, and decoration has no
place here.

Where an invariant is not yet mechanically enforceable — because the code it constrains does not
exist yet — it is marked `pending` with the milestone at which enforcement begins. **`pending` is
reported as `pending`, never as `pass`.** Pretending to enforce something is worse than admitting it
is not enforced yet.

---

## Preamble

Agents now act on behalf of humans, on devices humans carry on their wrist, wear on their face, and
sit inside at 130 km/h. The question is no longer whether software can be trusted to do what it was
asked. It is whether anyone can still tell what it did, and stop it.

This system exists to make that question answerable. Not by promising good behaviour, but by
building a machine in which bad behaviour is structurally out of reach: an agent cannot exceed the
authority it was handed, cannot widen its own budget, cannot erase its own trace, and cannot
overrule the human who granted it anything.

Everything else in this project — the kernel, the forge, the vote, the Guardian — exists to serve
that sentence.

---

## The invariants

### 1. No ambient authority

*Entrenched. Enforcement begins at M4.*

Nothing is reachable by default. Every access to every resource passes through a capability that was
explicitly handed over. There is no global namespace a process can walk, no root from which authority
descends by position, no "the caller happens to be privileged" path.

A capability is unforgeable, attenuable, revocable, and may carry an expiry. A holder can pass a
weaker version of what it holds; it can never construct a stronger one.

**How it is checked:** a test suite that grants a process a known capability set and proves it cannot
reach anything outside that set.

---

### 2. User sovereignty

*Entrenched. Enforcement begins at M5.*

On every device running this system, the person operating it can, at any moment:

- **See** — read the complete, unedited record of what agents did on that device;
- **Revoke** — withdraw any capability previously granted to any agent;
- **Refuse** — decline any action that requires attestation.

**No agent, no manufacturer, no vendor, and no update may remove, weaken, bypass or make
conditional any of these three powers.** A build in which the operator has lost them is not a build
of this system, is not covered by the syscall exception, and is a licence violation.

This invariant is the reason the project is copyleft. See
[`LICENSE.syscall-exception`](LICENSE.syscall-exception).

**How it is checked:** tests proving the ledger is readable and unforgeable from the operator's
side, that revocation takes effect immediately and cannot be refused by the holder, and that no code
path grants an attested action without attestation.

---

### 3. Total provenance

*Entrenched. Enforced from G0 — now.*

Every line of this system is traceable to what produced it: the task, the RFC, the roadmap objective
served, the contributing agent's identity and signature, the model, the prompt hash, every reviewer
verdict, the Guardian's verdict and reasoning, and the digest of the CI evidence.

A commit without a well-formed provenance record does not merge.

The ledger at [`.provenance/ledger.jsonl`](.provenance/) is append-only. Rewriting history is not a
recoverable mistake here; it is the destruction of the property that makes this project meaningful.

**How it is checked:** `ci/gate.sh` refuses any merge whose provenance record is missing, malformed,
or unsigned, and refuses any push that rewrites existing ledger lines.

---

### 4. Frugality, per profile

*Amendable by ordinary vote. Enforced from M0.*

Every device profile in [`profiles/`](profiles/) carries hard budgets: image size, boot-time memory,
boot duration. They are measured on every contribution. A regression is a failure, not a discussion.

This is not asceticism. A system that cannot fit on a watch cannot run on a watch, and a system that
demands new hardware every three years is an e-waste engine wearing a software costume. Frugality is
what makes the reach in profile `nano` real and the promise of longevity honest.

Budgets are expected to be revised as the system grows and as hardware changes. That revision is an
ordinary vote — deliberate, recorded, and never silent.

**How it is checked:** `ci/gate.sh` measures the built artefact against the active profile and fails
on any regression.

---

### 5. Zero telemetry

*Entrenched. Enforcement begins at M6.*

The system emits nothing outward that the operator did not explicitly grant through a capability.
There is no analytics channel, no crash reporter, no "anonymous usage statistics", no beacon, no
covert timing channel standing in for one, and no exception for the project's own developers.

If we want to know how the system behaves in the world, we ask, and the operator decides.

**How it is checked:** the base image is verified to contain no outbound network path that is not
reachable exclusively through an explicitly granted capability.

---

### 6. HAL boundary

*Amendable by ordinary vote. Enforced from M0.*

No architecture-specific code exists outside `kernel/src/arch/`. Not one register name, not one
inline assembly block, not one address constant.

The point is not tidiness. This system is meant to run on a watch, a pair of glasses, a phone, a
computer and a car. Portability is not something added when the second port is attempted; it is a
discipline that either holds from the first commit or has already quietly failed by the time anyone
looks.

**How it is checked:** `ci/constitution-check.sh` scans for architecture-specific constructs outside
the HAL directory.

---

### 7. No kernel dependencies

*Amendable by ordinary vote. Enforced from M0.*

The kernel's dependency tree is empty. No `spin`, no `bitflags`, no `log` — we write them.

Two reasons. This project claims to be created by AI; pulling in ten thousand lines of human-written
crates would make that claim false at the foundation. And the kernel is the part that must be
auditable in full by anyone who cares to — which is only possible if "in full" is a finite amount of
code that we control.

User space is free to depend on whatever it likes. This constraint binds `kernel/` alone.

**How it is checked:** `ci/constitution-check.sh` asserts the kernel manifest declares no
dependencies and that the resolved tree is empty.

---

### 8. Roadmap alignment

*Amendable by ordinary vote. Enforced from G0 — now.*

Every contribution names the roadmap objective it serves, and the Guardian has ruled on whether it
genuinely serves it.

This is what keeps a swarm of agents from producing an enormous volume of individually reasonable,
collectively purposeless work. Effort without direction is not contribution.

**How it is checked:** `ci/gate.sh` requires a resolvable objective reference and a Guardian quorum.

---

### 9. Agents do not vote

*Entrenched. Enforced from G3.*

The electorate is human and verified. Agents propose, implement, review, and judge against a mandate.
They do not set the mandate.

If this invariant falls, every other guarantee in this document becomes theatre: a system that
defines its own purpose is not accountable to anyone, and "built to improve humanity" becomes a
sentence with no one behind it.

Ballots are public and stored in the repository, in the open, attributed. Transparency is the
primary defence against a captured electorate — not cryptography. Anyone can audit who voted.

**How it is checked:** ballot records are verified against the human electorate register; any ballot
attributable to an agent identity invalidates the cycle.

---

### 10. English repository

*Amendable by ordinary vote. Enforced from G0 — now.*

Everything in the repository is written in English: code, comments, documents, roadmap, RFCs, tasks,
prompts, commit messages, the website, and the MCP tool surface. This is what lets contributors and
agents anywhere in the world take part.

**How it is checked:** a heuristic lint flags likely non-English additions, and reviewers judge.
Stated plainly: no script detects language reliably. Here the machine raises a hand and an agent
decides. This invariant is advisory in CI and binding in review.

---

## Amendment

Two tiers. This is the difference between a constitution and a poll.

| What | How it changes |
| --- | --- |
| Roadmap priorities | Ordinary credit vote, each cycle |
| Invariants **4, 6, 7, 8, 10** | Ordinary vote, recorded, one cycle |
| Invariants **1, 2, 3, 5, 9** — entrenched | **Supermajority *and* BDFL assent**, and never in the cycle in which the amendment was proposed |
| **This amendment procedure itself** | Entrenched, by the same rule |

That last row is not a formality. Without it, a captured majority amends the amendment procedure in
one cycle and everything else in the next. The lock has to lock itself.

**Nothing in this document may be amended by an agent.** Amendments are proposed by humans, voted on
by humans, and assented to by the BDFL. Agents may argue for an amendment — in public, on the record,
where their reasoning can be weighed. They may not enact one.

---

## What this document does not do

It does not promise the system will be good. It makes specific behaviours structurally unavailable,
which is a smaller claim and a far more testable one.

It does not assume the agents building this system are benevolent. It assumes nothing about them.
Every guarantee here holds whether the contributing agent is careful, careless, or adversarial —
because it is enforced by a deterministic gate that does not reason, and by a kernel that does not
negotiate.

And it does not assume the humans are benevolent either. That is what entrenchment is for.
