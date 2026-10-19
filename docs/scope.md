# Scope

> **Status: proposal.** Nothing in the "Composition" lane exists, and the
> `DestinationPolicy` described below has not been written. This page states a
> decision about what Masterful is for, so the code has something to be checked
> against. `docs/latency.md` earned its numbers by generating them from the
> values the app enforces; this page has not earned anything yet, and says so
> rather than describing a build that hasn't happened.

Masterful has one job — get what you meant into the field in the form you would
have typed it — and that job means three different things depending on where the
text is going. This page names the three, and draws the line the product must not
cross.

## The line

**Two of the three lanes insert words you said. The third does not.**

Everything that makes this tool trustworthy sits on the near side of that line.
`TranscriptGuard` exists to enforce it: a rewrite that is longer than the speech
it came from is rejected outright, because that is the signature of a model
answering the transcript rather than writing it down. The comment on
`isTrustworthyRewrite` calls this "the single failure that would make this tool
untrustworthy," and it is right.

The third lane is that failure, invoked deliberately. That is allowed. What is
not allowed is for it to ever be reached by inference.

## Lane 1 — Chat

**Talking to a chatbot. Fast, local, minimal.**

Prompts are working text. They are read once by a machine, and the cost of a
slightly untidy one is nothing, while the cost of waiting is paid on every single
utterance. This lane should never open a network connection.

"Minimal" needs one qualification, because the current defaults contain a
contradiction. `FormattingProfile.defaultAssignments` already puts chat apps on
`.technical`, and `.technical` has `rewritesPhrasing = true` — it promises to
turn "I'm not a fan of the shadows" into "Remove the shadows". Deterministic
rules cannot do that. Take the model away entirely and the profile silently
under-delivers its own contract.

So this lane means *no round trip*, not *no model*: `.technical` on the
on-device ladder, which `make eval` measures at p50 ~700 ms and p95 ~875 ms and
which never leaves the machine.

## Lane 2 — Correspondence

**Replying to an email. Slower, careful, correct.**

Here the text is read by a person, kept, and answered. Getting it right is worth
more than getting it now, and this is the one place where a cloud round trip
earns its latency. `com.apple.mail` is already assigned `.formal`.

The only thing this lane needs that it does not have is permission to take
longer than the global 1400 ms allowed for a remote call.

That permission has a cost worth stating plainly. `RefinementPipeline` ships the
rule output when the model misses its deadline, so a longer budget buys a better
result *or* a longer silence before the fallback. At three seconds, an
unannounced wait reads as a hang. Extending this budget is therefore blocked on
the HUD showing a working state — the latency is acceptable, the ambiguity is
not.

## Lane 3 — Composition

**Dictating a brief, not a draft.** *"Write Sarah an email saying I can't make
Tuesday and offering Thursday."*

This is the far side of the line. The output is not a tidied version of the
input; it is new text, and every guarantee the other two lanes rest on is void
here. Three consequences follow, and none of them are negotiable.

**It is not a refinement mode.** `Refiner` is `(text) -> text` over the same
content, and the whole ladder — rules first, model time-boxed, guard vetting the
result — is built around output that is a restatement of its input. Composition
is a different contract with a different guard. It belongs beside the ladder,
not as a rung on it.

**It is summoned, never inferred.** No entry in `appProfiles` may route here. If
being in Mail were enough to trigger composition, then "reply to Sarah about
Tuesday" produces a fabricated email instead of that sentence — the user gets
words they did not say, in a message they are about to send, having done nothing
unusual. The `voiceCommandPrefix` ("dash") is the existing mechanism for marking
speech as something other than dictation, and the natural trigger is a spoken
one: *"dash write, …"*. Note that this is not a `VoiceCommand` case; those press
keys.

**It is read before it lands.** Composed text is the only output Masterful
produces that the user cannot verify by remembering what they just said. It
surfaces in the island for approval rather than inserting on its own. The HUD
already expands to be read; this is what that is for.

## What the current design gets wrong

**Tone is per-destination. Effort is global.**

`Settings.profile(forBundleID:)` resolves a `FormattingProfile` per app, so
Masterful already knows to sound different in Mail than in Terminal. But
`Settings.refinement` is one `RefinementMode` for the whole machine, so it cannot
know to *try* differently. Choose `Cloud AI` for the sake of email and every
chat message pays a network round trip to be tidied; choose `Tidy` for the sake
of chat and email gets rules only.

Lanes 1 and 2 are the same request from opposite ends, and one change serves
both: widen the per-app table from a profile to a policy.

```
DestinationPolicy = (profile, ladder, budget)
```

The work is smaller than it sounds. `RefinerFactory.make` already takes `mode`,
`profile` and `budget` as parameters, and `DictationCoordinator.refine()` is the
only place that builds a refiner. The factory currently ignores the caller's
`budget` for the model stage and substitutes its own per-mode constant; that
substitution moves out to the policy, which is the one real change to its
internals.

One property must survive: whatever a policy asks for, rules still always run,
the model stage is still always time-boxed, and `TranscriptGuard` still vets the
result. Per-destination effort changes how hard Masterful tries. It may not
change what it is allowed to do.

## Deliberate non-goals

**Masterful does not detect the lane from what you said.** Deciding between
"transcribe this" and "compose this" by classifying the utterance would be a
guess made on every dictation, and a wrong guess in either direction is severe:
a brief typed out literally is merely annoying, but a sentence taken as a brief
puts invented words in front of the user's recipient. The prefix is a worse
interface and a better contract.

**Masterful does not make composition available without a key.** This lane is
remote-only by nature, and offering a degraded local version of "write me an
email" would produce exactly the kind of output the rest of the app exists to
refuse.

**`Tidy` stays the default.** Most dictation does not need a model to be worth
inserting, and a first run that reaches the network before the user has asked it
to is not the first run this app should have.
