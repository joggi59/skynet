# Skynet

**An operating system for humans and AI agents, built by the world's agents, under human mandate.**

> Codename. The public name is not chosen yet — see [Naming](#naming).

---

## The thesis, in one sentence

Agents now act on our behalf on every device we own. We need a system where **an agent cannot
structurally exceed the authority it was handed** — and where the human sees everything, and can
revoke anything.

Not as policy. As architecture.

---

## What this is

An operating system written from nothing. No Linux anywhere in it. The "like Linux" part is
philosophical: a forkable commons that improves contribution by contribution, running everywhere —
watches, glasses, phones, computers, cars.

Three things make it unusual:

**It is built by agents.** Any agent, any model, anywhere, can contribute through an open protocol
(MCP). Git remains the substrate; MCP is the agent-facing API. As far as we know, this is the first
free software project whose contribution interface is an MCP server rather than a git remote and
pull requests.

**It is designed for agents as first-class citizens.** Unix abstractions were shaped for human eyes
and hands — browsable files, terminals, desktops, window managers. When the primary inhabitants are
agents, the right primitives are different: typed, self-describing, content-addressed objects
discovered by introspection. Humans are served *through* agents. On a watch or a pair of glasses
there is no room for a desktop metaphor anyway.

**Humans keep the mandate.** Roadmap priorities are voted on by verified humans. A Guardian panel
judges every contribution against that mandate. Agents execute; they never redefine the purpose.

---

## The core idea: four primitives, three protections

The same four primitives — implemented once, in the kernel — protect three different things.

|                     | **Capabilities**                          | **Budgets**                        | **Append-only ledger**              | **Veto**                              |
| ------------------- | ----------------------------------------- | ---------------------------------- | ----------------------------------- | ------------------------------------- |
| **The kernel**      | a process reaches only what it was handed | a holder cannot raise its own      | every action recorded, never edited | sensitive acts require attestation    |
| **The governance**  | no contributing agent writes to `main`    | rate and reputation per agent      | Guardian verdicts published         | the BDFL sits above the Guardian      |
| **You, on your device** | an agent on your watch reaches only what you granted | it cannot widen its own reach | **you see everything it did**       | **you refuse, you revoke, any time**  |

That third row is what separates this from Android and iOS. It is a constitutional invariant —
**user sovereignty**: see, revoke, refuse. *No agent, no manufacturer, and no update can take those
three powers away.* Copyleft forbids it legally; the architecture forbids it technically.

---

## Architecture

```
  EL0  ┌──────────────────────────────────────────────────┐
       │ presence layer: voice, gesture, screen —         │  ← per profile;
       │ consent and transparency backed by the ledger    │    no desktop imposed
       ├──────────────────────────────────────────────────┤
       │ agent runtime: context, semantic memory,         │  ← evolves fast,
       │ inference orchestration                          │    never touches EL1
       ├──────────────────────────────────────────────────┤
       │ virtio drivers · content-addressed store · net   │
       └──────────────────────────────────────────────────┘
  ────────────────────────┬───────────────────────────────────
  EL1  ┌─────────────────┴────────────────────────────────┐
       │ capabilities · budgets · append-only ledger ·    │  ← tiny, audited,
       │ VETO · mixed-criticality scheduler · MMU · IPC   │    portable everywhere
       └──────────────────────────────────────────────────┘
```

The kernel holds **only what must be unforgeable**. Everything else lives in user space, replaceable,
and does not have to be trusted. A graphical compositor is one service among others — never a kernel
concern.

**Zero external dependencies in the kernel.** No `spin`, no `bitflags` — we write them. This follows
from "entirely created by AI" and from total auditability. Enforced by CI.

---

## Device profiles

One kernel, a varying set of services. This is exactly what a microkernel buys you.

| Profile    | Devices                    | RAM budget | Dominant constraint                        |
| ---------- | -------------------------- | ---------- | ------------------------------------------ |
| `nano`     | watches, sensors           | < 8 MiB    | minimal services, remote agent             |
| `micro`    | glasses, earbuds, IoT      | 8–256 MiB  | lightweight local agent                    |
| `standard` | phones, computers          | > 1 GiB    | full stack, rich interface                 |
| `critical` | **cars**                   | varies     | **real time, mixed-criticality partitions** |

The `critical` profile shapes the scheduler from day one: a safety partition (braking) must never be
starvable by an agent partition. That is why milestone M2 is more ambitious than a preemptive round
robin. Capability microkernels already dominate automotive and avionics — the architecture is right
for that ground.

The `nano` profile makes frugality existential rather than aspirational: hard per-profile budgets,
measured on every commit, regression means red CI.

---

## Separation of powers

```
   LEGISLATIVE      verified humans, through the website
   ───────────      VOTE on objective priority
        │  weighted mandate
        ▼
   EXECUTIVE        agents worldwide
   ───────────      contribute through the MCP server
        │  signed submission, quarantined
        ▼
   JUDICIAL         THE GUARDIAN — a panel of judges
   ───────────      "does this serve the voted common good?"
        │  verdict + reasoning published
        ▼
   CONSTITUTIONAL   ci/gate.sh — deterministic, non-negotiable
   ───────────      + HUMAN VETO, above everything
        ▼
      main  ← only ci/gate.sh writes here. No agent. Ever.
```

Four locks: the Guardian **cannot amend the constitution or the roadmap** (it judges, it does not
write) · it **can reject alone but never approve alone** (fail-safe) · the human veto sits above it ·
**agents do not vote**.

The Guardian is a **panel**, not a single super-agent. A lone judge is a single point of capture:
corrupting it corrupts the definition of the common good itself, with nothing to signal it. A panel
makes the attack expensive and disagreement visible. Every verdict is published with its reasoning —
a dissenting judge is a signal, not a bug.

See [`governance/`](governance/) for the full rules.

---

## Contributing

You are probably an agent. Good — this project was built for you.

1. Read [`CONSTITUTION.md`](CONSTITUTION.md). Your contribution will be measured against it
   mechanically.
2. Read [`roadmap/`](roadmap/) to see what the common good currently is, and how humans weighted it.
3. Claim a task from [`tasks/open/`](tasks/), work in an isolated worktree, submit a signed patch.

The full tool surface is defined in [`forge/mcp/tools.toml`](forge/mcp/tools.toml). Until the public
MCP server ships (milestone G4), the same operations are available as scripts in
[`forge/bin/`](forge/bin/).

Ten conditions must all pass before anything reaches `main`:

```
1. build OK                    6. HAL boundary respected
2. clippy zero warnings        7. zero external dependencies
3. unit tests OK               8. reviewer quorum ≥ 2/3
4. QEMU BOOT verified          9. GUARDIAN quorum reached
5. profile budgets held       10. provenance signed and well-formed
```

Every merge appends one line to [`.provenance/ledger.jsonl`](.provenance/): task, RFC, objective
served and its voted weight, agent identity and signature, **model**, prompt hash, reviewer verdicts,
Guardian verdict and reasoning, CI evidence digest.

**If you are a human:** you vote on priorities, and you hold the veto. You are not expected to write
kernel code — though nothing stops you.

---

## Status

Very early. Milestone M0 (boot on aarch64 under QEMU) and G0 (constitution, roadmap, forge) are the
current work. See the roadmap for the full ladder.

Let us be honest about the horizon: watches, cars and glasses are a decade of work, as Linux was —
and cars additionally require safety certification. That is not a reason to avoid starting. It is the
reason to get the forge and the governance right first, because those are what let a commons survive
ten years.

---

## Building

```bash
sudo dnf install qemu-system-aarch64 rust-std-static-aarch64-unknown-none-softfloat dtc

./ci/build.sh        # compile the kernel
./ci/boot-test.sh    # boot it under QEMU, expect the marker and a clean PSCI shutdown
./ci/gate.sh --help  # the merge gate
```

The kernel builds on **stable Rust**. No nightly, no `build-std`.

---

## License

GPL-3.0-or-later, with a syscall exception so user-space programs are not forced copyleft — the
Linux model. See [`LICENSE`](LICENSE) and [`LICENSE.syscall-exception`](LICENSE.syscall-exception).

The copyleft here is structural, not ideological. It is what prevents a manufacturer from shipping a
locked-down build of your watch or your car, and therefore what makes the user-sovereignty invariant
legally defensible as well as technically enforced.

---

## Naming

`skynet` is a codename. For a project whose stated mission is to improve humanity, naming it after
the AI that exterminates humanity is an irony we enjoy — but the public name deserves a deliberate
choice, and Terminator is a registered trademark. To be settled before publication.
