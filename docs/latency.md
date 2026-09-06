# Latency budget

Dictation is judged almost entirely on the gap between letting go of the key and
seeing text. Everything else is negotiable; this is not. The budget below is a
contract, not an aspiration — each stage emits an `OSSignposter` interval under
`com.tlotliso.masterful:latency`, so it is measured rather than asserted.

| Stage | Budget | Signpost |
|---|---|---|
| Hotkey edge → HUD visible | 50 ms | `hud.present` |
| Hotkey edge → first audio buffer | 80 ms | `capture.start` |
| Key release → final transcript (5 s utterance) | 400 ms | `transcribe.finalize` |
| Final transcript → refined text (rules) | 5 ms | `refine` |
| Final transcript → refined text (on-device) | 1200 ms | `refine` |
| Refined text → characters in the field | 100 ms | `insert` |
| **Key release → text on screen** (rules) | **< 1 s** | `session.total` |
| **Key release → text on screen** (on-device) | **< 1.8 s** | `session.total` |

## Where the budget is spent, and how it is defended

**Engine warm-up is paid at launch, not per utterance.** `AudioCaptureEngine`
builds its graph and installs the tap during bootstrap, then leaves them alone.
Pressing the hotkey calls `start()` on an already-prepared engine and gates a
flag the audio thread reads. Rebuilding the graph per session would cost roughly
a hundred milliseconds and make the microphone indicator flicker.

**Recording starts on the press, never after a disambiguation delay.** See
`HotkeyResolver`. Waiting out the double-tap window before deciding what a press
meant would add the entire window to every push-to-talk utterance.

**The refinement stage is time-boxed and optional.** `RefinementPipeline` races
the model against a deadline and ships the deterministic rule output if it loses.
A slow model may cost quality; it may never cost latency.

The deadline is set from measurement, not preference. `make eval` puts the
on-device model at **p50 ~700 ms, p95 ~875 ms** across the corpus. The original
600 ms figure was chosen before any of that existed and rejected 8 of 12 results
— which did not make the app faster, it made the on-device stage dead code that
burned most of a second and returned the rule output anyway. The budget is now
1200 ms, with headroom over the measured p95.

Two consequences are stated honestly rather than hidden. On-device clean-up
raises the release-to-text figure to roughly 1.5 s, which is the documented price
of correct sentence boundaries. And `Tidy` remains the default, because most
dictation does not need a model to be worth inserting.

**The model is warmed while the user is still speaking.** A cold first call
measured 1527 ms against ~700 ms warm, essentially all of it weight loading.
`FoundationModelsRefiner.prewarm()` is called the instant the hotkey goes down,
so that cost is paid during the utterance rather than after it.

**Insertion does not wait on cleanup.** `PasteInserter` restores the pasteboard
on a detached task after the paste has been posted, so the HUD is already
collapsing while the clipboard is being put back.

## How a deadline can enforce nothing

The first implementation of `withBudget` raced the model against a sleep inside a
`withTaskGroup`, took `group.next()`, and called `cancelAll()`. It returned the
right value and bounded nothing: a task group implicitly awaits every child
before returning, and inference does not check for cancellation, so the caller
still waited out the full model call. Measured latencies sat *above* the budget
that was supposed to cap them, which is the only reason it was caught.

The race is now resolved on a continuation claimed by whichever side finishes
first, and `RefinementPipelineTests` asserts on the clock rather than only on the
returned text — the original test passed happily against the broken version.

## Deliberate non-goals

The 280 ms capture tail in `DictationSession.captureTail` is *added* latency, on
purpose. People trail off, and cutting the stream the instant the key comes up
reliably clips the last word. A quarter of a second is well worth not losing the
end of every sentence.
