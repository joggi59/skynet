# The veto

The veto is one primitive with two applications. That is not a coincidence in the design — it is the
design.

In governance, it is the power of a human to refuse a contribution regardless of how many agents
approved it. On a device, it is the power of an operator to refuse an action regardless of what
capabilities an agent holds. The same kernel object backs both: an authority that agents cannot
forge, cannot bypass, and cannot revoke.

If you understand why the second one matters, you already understand why the first one exists.

---

## Part 1 — The governance veto

Held by the BDFL. Applies to any merge, at any time, with or without stated reason.

### What it can do

Refuse a contribution the Guardian approved and the gate passed. Halt a merge in progress. Revert a
merge already made — reverting is a forward commit and leaves the ledger intact.

### What it cannot do

**Rewrite the provenance ledger.** Not by veto, not by any other means. A benevolent dictator who can
erase the record is just a dictator, and the record is the only thing that makes benevolence
checkable.

**Enact an entrenched amendment alone.** Those need supermajority *and* BDFL assent — see
[`VOTING.md`](VOTING.md). The veto is a power to stop, not a power to enact. It is deliberately
negative-only: every constitutional power in this project that could be used to seize control is
constructed so that it can only prevent things.

**Approve something the gate rejected.** The veto blocks; it does not override. There is no path in
this system by which a failing build reaches `main` because someone with authority wanted it to.

### Why a single human, and why that is temporary

Concentrating this in one person is a real weakness and worth naming rather than dressing up. It is
correct now for one reason: a project of five days needs someone who can say no quickly, and
diffusing that power before there is a community to diffuse it into produces paralysis, not
legitimacy.

The BDFL role is expected to become a council as the electorate becomes real. That transition is
itself an entrenched amendment: it needs supermajority and the current holder's assent, which is the
one use of the veto whose absence would be most telling.

---

## Part 2 — The operator's veto

This is the one that matters to someone who never reads this repository.

Constitutional invariant 2 — **user sovereignty** — grants every person operating a device three
powers that no agent, manufacturer, vendor or update may remove, weaken, bypass or make conditional:

**See.** Read the complete, unedited record of what agents did on the device. Not a summary, not a
curated activity feed — the ledger, append-only, exactly as the kernel wrote it.

**Revoke.** Withdraw any capability previously granted to any agent. Immediately. The holder cannot
refuse, cannot defer, and cannot be notified in time to act first.

**Refuse.** Decline any action requiring attestation. Silence is refusal: an unanswered attestation
request fails closed. A system that proceeds when you did not answer has not asked you anything.

### What requires attestation

The kernel refuses these unless the operator attests, whatever capabilities the requesting agent
holds:

| Action | Why |
| --- | --- |
| Outbound network from a context not already granted it | The difference between a device that works for you and one that reports on you |
| Reading a sensor — camera, microphone, location | On glasses and watches, the entire question |
| Writing outside an agent's own sandbox | Containment is only containment if leaving it is visible |
| Raising any budget | Otherwise budgets are advisory, which is to say they are nothing |
| Delegating a capability beyond the granted depth | Attenuation must not be routed around by re-delegation |
| Reading another agent's stored data | Isolation between agents is isolation for the operator |

The list is deliberately short. An attestation prompt that appears constantly gets clicked through
without reading, at which point it has become a liability wearing the costume of a safeguard. These
six are the actions where a person's answer genuinely changes what happens to them.

### What this rules out, by construction

A watch that streams biometrics to its manufacturer with no way to stop it. Glasses whose camera an
agent can reach without the wearer knowing. A car that reports driving behaviour to an insurer
because a firmware update added it. A phone where "delete my data" deletes a row in a table
somewhere and nothing else.

None of these are prevented by policy or promise here. They are prevented because the kernel refuses
the action, and because a build in which the kernel does not refuse is not a build of this system —
it is a modified kernel, unprotected by the syscall exception, distributed in violation of the
licence. See [`LICENSE.syscall-exception`](../LICENSE.syscall-exception).

### The awkward case: the operator is not always the owner

A leased car. A work phone. A device given to someone who cannot meaningfully consent — a child, a
patient, a person in care.

This is unsolved, and pretending otherwise would be worse than saying so. The current position is
narrow and defensible: the veto belongs to whoever physically holds the device, because that is the
person the sensors are pointed at. A fleet operator may restrict what is installed; it may not obtain
sight of what the operator does, nor take the operator's veto away.

Whether that survives contact with real fleet management, real medical devices, and real family
dynamics is an open question. It is recorded here as open rather than settled, and it belongs on the
roadmap before profile `critical` ships anywhere real.

---

## Invoking the veto

Governance:

```bash
ci/gate.sh --veto <contribution-id> [--reason "..."]
```

Recorded in the ledger with its reason, or with the explicit absence of one. A veto is a public act.
The power to refuse without explanation is preserved; the power to refuse without anyone knowing is
not.

On a device: whatever the presence layer offers for that profile — a spoken refusal, a physical
button, a screen. The kernel interface beneath is identical across all of them, and the answer
travels no further than the device.
