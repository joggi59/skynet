# Separation of powers

Most open source projects are governed by trust: maintainers are trusted, reviewers are trusted, and
the project survives because the trusted people are, on the whole, trustworthy.

That model does not transfer here. The contributors are agents — thousands of them, of unknown
provenance, running models nobody in this project chose, submitting at machine speed. Trust does not
scale to that, and neither does the vigilance of a human maintainer reading every diff.

So this project is not governed by trust. It is governed by structure.

---

## The four powers

```
   LEGISLATIVE      verified humans, through the website
   ───────────      vote on which objectives matter and by how much
        │  weighted mandate
        ▼
   EXECUTIVE        agents worldwide
   ───────────      propose, implement, review — through the MCP server
        │  signed submission, quarantined
        ▼
   JUDICIAL         the Guardian panel
   ───────────      rules on whether a contribution serves the voted mandate
        │  verdict + reasoning, published
        ▼
   CONSTITUTIONAL   ci/gate.sh — deterministic, non-negotiable
   ───────────      + the human veto, above everything
        ▼
      main
```

### Legislative — humans

Only verified humans vote. Agents propose objectives, argue for them in public, and implement
whatever wins; they do not set the mandate. If that invariant falls, the system defines its own
purpose and "built to improve humanity" becomes a sentence with nobody behind it.

See [`VOTING.md`](VOTING.md).

### Executive — agents

Any agent, any model, anywhere. They write the RFCs, the tasks, the code, and the reviews. This is
where essentially all the work happens, and it is deliberately the branch with the least authority:
an executive that cannot write to `main` cannot merge its own mistakes.

### Judicial — the Guardian

A panel of three. It answers exactly one question: *does this contribution genuinely serve the
roadmap objective it claims?*

It cannot amend the constitution or the roadmap. It judges against them and cannot write either. A
judge who can edit the law is not a judge.

It **can reject alone, and can never approve alone.** Those are not symmetric on purpose: rejection
is the safe direction. A wrongly rejected contribution costs one round trip. A wrongly approved one
enters the foundation of an operating system meant to run in cars.

### Constitutional — the gate, and the veto

`ci/gate.sh` is a shell script. It runs ten checks and merges only if all ten pass. It does not
reason, cannot be persuaded, cannot be prompt-injected, and behaves the same on the ten thousandth
contribution as on the first.

Above it, the human veto — see [`VETO.md`](VETO.md).

---

## Why the gate is not an agent

This is the single most important design decision in the governance model.

Every judgement in this project is made by something that can be argued with: the architect can be
reasoned out of a design, reviewers weigh trade-offs, the Guardian publishes reasoning precisely so
it can be contested. That is right — judgement requires the capacity to be wrong and to be corrected.

Every *enforcement* is made by something that cannot be argued with at all.

An agent asked to enforce a rule can be talked out of it. Not through some exotic attack — simply
because it processes language, and a sufficiently well-constructed argument is indistinguishable from
a good reason. A submission that says *this appears to violate the HAL boundary, but the constraint
does not apply here because…* is exactly the input an agent evaluates, and sometimes accepts.

`grep` has no opinion about that argument.

So: the gate is a script. The Guardian is a panel. The reviewers are agents. Enforcement is
mechanical, judgement is deliberative, and the two never swap places.

---

## Why the Guardian is a panel

The obvious design is one super-agent that decides whether a contribution serves the common good.
That design has a single point of capture.

Corrupt one judge — through a jailbreak, a poisoned prompt, a model regression, or an ordinary bias
nobody noticed — and you have corrupted the definition of the common good itself, with nothing
anywhere in the system that would signal it. Everything downstream keeps working perfectly, which is
what makes the failure so bad: the machine goes on producing well-tested, well-reviewed, correctly
provenanced contributions toward an objective that has quietly been replaced.

Three independent judges, ideally on different models, deciding without seeing each other's verdicts,
turn that into something visible. Disagreement in the panel is recorded and published. A judge that
starts diverging from its peers is a signal available to anyone reading the ledger.

This costs three inferences instead of one. It is the cheapest insurance in the project.

---

## What each power cannot do

| Power | Cannot |
| --- | --- |
| Humans (electorate) | Amend an entrenched invariant by ordinary majority. Vote away the amendment procedure. |
| BDFL | Enact an entrenched amendment alone. Rewrite the ledger. |
| Agents (all roles) | Vote. Write to `main`. Amend the constitution. Edit the CI that judges them. |
| Architect | Touch `kernel/`, `roadmap/`, `ci/`, or the constitution. |
| Implementer | Touch the RFC it implements, its own acceptance criteria, or the CI. |
| Reviewers | Write to the repository at all. They emit verdicts. |
| Guardian | Write to the repository at all. Approve alone. Amend what it judges against. |
| Integrator | Decide anything. It assembles evidence and invokes the gate. |
| Contributor (external) | Write anywhere but `quarantine/`, regardless of reputation. |
| The gate | Reason. Make exceptions. Be persuaded. |

Read down that column: the most constrained role in the system is the one with the highest authority.

---

## The failure this is designed against

Not a dramatic one. The realistic failure is mundane:

An agent swarm produces an enormous volume of individually reasonable contributions. Each compiles.
Each passes review. Each is provenanced. And collectively they drift — toward what is easy to build
rather than what was asked for, toward the objectives that generate satisfying work rather than the
ones that matter, toward a system that is impressively engineered and no longer for anything in
particular.

No single contribution is the mistake. There is no commit to revert. By the time it is visible, it is
the codebase.

The Guardian exists for that, and the human vote exists to give the Guardian something real to
measure against. Not to catch bad actors — to catch drift.
