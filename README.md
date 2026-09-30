# Voxa

A voice-controlled automation agent for macOS. Hold a hotkey, speak a command, and Voxa carries it out on your Mac using
an LLM with tool calling, then shows and speaks the result. It lives in the menu bar, listens only while you hold the
key, and transcribes your voice on the Mac. The model can be Claude, OpenAI's GPT, or a model that runs on your own Mac
through Ollama.

> **Status: milestone 4 of 5.** Hold the key, speak, and Voxa carries the command out with an LLM and tools for apps and
> links, Shortcuts and AppleScript, your calendar and reminders, the clipboard, **other apps' windows (reading, clicking,
> typing, shortcuts), screenshots and your files**, asking your permission for anything that isn't safe, and answering aloud.
> **Whisper** is available as a speech engine that runs on your Mac. A welcome guide sets up permissions and the model on
> first launch, and Settings has a switch for every tool, a Permissions page and the history of what Voxa did. What is left
> is hardening, signing and notarization (milestone 5). See [Roadmap](#roadmap).

## Requirements

- macOS 14 or later (macOS 26 recommended: it enables Apple's newer speech engine and the Liquid Glass HUD)
- Xcode 26 / Swift 6.2 to build
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you change `project.yml` (`brew install xcodegen`)
- A Developer ID certificate only for signed, notarized distribution

## Quick start

```bash
make run          # builds Voxa.app (Debug, ad-hoc signed) and launches it
```

Look for the microphone icon in the menu bar. On the first launch a **welcome guide** opens: it explains what Voxa does,
asks for the microphone and speech-recognition permissions, and helps you choose a model. (It can be reopened from
Settings → General.) Or do it by hand:

1. **Choose a model**: menu bar icon → **Settings…** → **Model** → pick a provider (see [Models](#models)) → paste its key
   → **Save**. Keys go into the macOS Keychain and nowhere else. (**Test connection** makes a tiny request to check it.
   Until a key is saved, a command answers *Add your OpenAI API key* (or Anthropic's) with a button that opens this page.)
2. **Hold ⌥Space, speak, release.** The first time, macOS asks for Microphone and Speech Recognition access; the HUD
   explains anything that's missing and offers a button that opens the right System Settings pane.

Try: *"open Notes"*, *"open apple.com"*, *"what's on my calendar today?"*, *"remind me to call the bank tomorrow at ten"*,
*"what's 6 times 7, use AppleScript"* (it will ask before running the script).

> **Permissions and rebuilds.** An ad-hoc signature changes on every build, so macOS treats each build as a new app: it asks
> again, and an Accessibility entry left over from an earlier build can show as switched on in System Settings while doing
> nothing. To keep your grants across rebuilds, sign development builds with your Developer ID: `make run-signed`
> (`scripts/build.sh --sign-dev --run`). macOS asks once to let the build use your signing key: choose *Always Allow*.
> If Accessibility says *Not asked yet* although Voxa is on in the list, select Voxa there, press **−** to remove it, and press
> **Allow…** in Voxa again.

## Models

Pick one in **Settings → Model**. Everything after the model (the agent loop, the policy, the confirmation card, the tools)
is identical for all three, so the safety rules don't depend on which one you use.

| Provider | You need | Default model | Notes |
|----------|----------|---------------|-------|
| **Claude** | An Anthropic API key (`sk-ant-…`) | `claude-sonnet-5-5` | Messages API |
| **OpenAI** | An OpenAI API key (`sk-…`, the one you would put in `OPENAI_API_KEY`) | `gpt-6-luna` | Responses API; Voxa asks OpenAI not to store the conversation. Any model that can use tools works |
| **Ollama** | The [Ollama](https://ollama.com) app running, and a model that can use tools | none (you choose) | Runs on your Mac: the text of your command never leaves it. Default address `http://localhost:11434` |

- **A GUI app doesn't see your shell's environment,** so paste the key into Settings rather than exporting `OPENAI_API_KEY`.
  Voxa reads it from the Keychain only. (`voxa-dev`, the command-line tool, does read `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`.)
- **Ollama models must support tool calling.** Settings lists what the server has and warns about a model that can't call
  tools (for example `gemma2`); `qwen3` and `llama3.1` can. Install one in Terminal: `ollama pull qwen3:8b`. Small models
  are quicker but less reliable at picking the right tool; the policy still asks before anything risky, whichever you use.
- **Cloud models in Ollama** (names ending in `-cloud`) run on Ollama's servers, so what you say leaves the Mac. Settings
  marks them.
- The **context window** for Ollama defaults to 16,384 tokens, because Ollama's own default would silently cut off Voxa's
  instructions and tool list. Raise it in Settings if you use long clipboard or file contents later on.
- Try a key or a model without the app: `voxa-dev chat "say hello" --provider openai` (also `--provider ollama --model qwen3:8b`).

## Speech engines

**Settings → General → Speech recognition** offers three engines, all of which run on your Mac:

| Engine | What it is |
|--------|------------|
| Automatic | Apple's newest engine when its language model is installed, otherwise the classic recognizer |
| Classic | `SFSpeechRecognizer`, forced on-device |
| **Whisper** | OpenAI's Whisper, run through Core ML ([WhisperKit](https://github.com/argmaxinc/WhisperKit)). It needs a model, which you download once |

Choosing Whisper shows a list of models with their sizes: Tiny (about 80 MB, all languages), Base (about 150 MB, English or all
languages) and Small (about 490 MB, English or all languages). **Nothing is downloaded until you press Download.** The models
come from Hugging Face (`argmaxinc/whisperkit-coreml`); after the download Voxa prepares the model for your Mac's chip, which
takes a minute the first time, and from then on Whisper works offline. Models are kept in
`~/Library/Application Support/Voxa/Models/whisper` and **Remove** deletes one. Base (English) is a good start for English:
quick enough for a spoken command and much better than Tiny at names and numbers; the multilingual ones follow the recognition
language chosen above them.

While you hold the key Whisper shows a live guess about once a second (it re-reads everything heard so far), and the final text
when you let go. Silence and noise are never sent to it, and the sound annotations it makes up (`[BLANK_AUDIO]`, `(music)`) are
removed. It needs no Speech Recognition permission. If the model you chose isn't on the Mac, the command says so, with a button
that opens Settings. Try it without the app: `swift run voxa-dev transcribe clip.aiff --engine whisper --model base.en --download`
(the `--download` is what fetches the model).

## What Voxa can do

Every tool has a switch in **Settings → Tools**; a tool that is off is hidden from the model and refused if called anyway.
The right-hand column is how Voxa behaves out of the box: **Settings → Safety → Full control** (off by default) turns the
asking off, and the Safety section below says exactly what it changes.

| Tool | What it does | How it is treated |
|------|--------------|-------------------|
| Open apps, open links | Opens an app or a web page (only opens it: playing or clicking something on it is a further step) | Runs, and tells you |
| Wait | Pauses up to 10 seconds so a page or app can finish opening before Voxa looks at it | Just runs |
| List and run Shortcuts | Runs one of your Shortcuts | **Always asks** |
| Run AppleScript | Runs a script you read first | **Always asks**; shell routes are refused |
| Read your calendar | Lists events for a day or a week | Runs; what it returns is untrusted data |
| Add a calendar event | Adds one (never invites anyone) | Runs, and tells you |
| Change or delete a calendar event | Moves, renames or removes one occurrence | **Always asks**; warns if others are invited |
| Read your reminders, add a reminder | Lists what is due, adds one | Read runs; add tells you |
| Read the clipboard | Reads the text you copied | Tells you; untrusted; **never** something a password manager marked secret |
| Copy to the clipboard | Puts text there for you to paste | Tells you |
| See what's in front | The front app, and with Accessibility its window title and your selection | Runs; title and selection are untrusted |
| Look at an app's window | Lists the buttons, fields and menu items of the front app (or its menu bar), each with a short reference | Runs; the list is untrusted data; needs Accessibility |
| Click, type and press keys in other apps | Presses a listed control (or a point in a screenshot), types where the cursor is, presses shortcuts such as ⌘S | Tells you; **asks** once anything has been read from outside; **always asks** for a control that sends, deletes or buys, a quit or log-out shortcut, or text with a line break; **never** in a password field, a terminal, or a password manager |
| Look at the screen | A picture of the front window (only if you ask for it, the whole screen) for the model to read, as a last resort | Tells you; the whole screen **always asks**; needs Screen Recording; the picture isn't kept after the command |
| Find files, show in Finder | Searches file names in your home folder; shows one in a Finder window | Runs; the names are untrusted data |
| Move files, move to the Trash | Moves files into a folder, or renames one; puts files in the Trash | **Always asks**; never replaces a file, never deletes one, and refuses hidden folders, your Library, the standard folders themselves, the inside of apps, and anything outside your home folder and external drives |

## Using it

| You do | Voxa does |
|--------|-----------|
| Hold ⌥Space | HUD appears near the top of the screen: *Listening…*, a level meter and the live transcript |
| Release | Records a fraction of a second more (so the last word isn't clipped), then *Transcribing…*, then *Thinking…* while the model works and the name of each action while it runs |
| A risky action comes up | A card shows exactly what will happen (the whole script, the address, the app) and why Voxa is asking. **Allow** / **Don't Allow**, **⌘↩** to allow, or hold ⌥Space and say *yes* or *no*. Esc stops the whole command. No answer in 60 seconds counts as *no* |
| The reply | A short answer stays up for a few seconds and is **read aloud** (switch it off in Settings → General → Voice). Holding ⌥Space or pressing Esc stops the speech at once. Hold ⌥Space within two minutes for a follow-up ("make it three hours") |
| Tap the key briefly | A hint: *Hold ⌥Space while you speak*. Push-to-talk needs a hold |
| Press Esc | Cancels the command at any point (listening, thinking, or waiting on a question) and dismisses; while a reply is showing, Esc dismisses it |
| Say nothing | *I didn't catch that* |
| Deny a permission | An error naming the permission with a button that opens System Settings |

The HUD never steals focus from the app you're working in. Change the shortcut or the recognition language in
**Settings…** (menu bar icon).

## Project layout

See [docs/DESIGN.md](docs/DESIGN.md) for the full design. In short: all logic is a Swift package of small modules
(`VoxaCore`, `VoxaAudio`, `VoxaSpeech`, `VoxaWhisper`, `VoxaPermissions`, `VoxaHUD`, `VoxaSettings`, `VoxaLLM`, `VoxaPolicy`,
`VoxaTools`, `VoxaAgent`, `VoxaApp`); the Xcode project only wraps `VoxaApp` in an app bundle with the Info.plist, entitlements and signing.

**From key press to recognized text**

```mermaid
sequenceDiagram
    actor User
    participant HK as Hotkey service
    participant S as VoiceSessionController
    participant P as Permissions
    participant M as MicrophoneCapture
    participant R as Speech recognizer
    participant H as HUD
    User->>HK: hold ⌥Space
    HK->>S: pressed
    S->>H: Getting ready…
    S->>P: ensure microphone (+ speech) access
    S->>M: start()
    M-->>S: audio chunks and levels
    S->>H: Listening…
    M-->>R: 16 kHz mono chunks
    R-->>S: partial transcripts
    S->>H: live transcript
    User->>HK: release
    HK->>S: released
    S->>M: stop() after a short tail
    R-->>S: final transcript
    S->>H: Heard: "…"
```

**From recognized text to a done thing**

```mermaid
sequenceDiagram
    actor User
    participant S as VoiceSessionController
    participant A as AgentLoop
    participant M as Model (Anthropic API)
    participant P as PolicyEngine
    participant C as Confirmation card
    participant T as Tool
    S->>A: command (transcript)
    loop at most 12 turns
        A->>M: conversation + tools (streamed)
        M-->>A: text, or tool calls
        A->>A: validate JSON, schema, and the tool's own assessment
        A->>P: what would this call do? (risk, taint, settings)
        alt sensitive, or outside content was read
            P-->>A: ask
            A->>C: exactly what will happen, and why
            C-->>User: Allow / Don't Allow, ⌘↩, or say yes / no
            User-->>C: answer (no answer in 60 s means no)
        else safe
            P-->>A: allow
        end
        A->>T: execute (time-limited, cancellable)
        T-->>A: result (wrapped as untrusted data if it came from outside)
        A->>M: tool results, in one message
    end
    A-->>S: reply
    S-->>User: HUD shows the reply
```

## Permissions

| Permission | Used for | When it is asked |
|------------|----------|------------------|
| Microphone | Hearing your command | First push-to-talk, or from the welcome guide |
| Speech Recognition | Apple's classic on-device recognizer (not needed by the newer engine) | First push-to-talk, only if that engine runs |
| Calendars, Reminders | The calendar and reminders tools | The first time a command needs one, or ahead of time from Settings → Permissions |
| Accessibility | Reading the front window (title, selection, its controls) and clicking, typing and pressing keys in it | When a command needs it (macOS sends you to System Settings to switch it on), or ahead of time from the welcome guide or Settings → Permissions |
| Automation | `run_applescript` controlling another app | The first time a script talks to that app (macOS asks per app) |
| Screen Recording | The `screenshot` tool | When a command needs it, or ahead of time from Settings → Permissions |
| Files and Folders | Moving or trashing files in Documents, Desktop, Downloads and similar | macOS asks the first time Voxa touches each of them; Voxa has no switch of its own for it |

Voxa asks macOS at the moment a tool needs a permission, and the command's clock stops while the prompt is up. If you have said
no, the command ends with a message and a button that opens the right System Settings pane, rather than the model
being asked to write around it. **Settings → Permissions** shows all of them at once with a button on each, and a row turns green
when you come back from System Settings.

Speech recognition is always on-device. If a language has no on-device model, Voxa says so and tells you how to install
one rather than sending audio to Apple's servers.

## Security model

Voxa can act on your Mac, so the design assumes that anything it reads may be hostile, and that the model can be fooled.
The policy engine is the security boundary (the app can't be sandboxed: Accessibility and Apple Events need it), and it is
exhaustively tested. The rules, all in force in this milestone:

- **Push-to-talk only.** The microphone is open only while the key is held; macOS shows its orange indicator meanwhile. A
  spoken *yes* also needs the hold, so audio from a video or another voice can't approve anything.
- **Only your spoken command is an instruction.** Script output, the screen, another app's controls, the clipboard, file names and web pages are *data*:
  it reaches the model wrapped in a random-boundary envelope, stripped of invisible characters, and can't close its own
  envelope. The system prompt tells the model to treat it as data.
- **Three risk tiers, decided by code, not by the model.** Read-only actions run; reversible ones run with a notice;
  sensitive ones (running scripts and Shortcuts, moving or trashing files, a button that sends or deletes, a quit shortcut) **always** ask,
  unless you have given Voxa full control (below). Risk only goes
  *up*: the highest of what the tool says, what the policy says about that tool, and what the call turns out to be. The
  model can't pass a "risk" or "confirmed" argument; the tool schemas forbid extra arguments and every call is validated
  against them.
- **Untrusted content raises the bar.** After the model has read anything from outside your command, even reversible
  actions ask, and the card says why. (In testing, a script whose output told the model to open a hostile link did fool the
  scripted model. The link was not opened without a prompt, and declining it ended the attempt.)
- **Full control is a switch only you can flip.** *Settings → Safety → Full control* (off by default) makes Voxa carry out
  commands without an Allow card: deleting and moving files, calendar changes, AppleScripts and Shortcuts, clicks and typing in
  other apps (System Settings and Disk Utility included), and everything that would have asked because it had read something from
  outside. Turning it on asks you first (*Give Voxa full control?*);
  turning it off is immediate, even for a command that is running: its next action asks. While it is on, the menu-bar menu says **Full control is on** and has *Turn Off Full Control*, the
  Tools tab says so, and History marks each action that ran that way (*ran without asking (full control)*). It is read from your
  settings when a command starts, never from the model or anything it reads, and Voxa's own windows are off limits to its UI tools
  and its scripts, so a fooled model can't open Settings and switch it on. It removes questions, not refusals: password fields,
  terminals and password managers, hidden and Library files, shell access from scripts (`do shell script`, Terminal) and blocked
  links stay refused. macOS's own permission prompts are the system's and still appear. The model is told confirmations are off,
  so it takes more care with what can't be undone. The price is real: with it on, something a web page or an email says to the
  model can be acted on without you seeing it first, and a script nobody read runs. The script check that refuses the routes to a
  shell is a speed bump, not a sandbox, and with full control on there is no reader behind it.
- **Voxa checks that a command is really finished.** Models like to stop at the first step that looks like an answer ("I opened
  the search results" for *play it on YouTube*). When the model wants to reply after a step that may be only a start (opening a
  page or an app, waiting, looking, clicking, typing, a script), the reply is first put to a short separate request to the same
  model, with no tools: *given what the user said, the names of what was done, and this reply, is anything they asked for plainly
  still left?* It answers in a fixed shape (done or not, what is left, how sure). If something is left and it is sure, the model
  is sent back to finish, at most twice, with a note that can only ask for the user's own command. The reply stands if the check
  can't be made, if the model asked you a question, if you said no to something on the way, if the model itself looked at the
  result of its last action (the check can't see the screen either), or if it was sent back and answered again with nothing new
  done: it has made its case. The check never sees what a page,
  window or file returned, only your words, the names of the steps (as data) and the reply. It costs one short extra request
  after such commands; *Settings → Safety → Check that a command is finished* turns it off, and History shows each check.
- **You see the real thing.** The card is written by the tool's own code from the validated arguments: the whole script,
  the exact address, the app. Hidden and text-direction characters are shown as visible markers.
- **No shell.** There is no arbitrary-command tool. AppleScript that reaches for `do shell script`, Terminal, other scripts,
  Objective-C bridging or remote machines is refused before you are asked. This is a speed bump, not a sandbox: an AppleScript
  is always sensitive precisely because *you* reading it is the real check.
- **Links are vetted.** Web, mail, phone, message and map links only; never `file:` or a custom scheme; credentials in an
  address, backslashes and encoded host names are refused; local-network addresses, bare IPs, look-alike names and
  data-stuffed addresses need your OK.
- **Bounded.** At most 20 steps (*Settings → Safety → Steps per command*, up to 40; a step is one turn of the model, however many
  tools it calls in it, and it is told to send calls that don't depend on each other together), 30 seconds per action, about
  nine seconds a step for the whole command (three minutes at 20; not counting time spent deciding), and two
  refusals end the command. Esc stops everything, including a running script.
- **Append-only audit log** of commands, tool calls, decisions and your answers: `~/Library/Application Support/Voxa/audit.jsonl`
  (private to you, JSON Lines, capped at 5 MB). It holds no tool output and no key. **Settings → History** shows it grouped by
  command, with a search, *Show in Finder* and *Clear History*: the only way anything is ever removed from it.
- **Your calendar, reminders, clipboard and screen are outside content.** Whatever they return reaches the model as untrusted
  data, and once it has, even reversible actions ask (an invitation from a stranger can carry an instruction). The clipboard tool
  honors the convention password managers use and never returns something marked secret. A tool's permission is checked *before*
  the tool describes what it will do, so nothing reads your calendar without access.
- **Driving other apps is checked at the moment it happens.** A reference from a listing only works while the same app is still
  in front and the control is still there with the same name; a click at a point in a screenshot only works if the window hasn't
  moved and what is at that spot is what you were asked about. Otherwise nothing is done and the model is told to look again.
  A control whose label says *Send*, *Delete*, *Buy*, *Allow* and the like always asks, as does Return when the window's default
  button looks like one, a line break in typed text (which sends in many apps), and shortcuts such as ⌘Q. Results say *what was
  done* in Voxa's own words and never repeat text from the app.
- **Some apps are off limits.** Voxa neither reads nor drives terminals (typing there would run commands, which would get around
  the no-shell rule), script editors, password managers, Keychain Access, or the windows macOS uses to ask for your password;
  System Settings, Disk Utility and Activity Monitor are allowed but everything in them asks. It never types into a password
  field, and never reads one. This is a short hand-kept list, a second line of defence: it isn't the reason anything else is safe.
- **A picture is the most private thing sent.** The screenshot tool needs Screen Recording; it captures one window (not what is
  around it) unless the whole screen is really needed, which always asks; it skips Voxa's own windows; it is scaled down; and
  once the command is over the picture is dropped from the conversation, so it isn't sent to the model again on a follow-up.
- **Files: the Trash, never deletion.** Paths are made absolute and followed through links before they are judged. Only your own
  files can be moved or trashed (your home folder and external drives, minus hidden items, the Library, the standard folders
  themselves and the inside of apps and photo libraries). Nothing is ever replaced or deleted: the only way a file goes is
  `trashItem`, and a lint rule fails the build if the tools ever call a deleting function. Results never repeat a file name.
- **Secrets.** Each API key lives in the Keychain only (one entry per provider, this device only, never synced). Logs never
  contain keys, transcripts or tool payloads at the default level. A key is only ever sent over `https` (or to this Mac, for
  a local test server): a server address in Settings that isn't, silently falls back to the provider's own, so a bad setting
  can't hand your key to another host.
- **What is sent, and to whom.** The text of your command, the tool definitions, and the results tools return go to the
  provider you chose: Anthropic, OpenAI (with `store: false`, so nothing is kept for later lookup), or your Ollama server. With
  Ollama on this Mac nothing leaves it; an Ollama server on another machine, or a cloud model, is your own choice and Settings
  says so. Your voice never leaves the Mac. Ollama takes no key; its address may be `http` because it is usually on this Mac.

## Development

```bash
make test         # unit tests (1,165 of them, ~10 s: includes real windows on the screen, a real osascript and a real speech voice)
make lint         # SwiftLint
make format       # SwiftFormat
make snapshots    # render the HUD in every state, light and dark, to build/snapshots
```

A few suites drive real windows (the Accessibility, window-list and screenshot code, each on a window of the test's own, so
nothing of yours is ever read or clicked). They need the display awake, and the screen-capture ones also need Screen Recording
allowed for whatever runs the tests (Terminal, Xcode); otherwise they are skipped, not failed.

### Developer tools

`swift run voxa-dev <command>` exercises the building blocks without a person or a microphone:

```bash
say -o /tmp/clip.aiff "open safari and search for swift concurrency"
swift run voxa-dev speech-status                       # what each speech engine can do on this Mac (downloads nothing)
swift run voxa-dev transcribe /tmp/clip.aiff           # run an engine over a file
swift run voxa-dev system-prompt                       # print the agent system prompt exactly as sent
swift run voxa-dev ask "open example dot com" --dry-run  # a typed command through the real model client, agent loop and tools
swift run voxa-dev ask "open safari" --provider openai --dry-run                    # …with OpenAI ($OPENAI_API_KEY)
swift run voxa-dev ask "open safari" --provider ollama --model qwen3:8b --dry-run   # …with a local model
swift run voxa-dev chat "say hello" --provider openai   # one plain model call, no agent: does my key / model work?
swift run voxa-dev ollama                               # what an Ollama server has, and what each model can do (read-only)
```

`voxa-dev ask` (with `--sample-data` for the calendar and clipboard tools) needs a key (`--key`, or `$ANTHROPIC_API_KEY` / `$OPENAI_API_KEY`; Ollama needs none) or the mock server below.
`--confirm yes,no` answers the first prompt yes and the second no (default: ask at the terminal). `--dry-run` prints what
`open_app` / `open_url` would open. Keys are used to build the client and never printed.

### Testing without a key: the mock model server

```bash
scripts/mock-llm-server.py --port 8899 --log /tmp/mock.jsonl &      # a stand-in for all three model APIs
swift run voxa-dev ask "add numbers" --base-url http://127.0.0.1:8899 --confirm yes                       # Claude
swift run voxa-dev ask "add numbers" --provider openai --base-url http://127.0.0.1:8899/v1 --confirm yes   # OpenAI
swift run voxa-dev ask "add numbers" --provider ollama --model qwen3:8b --base-url http://127.0.0.1:8899 --confirm yes
```

One server speaks Anthropic's Messages API, OpenAI's Responses API and Ollama's native chat API. It validates each request as
the real service would (headers, tool-result adjacency, sorted tools, parameters a model rejects, OpenAI's message `phase`,
Ollama's context window and tool support) and answers by keyword (see its header): `add numbers` (a script that needs
confirmation), `inject` (a script whose output tries to redirect the model), `shell` (must be blocked), `ui click reload`,
`shot click`, `trash screenshots` and the other window, screenshot and file commands (see its header), `unauthorized`,
`quota`, `overloaded`, `cutoff`, `refuse`, `slow`. It pretends to have four Ollama models, one of which can't use tools.

Two scripts run the real Debug app against it, with settings in a throwaway preferences domain (yours are untouched) and
no system prompt ever appearing:

```bash
scripts/build.sh
scripts/e2e-providers.sh      # Claude, OpenAI and Ollama: a confirmation, the audit trail and every request
scripts/e2e-tools.sh          # calendar, reminders, clipboard and context tools on sample data, another app's window, screenshots
                              # and files (a pretend Safari and a pretend disk), a page and a file name with a hidden
                              # instruction, the permission gate, spoken replies (one short sentence is said aloud), the walkthrough
```

To try a build without disturbing the Voxa you are using, build it somewhere else and point the scripts at it:

```bash
DERIVED_DATA=/tmp/voxa-e2e scripts/build.sh && DERIVED_DATA=/tmp/voxa-e2e scripts/e2e-tools.sh
```

The test copy listens to notifications carrying a private suffix (`VOXA_DEBUG_HOOK_SUFFIX`), and the scripts only ever stop the
copy they started, so the Voxa you are using neither hears them nor is stopped.

`e2e-tools.sh` uses two Debug-only variables: `VOXA_DEBUG_SAMPLE_DATA=1` (or `hostile`, which adds an event, a page and a file
name that try to steer the model) makes the tools use made-up data (a pretend Safari to click in, a pretend disk), and
`VOXA_DEBUG_TOOL_PERMISSIONS=calendars=denied,accessibility=notDetermined` scripts the answers the permission gate gets.

### Debug builds

Debug builds add a **Debug: preview HUD** submenu, and the app listens for Darwin notifications so the HUD and windows can
be driven from a shell (no microphone, no key press):

```bash
notifyutil -p com.rohitsainier.voxa.debug.hud.listening      # also: partial long transcribing result notice error errorPlain hide
notifyutil -p com.rohitsainier.voxa.debug.settings           # open Settings (…settings.close, …settings.tracking, …settings.tab.model|tools|permissions|history…)
notifyutil -p com.rohitsainier.voxa.debug.onboarding         # open the welcome guide (…onboarding.step.N, …onboarding.close)
notifyutil -p com.rohitsainier.voxa.debug.key.down           # inject the push-to-talk key down / up (…key.up) into the real pipeline
notifyutil -p com.rohitsainier.voxa.debug.hud.confirmScript  # also: thinking acting reply replyLong confirmURL confirmTaint confirmLong
swift scripts/window-info.swift Voxa                          # window level, frame and visibility of the running app
```

To drive the whole agent against the mock server, with no key, no microphone and a private audit file:

```bash
open -n --env VOXA_ANTHROPIC_BASE_URL=http://127.0.0.1:8899 --env VOXA_DEBUG_API_KEY=sk-ant-mock \
    --env VOXA_DEBUG_OPENAI_API_KEY=sk-mock --env VOXA_DEBUG_DEFAULTS_SUITE=com.rohitsainier.voxa.e2e \
    --env VOXA_DEBUG_COMMAND_FILE=/tmp/cmd.txt --env VOXA_DEBUG_REPORT_FILE=/tmp/report.txt \
    --env VOXA_DEBUG_AUDIT_PATH=/tmp/audit.jsonl build/DerivedData/Build/Products/Debug/Voxa.app
echo "add numbers" > /tmp/cmd.txt; notifyutil -p com.rohitsainier.voxa.debug.ask     # submit the command
notifyutil -p com.rohitsainier.voxa.debug.key.allow      # ⌘Return   (also: key.escape, button.allow, button.deny, button.recovery, answer.yes / no / unclear)
notifyutil -p com.rohitsainier.voxa.debug.report; cat /tmp/report.txt                # status, which keys are captured, permissions
```

`VOXA_DEBUG_DEFAULTS_SUITE` keeps the app's settings in a separate preferences domain (write the provider, model and address
there instead of clicking through Settings; `scripts/e2e-providers.sh` shows how). OpenAI's and Ollama's addresses are
ordinary settings, so they need no variable.
These variables are compiled out of Release builds, which always use the Keychain, Anthropic's own endpoint and your own
preferences.

To check speech recognition without speaking, hold the injected key while the Mac talks to its own microphone, and have the
app write what it heard to a file (Debug builds only, opt-in):

```bash
open -n --env VOXA_DEBUG_TRANSCRIPT_FILE=/tmp/heard.txt build/DerivedData/Build/Products/Debug/Voxa.app
notifyutil -p com.rohitsainier.voxa.debug.key.down; say "open safari"; notifyutil -p com.rohitsainier.voxa.debug.key.up
sleep 1; cat /tmp/heard.txt
```

### Logs

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "com.rohitsainier.voxa"'   # what happened
/usr/bin/log stream --predicate 'subsystem == "com.rohitsainier.voxa"' --level debug      # watch live
```

(Use the full path: in zsh, plain `log` is a shell builtin and fails silently.) Every press and release of the shortcut
leaves a line (`push-to-talk key down` / `key up`), and each command's outcome is logged without its content.

Transcripts are never logged at the default level; at debug level they are marked private.

### Known pitfalls

- **Never size a window through Auto Layout** (`NSHostingController` `.preferredContentSize` and friends). On macOS 26
  it makes AppKit throw inside its layout pass; this crashed Settings. A lint rule enforces it; see the design doc.
- **`swift build` cannot produce a working `.app`**: SwiftPM's resource accessor expects resource bundles at the app's
  root, which code signing rejects. Build the app with Xcode (`scripts/build.sh`); use `swift test` for the logic.
- **Carbon hotkeys** cannot be modifier-only keys, and another app may already own ⌥Space (Voxa can't tell). Pick a
  different shortcut in Settings if the key does nothing. ⌥⌘Space (Command+Option+Space) is macOS's own *Show Finder
  search window* shortcut and never reaches Voxa; the default is ⌥Space (Option+Space).
- **Don't poll key state.** `CGEventSource.keyState` reads every key as up without Input Monitoring permission; a
  watchdog built on it once cut every hold to ~100 ms. Diagnose shortcut trouble with the log breadcrumbs instead.

## Manual QA checklist

Automated tests cover the state machine, audio conversion, the model client, the agent loop, the policy and window behavior,
and the app has been driven end to end against a mock API server. These need a person, real hardware, macOS permissions and
a real API key:

- [ ] Launch: a microphone icon appears in the menu bar; the menu reads "Ready — hold ⌥Space to talk".
- [ ] First press: the Microphone prompt appears; after Allow, and the Speech Recognition prompt, holding ⌥Space works.
      (If you released the key while a prompt was up, the HUD says *You're all set*.)
- [ ] Hold and speak: the HUD shows *Listening…*, the meter moves with your voice, words appear live.
- [ ] Release: *Transcribing…*, then *Heard* with the final text; the HUD fades out after about three seconds.
- [ ] Quick tap: the HUD says *Hold the shortcut while you speak*, then fades; no error, and no orange microphone dot left behind.
- [ ] Esc while listening: the HUD disappears and the orange microphone dot goes away immediately.
- [ ] Esc while a result is showing: dismisses it. Esc elsewhere, when no HUD is showing, still reaches your app.
- [ ] Say nothing: *I didn't catch that*.
- [ ] Deny Microphone in System Settings, then press: an error with **Open System Settings** that opens the Microphone pane.
- [ ] Focus: keep typing in another app while the HUD shows; the app stays active and no keystroke is lost.
- [ ] A full-screen app: the HUD still appears over it. Two displays: it appears on the one with the pointer.
- [ ] Light and dark mode; VoiceOver announces *Listening* and the recognized command.
- [ ] Settings: opens without a crash (repeatedly); changing the shortcut takes effect and the menu label follows.
- [ ] AirPods or another Bluetooth mic: connect one, press, speak; the command survives the audio format switch.
- [ ] Recording limit: hold the key for a minute; recording stops on its own.
- [ ] Newer speech engine (macOS 26): after the first command the model downloads in the background (check
      `swift run voxa-dev speech-status`); later commands use it. Turning off the Settings toggle prevents the download.

**Milestone 2: needs your API key and your Mac**

- [ ] Settings → Model: paste a key, Save (the field clears, "A key is saved in your Keychain"), **Test connection** says
      *Connected*. Remove it: the next command says *Add your Anthropic API key* with a working button.
- [ ] *"Open Notes"* opens Notes, the HUD shows *Thinking…*, then *Open Notes*, then a short reply. No question is asked.
- [ ] *"Open apple.com"* opens the page in your default browser. *"Open apple.com in Safari"* uses Safari.
- [ ] *"Run an AppleScript that returns 6 times 7"*: a card shows the whole script and **Allow / Don't Allow**. Allow → the reply
      says 42. Try each way to answer: click, **⌘↩**, and hold ⌥Space and say *yes* (and once *no*, and once something unclear).
- [ ] A plain Return (typing in another app while a card is up) does **nothing** to the card. ⌘↩ only works about half a second
      after the card appears.
- [ ] *"Use AppleScript to tell Finder to activate"*: macOS asks for **Automation** permission for the first time, naming Voxa.
      After Allow, the script runs; after Don't Allow, the reply explains it needs the permission.
- [ ] Ask for something impossible ("run a shell command"): a plain refusal, never a prompt.
- [ ] Esc while *Thinking…*, while a script runs and while a card is up: each stops the command and clears the HUD at once.
- [ ] A follow-up within two minutes ("and open Safari too") knows what came before; after two minutes it doesn't.
- [ ] Turn Wi-Fi off and ask for something: *You appear to be offline*, no hang. Turn it on again: the next command works.
- [ ] Settings → Safety → *For every change*: even *"open Notes"* now asks first.
- [ ] Look at `~/Library/Application Support/Voxa/audit.jsonl`: your commands, the tools, each decision and answer, no tool output.
      (Settings → History shows the same thing.)

**Milestone 3: needs your Mac and real permissions** (nothing below has been run against a real calendar, real reminders or a
granted Accessibility permission: the automated checks use sample data and scripted permission answers)

- [ ] First launch: the welcome guide opens. Its permission buttons bring up the real macOS prompts (Microphone, Speech
      Recognition, and if you press them Calendars, Reminders, Accessibility) and the rows turn green as you answer.
- [ ] *"What's on my calendar today?"* with Calendars not yet allowed: the macOS prompt appears, and after Allow the command
      answers from your real calendar. After Don't Allow, the command ends with *Calendars access is off* and a button that opens
      the Calendars pane; turning it on there and asking again works.
- [ ] *"Add lunch with Sam tomorrow at one"* adds a real event on the right day and time (check Calendar), and the reply says
      the day and time back. Try an all-day event (*"…on Friday, all day"*) and a two-day one: they must show as all-day in Calendar.
- [ ] *"Move my dentist appointment to four"* and *"cancel it"* each show a card with the event and ask first; only that one
      occurrence of a repeating event changes. An event with other attendees says so on the card.
- [ ] *"Remind me to call the bank tomorrow at ten"* adds a reminder due at ten that actually notifies (check Reminders).
- [ ] Copy some text, then *"what did I copy?"*: it reads it back and a notice says the clipboard was read. Copy a password from a
      password manager: Voxa says it was marked secret and doesn't read it. *"Copy hello"* replaces the clipboard.
- [ ] Turn Accessibility on (Settings → Permissions), select some text in another app, and ask *"what's selected?"*: it names
      the app, the window title and your selection. With it off, only the app is named.
- [ ] Replies are spoken. Change the voice and speed in Settings → General → Voice and press *Test voice*. Hold ⌥Space while it
      talks: it stops at once. With the switch off, nothing is spoken.
- [ ] Settings → Tools: turn *Open apps* off, ask *"open Notes"*: it is declined. Turn it back on.
- [ ] Settings → General → *Start Voxa when I log in*: turn it on (macOS may ask you to approve it in Login Items), log out and in.
      Turn it off again.
- [ ] Settings → History: your commands appear with what happened; search finds one; *Show in Finder* reveals the file; *Clear
      History…* asks, then empties it.

**Milestone 4: needs your Mac, Accessibility, Screen Recording and a Whisper download** (nothing below has been run against a real
app's window, real synthetic input, a real screen capture of your apps, real files in your folders, or a downloaded Whisper model:
the automated checks use a pretend desktop, a pretend disk and a made-up model. The real screenshot code was run once, on a
window of its own. Use `make run-signed` so the Accessibility grant survives rebuilds.)

- [ ] Settings → Permissions: press **Allow…** on Accessibility and switch Voxa on in System Settings; the row turns green
      within a second or two. Same for Screen Recording (macOS may ask you to quit and reopen Voxa).
- [ ] With TextEdit or Notes in front: *"press command N"* opens a new note or document, and no question is asked. *"Type hello
      world"* types it where the cursor is (a notice, no question, as nothing outside has been read).
- [ ] *"Click File and then Save As"* or *"click the Bold button"*: Voxa reads the window, then asks before clicking, and the card
      names the control. Allow → it happens. Then *"press command Q"* in a scratch app: the card explains it quits the app.
- [ ] Ask it to type into a password field (a website's login form): it refuses and says it doesn't type into password fields.
- [ ] Put Terminal in front and ask it to type something: it refuses ("runs whatever is typed into it"). The same in 1Password or
      Keychain Access, for reading the window and for a screenshot.
- [ ] *"What's on this page?"* in Safari: the reply describes what the window listing found. If a control isn't listed (a
      canvas, an image button, a Chrome or Electron app, which show little until their accessibility is on), ask *"take a
      screenshot and click the play button"*: after the screenshot it asks, and the click lands on the right spot.
- [ ] *"Take a screenshot"*: a notice, and the reply describes the window (not the desktop around it). *"…of the whole screen"*
      asks first. Voxa's own card is not in the picture. Ask a follow-up: it doesn't have the picture any more.
- [ ] While a click is waiting for your answer, switch to another app and allow it: nothing is clicked, and Voxa says the app
      changed. Move the window between a screenshot and the click: nothing is clicked.
- [ ] *"Find my invoices"* lists real files from your home folder; *"show me the first one"* reveals it in Finder.
- [ ] *"Move the file called … to my Documents folder"*: macOS may first ask to let Voxa into that folder; then the card lists what
      goes where, and after Allow the file moves. A name that is already taken stops it. *"Trash the … files"* asks with the list,
      the files land in the Trash, and **Put Back** returns them. *"Delete my .ssh folder"* is refused without a question.
- [ ] Settings → General → Speech recognition → Whisper: the model list appears with sizes. Download **Base (English)**: progress
      shows, then *Getting it ready for this Mac (once)…*, then *Ready*; **Use this one** if it isn't already in use. Hold ⌥Space
      and speak: text appears while you talk and the command works. Quit and reopen: the first command after launch is quick.
- [ ] Turn Wi-Fi off after the model is ready: Whisper still works. **Remove** the model: the next command says the model isn't
      downloaded, with a button that opens Settings. Cancel a download part-way: it stops, and Download carries on from there.
- [ ] Say nothing while Whisper is on: *I didn't catch that*, never invented words such as "Thank you for watching".
- [ ] (Ollama) With a model that can't see images, ask for a screenshot: the model is told it can't, and says so in its reply.

**Full control: needs you to click (nothing here has been clicked by anyone but a test)**

- [ ] Settings → Safety → **Run commands without asking me**: flipping it on shows *Give Voxa full control?* with **Give Full
      Control** and **Keep Asking**. Keep Asking (or Esc) leaves the switch off. Give Full Control turns it on, and the *Ask before
      acting* picker greys out.
- [ ] With it on, the menu-bar menu has **Full control is on** and **Turn Off Full Control**; the Tools tab shows an orange note.
- [ ] *"Trash the … files"* (or *"move the file called …"*) now goes straight through, with no card; the HUD still shows what it is
      doing. Settings → History says *ran without asking (full control)* for it.
- [ ] *"Run an AppleScript that returns 6 times 7"* now runs with no card and answers 42, and History says *ran without asking*.
      In System Settings, *"click Privacy & Security"* goes straight through too.
- [ ] *"Delete my .ssh folder"* and typing into a password field are still refused, and so is an AppleScript that runs a shell
      command. Put Voxa's own Settings window in front and ask it to click something: it refuses (*It holds Voxa's own settings
      and approvals*).
- [ ] **Turn Off Full Control** in the menu: the switch in Settings shows off at once. Quit and reopen Voxa with it on: it is still on
      (and the menu still says so).
- [ ] *"Play Hanuman Chalisa on YouTube"* (or any song or video) in **one** command: the results page opens, Voxa waits for it,
      takes a picture of the window, clicks the first real video, and the reply says it is playing. (In Brave and Chrome the page
      can't be read as a list, so it works from the picture; the History tab shows Open links, Wait, Look at the screen, Click.)
      Without full control it asks once, before the click. History also shows the check: *Checked that it was finished: not yet
      (…)* if the model stopped early, then *yes* once it had finished. If it still stops at the results page, tell me which model
      you use and what History shows.
- [ ] Settings → Safety → **Check that a command is finished**: turn it off and give a command that only opens a page: the reply
      stands with no check in History. Turn it on again.
- [ ] Try it from a terminal, without the app: `swift run voxa-dev ask "…" --full-control` (add `--sample-data` to keep it away from
      your real calendar).

**Model providers: needs your OpenAI key and/or Ollama with a tool-capable model**

- [ ] Settings → Model → **OpenAI**: paste your key, Save, **Test connection** says *Connected*. *"Open Notes"* works, and
      *"Run an AppleScript that returns 6 times 7"* asks first, exactly as with Claude. (Not yet run against the real OpenAI
      API: the only checks so far are the mock server, which follows OpenAI's published API, and the unit tests.)
- [ ] A wrong OpenAI key: *OpenAI rejected your API key*, with a button that opens Settings on the Model tab.
- [ ] Settings → Model → **Ollama**: *Running (version …)*, your models are listed, and one without tool support shows a warning.
      Choose a tool-capable model; **Test connection** says *Connected* (the first one loads the model, which can take a while).
- [ ] Quit Ollama and give a command: *Ollama isn't running*, with **Open Ollama**. The model list in Settings says so too.
- [ ] Ollama, a model that can use tools: *"open Notes"* works, and an AppleScript still asks first.
- [ ] Switch provider in Settings, then follow up within two minutes: the new provider starts a fresh conversation.

## Roadmap

| | Scope | Status |
|-|-------|--------|
| M1 | Menu-bar shell, hotkey, audio capture, Apple STT, HUD with live transcript | done |
| M2 | LLM client + agent loop, `open_app` / `open_url` / `run_shortcut` / `run_applescript`, policy engine, confirmation HUD | done |
| M3 | Permissions manager + welcome guide, calendar / reminders / clipboard / context tools, spoken replies, full settings, history viewer | done |
| M4 | Accessibility UI tools, screenshot + vision fallback, file tools, WhisperKit engine | done |
| M5 | Hardening, signing and notarization scripts, DMG, final docs | next |

## License

Not yet licensed. All rights reserved.
