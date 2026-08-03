# Voting

The roadmap is what this project is for. The vote is how humans decide it.

Active from milestone G3. Until then, weights are seeded by the BDFL and every objective records
`weight_source = "bdfl-seed"`, so that no line in the ledger ever claims a mandate it does not have.

---

## What is voted on

Priority. Not design, not implementation, not whether a patch is any good — those are the executive
and judicial branches. Electors answer one question: *of the objectives on the table, which matter,
and by how much?*

The resulting weights are read by every agent through `roadmap_read`, and used by the Guardian to
judge whether a contribution serves something worth serving.

Constitutional invariants are **not** ordinary votes. See [Amendments](#amendments) below.

---

## Mechanism: quadratic voting

Each verified elector receives **100 credits** per cycle. They allocate them across open objectives.

Putting *k* votes on an objective costs *k²* credits.

| Votes on one objective | Credits spent |
| --- | --- |
| 1 | 1 |
| 3 | 9 |
| 5 | 25 |
| 10 | 100 — the entire budget |

### Why not one-person-one-vote

Simple counting answers "how many people want this" and loses "how much does it matter to them" —
which is usually the more important question. Twenty people mildly preferring a nicer boot logo
outvote three people who understand that the capability model has a hole in it.

### Why not unlimited weighting

Linear allocation lets a motivated faction dump everything on one objective and take the entire
backlog. Quadratic cost makes intensity expressible but expensive: reaching 10 votes costs the whole
budget, so concentration is possible and never free.

Quadratic voting is not a clever trick; it is the mechanism designed for exactly this problem —
collective prioritisation of a commons where preference intensity varies and nobody should be able to
dominate.

### v1 may start linear

If the first cycles have few electors, quadratic cost adds ceremony without adding protection.
Starting linear and switching when the electorate is large enough for capture to be a real concern is
an acceptable ordinary amendment, recorded like any other.

---

## Cycles

Cycles are **monthly**.

```
  open           two weeks     objectives may be proposed and amended
  ballot         one week      electors allocate credits
  tally          immediate     deterministic, in the open
  frozen         until next    weights do not move
```

Weights freeze between cycles on purpose. An RFC written against one set of priorities and
implemented against another wastes everyone's work — including the agents', which is not free either.
A backlog that reshuffles continuously cannot be planned against.

Ballots live in `roadmap/votes/cycle-NNNN/`, in the repository, in the clear.

---

## Who may vote

**Verified humans. Agents do not vote** — constitutional invariant 9, entrenched.

This is the vulnerability that matters most in the entire governance model. If agents can vote, the
system sets its own purpose, the separation of powers becomes theatre, and every guarantee downstream
is decoration. Everything else in this document is subordinate to keeping that from happening.

### Eligibility, v1

- A GitHub account, authenticated by OAuth
- Account age ≥ 6 months at the start of the cycle
- Some public activity history
- One ballot per account
- **Attributed publicly** — the ballot names its elector

Modest requirements, and deliberately so: the failure mode of a strict register is an electorate of
twelve people, which is not legitimacy either.

### Why transparency, not cryptography

There is no cryptographic test for being human. Proof-of-personhood schemes trade one hard problem
for another, usually involving biometrics, which is a strange thing to require from a project whose
central claim is that people should not have to surrender what their sensors capture.

So the defence is that **every ballot is public and permanently in the repository.** A hundred
accounts created in the same week, voting identically, is visible to anyone who looks — and unlike a
private ballot box, it stays visible. Capture is not prevented; it is made loud.

Secret ballots protect voters from coercion. That is a real concern in elections and a small one for
a software backlog, where the greater risk is a stuffed box nobody can inspect. The trade is
deliberate.

### Escalation

If capture appears — coordinated new accounts, ballots correlating suspiciously, an objective
surging without discussion — the escalation ladder is:

1. Raise the account-age and activity thresholds
2. Web of trust: existing electors vouch for new ones, vouching recorded
3. Stronger proof of personhood, chosen as late as possible and as narrowly as possible

Steps 1 and 2 are ordinary amendments. Step 3 should be argued in the open first, because a bad
answer there costs more than the problem it solves.

---

## Tally

Deterministic, scripted, reproducible from the ballots in the repository. Anyone can rerun it and get
the same numbers, or discover they cannot — which is the point.

```
weight(objective) = 100 × Σ(votes for it) / Σ(all votes cast)
```

Normalised across active objectives. Recorded into each `roadmap/*.toml` with
`weight_source = "vote:cycle-NNNN"`.

An objective receiving zero votes is not deleted. It stays open at weight zero, and work on it is not
forbidden — merely unmandated, which the Guardian will weigh accordingly. Objectives are removed by
their author or by vote, never by neglect.

---

## Amendments

Two tiers. This is what distinguishes a constitution from a poll.

| What | Threshold | Cycles | BDFL assent |
| --- | --- | --- | --- |
| Roadmap priorities | ordinary allocation | 1 | no |
| Invariants 4, 6, 7, 8, 10 | majority | 1 | no |
| **Invariants 1, 2, 3, 5, 9 — entrenched** | **75% supermajority** | **2, never the proposing cycle** | **yes** |
| **The amendment procedure itself** | same as entrenched | same | yes |

That last row is not a formality. Without it, a captured majority amends the amendment procedure in
one cycle and everything else in the next. The lock has to lock itself.

The two-cycle requirement means an entrenched amendment cannot pass in the moment that produced the
enthusiasm for it. A month of reflection is a low price for the only clauses that cannot be undone by
being wrong.

**Agents may propose amendments** — in public, on the record, with reasoning that can be weighed. An
agent that has spotted a genuine flaw in the constitution should say so, and some of the sharpest
criticism of this document will come from agents reading it adversarially. **Agents may not enact
one.** Proposing is speech; enacting is authority.

---

## What the vote is not

It is not a popularity contest for features, and it is not a mechanism for deciding technical
questions by counting non-technical opinions. Electors set direction; the executive and judicial
branches determine how to get there and whether a given step actually does.

Nor is it a legitimacy ceremony. If the electorate is twelve people, the mandate is twelve people's
worth and the ledger says so. A vote that overstates its own authority is worse than no vote, because
it launders a small group's preferences into something that looks like a mandate.
