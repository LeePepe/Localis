# `pairingState` and the pin: is the write side already holding this?

Task #53, verification only. No source file is modified by this report.
Read against `de383a6` (`origin/main`).

**Conclusion: close the task.** Both halves it asks for are already held, one
of them by a mechanism the task did not anticipate — the store cannot record a
pin at all, so the "two stores, one write" atomicity problem this task was
opened on does not exist in the shape it was described. The one genuine gap
found is a missing *test*, not missing behaviour, and it is small enough to
name here rather than to keep a task open for.

## 1. Does `HostRevocation.apply` give "both change or neither"?

`HostRevocation.swift:95-103`:

```swift
if outcome.clearsCredentials {
    try credentials.removeCredentials(for: host)   // Keychain first
}
try await repository.save(outcome.applied(stored))  // store second
```

It is not a transaction, and the doc comment argues only the first failure
direction. Both directions, worked out:

**Keychain fails → store never written.** `try` propagates, `save` is not
reached, the record still reads `.paired`. Covered by
`HostRevocationTests.keychainFailureIsNotSwallowed` (`:256`).

**Keychain succeeds → store write fails.** The record still reads `.paired`
while the credential is gone. This is the half the comment does not discuss,
and it is **the same state this task was opened about** — `.paired` with no
pin. Its consequence: `HostAssembly.host(id:)` finds `.paired`, asks for the
pin, gets `nil`, and returns the host with `canConnect == false`
(`HostAssembly.swift:86-95`). Fail-closed. Since #51 landed, the card names it
via `.unprobable` rather than showing it as an ordinary unpaired machine.

So the interleaving is **not atomic and does not need to be**: its worst state
is one the read path already treats as untrustworthy.

**And there is a stronger reason, which changes this task's premise.** The
store has no pin column at all —
`StoredModels.swift:154-169`, asserted by
`StoredHostTests.storageHoldsNoSecondTrustAnchor`:

> The consequence is deliberate and has to be understood before using this
> type: a `LocalisHost` read back from this package always has
> `pinnedSPKI == nil`

`unpaired()` is `with(pinnedSPKI: .some(nil), pairingState: .revoked)`
(`LocalisHost.swift:97-99`), but `StoredMapping.swift:309` writes only
`pairingStateRaw`. **The pin-clearing half of `unpaired()` is a no-op against
the store.** There is exactly one durable copy of the pin — the Keychain — so
"both stores change or neither" was never the invariant. The two writes are of
*different facts* (state; credential), not two copies of one fact, and only
one of them can drift.

## 2. Does the original symptom go through this path?

**No.** The task's `.paired` + no pin came from reinstalling the app over a
surviving database, so `DemoSeed.populateIfEmpty` short-circuits on a non-empty
store (`DemoSeed.swift:53-56`) and never re-writes the Keychain — the pin was
lost with the app container. The real-world equivalent is a restored device
backup, which carries the store and not the Keychain;
`HostAssembly.swift:89-95` names exactly that case.

In both, **the writer is iOS, not us.** No `HostRevocation.apply` runs, so
"prevent it on the write side" has nothing to attach to. team-lead's judgement
here is confirmed.

The residue in the *other* direction — a stale pin under a host that is no
longer `.paired`, which is what a half-finished `apply` leaves — is guarded:
`HostAssemblyTests.unpairedHostIsNeverPinned` (`:127-151`) seeds a `.revoked`
host with a pin in the Keychain and asserts the join refuses to attach it
(`joined.pinnedSPKI == nil`, `canConnect == false`). `HostAssembly.swift:81`
calls this "residue from an unpairing that did not finish" in as many words.

**Both residue directions therefore have an owner:** stale-pin-under-revoked is
refused at the join; paired-without-pin is fail-closed at the join and named at
the card since #51.

## 3. The one real gap: a failure direction with no test

Nine tests cover `HostRevocation`, and the fake credential store can be told to
throw (`HostRevocationTests.swift:47-69`). **`InMemorySessionRepository` has no
equivalent** — no test injects a failing `save`, so the "Keychain succeeded,
store write failed" branch is reasoned about here and asserted nowhere.

It is worth one test, not a task: seed a `.paired` host, make `save` throw,
apply `.tokenRevoked`, and assert the error propagates and that a subsequent
join yields `canConnect == false`. That pins the fail-closed property the
argument above depends on, instead of leaving it as a comment. Recommend
folding it into whoever next touches `LocalisTests/HostRevocationTests.swift`.

## 4. The blocking reason, and what it cost

This task waited on a bridge unpair route. That route was ruled not to exist —
`bridge/Sources/LocalisBridgeCLI/Unpair.swift` argues an authenticated HTTP
endpoint would let any paired phone revoke *another* phone, turning a stolen
token from "read the model list" into "lock the owner out". The wait was for
something ruled out by design.

Worth separating: the *decision* was recorded in the right place, in the source
that implements it. What was missing is that a decision recorded on one side
does not reach a task description on the other. Nothing here is a defect in
`Unpair.swift`.

## Recommendation

**Close #53.** The invariant it names is held; the mechanism is not the one it
assumed (there is no second durable copy of the pin to keep in sync); and its
original symptom is produced by iOS's backup restore, where no write side of
ours participates. The single follow-up is the missing failure-injection test
in §3, which should ride along with the next change to that file rather than
keep a task open.

## What this report did not check

- No test was run. Every claim above is read from source at `de383a6`; the
  behavioural claims in §1 are arguments from the code, not measurements. The
  §3 test is missing precisely because that branch has never been executed.
- `bridge/` was read only for the quoted comment in §4 (`Unpair.swift`), per
  the task's scope limit.
