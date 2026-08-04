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

`SessionStore` is in memory. So is `TokenStore`. A bridge restart therefore
loses **both**, and the second one bites first:

- **The token is gone.** Every previously paired phone now gets
  `401 invalid_token` on its next request and must re-pair. Verified end to
  end: pair, `GET /v1/models` → 200, kill the process, start it again, *the
  same token* → `401 {"error":{"code":"invalid_token"}}`. Note what does not
  change across that restart — the instance id is read from `~/.localis` and
  is identical before and after. The phone still recognises the Mac; it just
  can no longer talk to it.
- **The session mapping is gone.** Even after re-pairing, the next turn on an
  old session id starts a fresh CLI conversation.

The mapping loss is recoverable and honest — a forgotten conversation is
visibly a forgotten conversation, where a *wrong* id would make the CLI reject
the turn outright. The token loss is the sharper edge, and it is tracked
separately; it is not a property of session mapping and is not fixed here.

`401 invalid_token` is deliberate: the client switches on that code and clears
its stored token, which is the remedy. An off-vocabulary code (this handler
said `unauthorized` until 2026-08-04) is mapped by the client to "malformed
response" — the phone would report a broken bridge instead of "re-pair with
this Mac".

## What the contract does not say

Two questions a second implementer would have to guess at. Both are reported
to the spec owner rather than answered here — a bridge that invents an answer
is a bridge the client cannot predict.

1. **Does a session id survive a bridge restart?** The contract describes the
   header as mapping an iOS session to an agent session, but says nothing about
   whether that mapping is expected to be durable. This bridge's answer is "no",
   which is *an* answer, not *the* answer.
2. **What should happen when a session id is reused against a backend that
   never saw it?** Today it silently starts fresh. Rejecting it would also be
   defensible, and the client currently cannot tell the two apart.
