# Decisions worth knowing about

The README is the short version. This page is the long one: the problems that
shaped the app, and why each was solved this way rather than the obvious way.

**Contents**

- [Input](#input) — bindings, the event tap, press vs. release
- [Audio](#audio) — releasing the microphone, ducking other apps
- [The island](#the-island) — focus, colour, shape, measurement, motion
- [Text and safety](#text-and-safety) — the guard, injection, insertion, secure input
- [Privacy and packaging](#privacy-and-packaging) — history, sandboxing, no `.xcodeproj`

---

## Input

**Bindings are a list, not a setting.** One machine is several machines over a
day: open on a desk the Globe key is under your thumb; closed in clamshell with
an external keyboard and mouse it is not reachable at all. So every binding is
live simultaneously — Globe *and* a mouse side button *and* a chord on an
external keyboard — and docking never means re-recording anything. A session is
owned by whichever trigger started it, so resting a thumb on the mouse button
while holding Globe cannot end a dictation half way through a sentence.

**One event tap handles Fn, chords, and mouse buttons.** `RegisterEventHotKey`
cannot see the Globe key (it is a modifier flag, not a key code) and cannot see
mouse buttons at all. A single `CGEventTap` covers all three through one
`Trigger` type — which is what makes a mouse side-button a first-class dictation
trigger rather than a special case. Left and right modifiers are told apart via
the device-dependent flag bits; the general masks cannot do it correctly when
both sides are held. The tap runs on its own thread and re-arms itself on
`tapDisabledByTimeout`, which is why it does not quietly die after a few hours.

**Recording starts on the press; the release decides what it was.** Waiting out
the double-tap window before acting adds the whole window to every push-to-talk
utterance. Instead the microphone opens immediately and a short release holds it
open for a possible second tap. See `HotkeyResolver`.

## Audio

**The microphone is released when you stop talking.** The audio graph — tap,
converter, format — is built once and reused, because rebuilding it per utterance
is latency nobody asked for. The *device* is a different matter: macOS lights the
recording indicator for as long as the input device is running, not while buffers
are being read, so an engine left up between sessions is an orange dot that never
goes out. `AudioCaptureEngine` closes the gate after the capture tail and then
stops the engine after `idleGrace`, which is what turns the indicator off; the
next hotkey press pays tens of milliseconds to start it again, and back-to-back
dictations inside the grace pay nothing. Start and teardown are serialised on one
queue, so a teardown firing as a session begins can never leave the microphone
stopped while the session believes it is open. On a Bluetooth headset this is
visible: opening the mic renegotiates the device down to its hands-free profile
and releasing it restores playback quality, once per dictation.

**Other audio is ducked, not paused, and never left ducked.** macOS has no
public per-application output volume — the tools that really do it ship a kernel
driver — so `OutputDucker` fades the default output device instead, which lowers
everything rather than just the browser tab. Three details make that acceptable
rather than rude: it only ducks when something is actually playing, so it never
captures a volume to restore that nobody was listening to; it fades over ~180 ms,
because a step change reads as the media player being yanked; and on the way back
up it checks the volume is still the one it set, so reaching for the volume keys
mid-sentence beats anything the app remembers. Restore waits out the capture
tail — bringing the video back while the microphone is still open would put it in
the recording — and the original volume is restored on quit, against the device
it was taken from rather than whatever is default by then.

## The island

**The HUD must never take focus.** A non-activating `NSPanel` that cannot become
key. If it took focus, the field the user was typing into would lose it and there
would be nowhere to insert. Everything else about the window follows from that.
The window is oversized and fully transparent with all animation happening in
SwiftUI inside it — animating an `NSWindow` frame in lockstep with its content is
where floating HUDs get their jank.

**Recording is white; outcomes carry colour. Nothing casts a shadow.** Listening
is the state you see every time you use the app, often for seconds at a stretch,
so it stays neutral and refuses to compete with the work behind it — a saturated
tint in the notch reads as an app announcing itself. The states after it are
brief and rare, and there colour is doing real work. Separately, nothing in the
app casts a shadow: a shadow is a claim to be floating above the display, and the
island is cut into it. If something looks like it needs a shadow to be legible,
the shape or the contrast is wrong.

**The HUD is one black shape that changes size.** On a notched Mac it rests
exactly filling the notch — same black, same height, same bottom edge — so at
rest it is invisible, and starting dictation makes the notch appear to widen.
There is no second panel and nothing cross-fades: `IslandShape` interpolates one
rounded rectangle's width, height and corner radii, which is why every state
change reads as the same physical object. It shows a bar while things are going
well and opens into a card only when there is something to read
(`DictationPhase.hudPresentation`), which is also why the live transcript is not
drawn — the one moment you cannot spare the attention to read is while you are
still speaking. Displays without a notch get the same island as a floating card.

**The island is measured against the camera, not the screen.** Two of the
numbers macOS reports are not quite the hardware, and both show. The physical
cutout is a point or two deeper than `safeAreaInsets.top`, so an island drawn to
that figure leaves the notch protruding below the bar as a small bump in the
middle; it overshoots on purpose, because the errors are asymmetric — too tall
is invisible against a wider shape in the same black, too short is not. And the
menu-bar strips either side are not equal widths — 763pt and 762pt on a 14-inch
Pro — which puts the notch half a point right of the display's midline. The
island centres on that, and its two flanks are always the same width, so the gap
it keeps clear stays over the camera however wide the readout grows. Sizing the
flanks independently slid that gap left by half their difference and posted the
text behind the notch, which is why the clipping got worse the more you said.

**Four things become one thing.** Listening draws a live waveform. The moment
the key comes up those four bars fall to the row of dots the waveform already
draws in silence, gather to the centre, and weld into a single ball that breathes
on its own. It is one view at two values of one number — `VoiceIndicator`, with
`coalescence` running 0 to 1 — rather than two indicators taking turns, and the
join is a blurred layer cut with an alpha threshold, so the shapes fuse at their
boundary the way two drops do instead of sliding over one another.

![Four bars falling to dots, gathering to the centre and welding into one
breathing ball](island/morph-closeup.gif)

The version before it failed for a reason only visible on the hardware: at the
top of a screen, in the corner of your eye, *anything small that throbs reads as
the waveform*. A thinking indicator that pulsed in place looked exactly like
still recording, and the glyph beside it was literally `waveform`. Hue and a 12pt
symbol were carrying the whole distinction, and peripheral vision resolves
neither. What separates the two states now is cardinality — four jostling things
driven by your voice, against one whole thing driven by a clock — which the eye
reports far faster than either. The morph runs on its own spring, the only place
in the app deliberately slower than the island around it: at the usual 0.34s the
fusion took three frames, which is correct as a state change and useless as a
depiction of one.

Every frame of that is the shipping view. The coalescence values come from
`Motion.coalesceSpring` — the same spring SwiftUI runs in the app, sampled at the
frame times — so retuning the spring changes the documentation with it. The
entrance in the README is the same trick one level up: the island's arrival *is*
its size changing, so the strip walks `Motion.enterSpring` and `Motion.exitSpring`
through `HUDView`'s own geometry rather than animating a shape that merely
resembles it. The view keeps deciding what "open" means for each phase; the
renderer only says how far along the spring is.

**Type and colour are the platform's, not ours.** Every size in the app resolves
to a macOS HIG text style rather than to a point size someone liked, and every
colour to a system colour — which means both arrive already tuned per appearance,
already correct under Increase Contrast, and already following the user's text
size. `.system(size: 12)` is frozen at twelve points forever and pairs with
nothing. Emphasis is a weight applied to a style, never a jump to the next size
up. The island is the documented exception on both counts: its type is fixed
because its geometry is *reserved* rather than measured — the shape springs to a
height before the text inside it is laid out, and it has to land exactly on the
notch's edge — and its fill is pure black because no dynamic colour's job is
"exactly the black of a MacBook's display housing". Deviations are written down
where they happen rather than left to be discovered.

## Text and safety

**Clean-up can never change what you said.** `TranscriptGuard` bounds any model
rewrite by length ratio and token retention, and anything that trips it is
discarded in favour of the deterministic rule output. It is tested against
hallucination, truncation, and the model answering the transcript instead of
formatting it. Slightly untidy words you *did* say always beat tidy words you did
not. The model stage is also time-boxed: it may cost quality, never latency.

**Dictated speech is data, not instructions.** Transcripts are delimited before
they reach any model, and the prompt says so. Speech that happens to sound like a
command is text the user said out loud, not a request addressed to the model.

**Formatting follows the destination.** The frontmost app is known at insertion
time, so a terminal gets no sentence casing and Slack gets no trailing full stop.
Applying one house style everywhere is the tell of a tool that does not know
where it is.

**An inserter that cannot prove it worked does not claim success.** Chromium and
Electron apps accept an `AXSelectedText` write, report the attribute as settable,
return `.success` — and silently discard the text. Trusting that return value
means reporting success for text that never arrived, and since Accessibility runs
first, the paste fallback never gets a turn. So the caret has to have actually
moved. Where the caret cannot be read at all, the strategy declines *before*
mutating anything, because the alternative to that ambiguity is either losing the
text or pasting it twice. `make probe` diagnoses this per app.

**Secure input is refused, not worked around.** When a password field has focus,
Masterful declines to listen and says so. Dictating a credential would route it
through a microphone, a recogniser, and the clipboard.

### Spoken commands

Dictation that can only produce text cannot submit a form, clear a field, or
correct itself. On an open laptop that is a minor gap. In clamshell mode, lid
shut, it is the difference between the product working and not.

Say **"dash enter"** to press Return, **"dash delete"** to erase, **"dash clear"**
to empty a field. The full set is in Settings → Dictation.

The design problem is ambiguity: any word chosen as a command is also a word
someone might dictate. Two rules resolve it, and the second exists because the
first was not enough.

A prefix must be followed by a **known command** — "I'll dash to the shop" keeps
its "dash", because "to" is not a command. And a command must **end the
utterance**: only a trailing run of commands counts, so anything with more speech
after it reverts to plain text. That second rule is what stops you triggering a
command by talking *about* one. It is not hypothetical — asking "what's the use
case for dash tab" fired a real Tab, moved focus out of the text field
mid-sentence, and sent the rest of the sentence to another window.

The cost is that commands can no longer be interleaved between runs of text.
That is a real loss and the right trade: interleaving is a convenience, while a
misfire silently corrupts what the user was saying. Doing better needs the pause
before a spoken command, which means timing data the parser does not have.

Commands are parsed *before* the clean-up stage runs, deliberately. If the model
saw "dash enter" it would tidy it into prose and the action would be silently
turned back into text.

## Privacy and packaging

**History stores transcripts, never audio.** Keeping recordings would make this
database the single most sensitive file on the machine, and nothing the app does
needs them once the transcript exists. The store is explicitly local — no
CloudKit — and the API key for the optional cloud mode lives in the Keychain
rather than in the settings file.

**Not sandboxed.** Event taps and the Accessibility APIs are categorically
unavailable to sandboxed apps. That is inherent to this class of tool, and it
permanently rules out Mac App Store distribution.

**There is no `.xcodeproj`.** SwiftPM builds the code; the `Makefile` assembles
the `.app` around it. Every step of bundling and signing is visible, diffable,
and reproducible from a clean checkout rather than buried in a project file. The
app icon is drawn in code by `Tools/make-icon.swift` for the same reason.
`open Package.swift` still gives Xcode and SwiftUI previews for the library
targets.

## Why the demo has a notch in it

The tour at the top of the README is a real recording, with one thing put back:
the notch. That cutout is in the panel, not in the framebuffer — macOS draws the
desktop straight through the region behind it, so **no screenshot or screen
recording of a Mac contains a notch**. Left alone, a recording shows this island
as a black bar hanging off the top edge for no visible reason, which is the one
thing the design is not. So the camera housing is composited back at the geometry
`HUDController` measures from that display — 763–948pt across, 33pt down — which
is the only frame-by-frame edit in it.

It is five separate dictations rather than one long morph through a list. The
island returns to the bare notch between them because that is what the app does:
a session ends when its outcome has been shown, and nothing in the product ever
turns a delivered card into a refusal card.
