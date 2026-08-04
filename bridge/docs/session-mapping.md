# Session mapping — `x-localis-session-id` → the CLI's own session

How the bridge turns the contract's session id into a continued conversation on
a CLI that has never heard of Localis.

**This is implementation documentation, not contract.** The contract fixes one
thing only: `x-localis-session-id` maps an iOS conversation onto an agent
conversation on the bridge side. *How* is the bridge's business — today it is
`claude --resume`, and a different backend will do something else entirely.
Nothing here may be relied upon by the client.

Everything below was observed against a real `claude` CLI on 2026-08-04, not
derived from reading the code. Where a claim is untested it says so.

## The two ids

| | minted by | lifetime | where it appears |
|---|---|---|---|
| **contract session id** | the iOS client | forever, client-side | `x-localis-session-id` request header |
| **backend session id** | the CLI, on its first turn | until the bridge process exits | `--resume <id>`, and the CLI's own `session_id` field |

They are deliberately different things, and neither side learns the other's
scheme. The client never sees a CLI session id; the CLI never sees a UUID from
the phone.

## The path a turn takes

1. `BridgeHandler` reads `x-localis-session-id` off the request.
2. `TurnCoordinator` asks `SessionStore` for the backend session filed under
   `(contract session, backend id)`.
3. `ClaudeInvocation` appends `--resume <backend session>` — **only** if one was
   found and it is non-empty. An empty `--resume` makes the CLI reject the
   invocation outright, so a first turn omits the flag rather than passing "".
4. The CLI's first output frame carries its own `session_id`.
   `ClaudeStreamDecoder` surfaces it as `.session(id)`, and the coordinator
   files it against the contract session for next time.

The key is `(session, backend)`, not the session alone. The same conversation
against two backends is two conversations — keying on the session alone would
hand codex a session id that only claude ever minted, and the CLI would reject
a turn for a session it never created.

## What was actually observed

Two turns over one paired device, same `x-localis-session-id`:

```
turn 1  "Remember the word APPLE. Reply with just: ok"   → ok
turn 2  "What word did I ask you to remember?"           → APPLE
```

Negative controls, both run against the same live bridge, because "it
remembered" only means something if *not* remembering is also reachable:

```
different session id, same question → "You haven't asked me to remember a word
                                        — this is the first message…"
no session header at all, same question → "I don't have a record of that word.
                                        This conversation starts here for me…"
```

So the mapping is doing the work: continuity follows the header, not the
process, and not the wall clock.

## The restart boundary — the part to know before relying on any of this

`SessionStore` is in memory. `TokenStore` is no longer: grants are written to
`~/.localis/grants.json` (2026-08-04), because pairing is a one-time act
(spec.md:46) that ends only when the user unpairs (FR-027) or the certificate
changes (constitution §V), and a process exiting is none of those.

So a restart today loses one of the two:

- **The token survives.** Pair, restart, same token → 200. A corrupt grant file
  is a startup error naming the remedy, never a silent reset — replacing it
  would unpair every device on the Mac with no event the user could point at.
- **The session mapping is still gone.** The next turn on an old session id
  starts a fresh CLI conversation. Recoverable and honest — a forgotten
  conversation is visibly forgotten, where a *wrong* id would make the CLI
  reject the turn outright.

Note what does not change across a restart either way: the instance id is read
from `~/.localis` and is identical before and after, so the phone recognises
the Mac. Before grants were persisted, that combination was the bad one — the
phone knew the Mac and was refused by it on every request.

Making the session mapping durable is not simply the same fix again. The
backend session id belongs to `claude`, lives under `~/.claude/`, and expires
on a schedule this bridge does not control — so a persisted mapping can outlive
the conversation it names. An empty `--resume` is known to make the CLI reject
the invocation outright; what it does with an *unknown* id is not yet tested,
and that answer decides whether durability alone is enough or it needs a
fall-back-and-retry.

`401 invalid_token` is deliberate: the client switches on that code and clears
its stored token, which is the remedy. An off-vocabulary code (this handler
said `unauthorized` until 2026-08-04) is mapped by the client to "malformed
response" — the phone would report a broken bridge instead of "re-pair with
this Mac".

## What the contract does not say — and what has been decided since

Two questions a second implementer would have to guess at. Neither is answered
by the contract text as of `origin/main` = `d35b7f6`; both have been **ruled on
by the spec owner** (2026-08-04) and are queued to be written into it. Recorded
here so this file does not read as an open invitation to decide them again —
but the contract, once amended, is the authority, not this paragraph.

1. **Does a session id survive a bridge restart?** Ruled: it should, and it
   will once the mapping is persisted — but *not silently either way*. Today it
   does not, and the user sees the AI "forget" with no indication why. If the
   mapping ends up persisted while grants are not (or vice versa), the client
   must be able to tell the two situations apart.
2. **A session id reused against a backend that never saw it?** Ruled: keep
   today's behaviour — start fresh, do not reject. Rejecting would break
   switching backends mid-conversation, which Amendment B explicitly allows
   ("a switch applies from the next message"). The contract is to state that a
   new backend starts from empty context, so the client knows whether to say so.
