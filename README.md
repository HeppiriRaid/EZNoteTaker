# EZNoteTaker 🏛️

An iPhone app for an **architecture history walking-tour class**. It records the professor,
transcribes the lecture live on the phone, lets you snap photos of each building without
leaving the recording screen, and then **automatically** turns each class into:

- **Summary**: overview, sections, key takeaways, key terms and practice exam questions
- **Buildings**: every building discussed, with **architect**, **year built**, style, location,
  why it matters, key facts, stories and trivia, and what the professor emphasized. Your
  photos are placed on the matching building automatically.
- **Cheat Sheet**: all buildings from all classes stacked by day (Day 1, Day 2, …), plus a
  **Timeline** view for memorizing years and a **Map** of everywhere you walked. Export it
  to **Google Docs** (with photos) or as a printable PDF.
- **Study**: flashcards (see the photo, recall name, architect and year; weakest first) and a
  multiple-choice **Exam Quiz** like the final.

Study notes are written by **Claude Opus 5.5 on your Claude subscription**, through Claude
Code, with no per-request API billing and nothing to copy or paste. Right after class, a free
on-device draft from Apple Intelligence appears first; Claude's verified version replaces it
when it's ready.

## How it works

```
 iPhone (record, transcribe on device, take photos)
    │  Finish class
    ├──▶ instant draft with Apple Intelligence (on device, free)
    └──▶ relay ──▶ Claude Code runs Claude Opus 5.5 on your subscription
                     │
 iPhone ◀── imports the results automatically: summary, buildings, photo placement
```

**Recording features**
- Long-form, on-device transcription with Apple's iOS 26 `SpeechAnalyzer`, built for lectures.
  It falls back to `SFSpeechRecognizer` when needed.
- The audio is saved, so you can tap any timestamp in the transcript to re-listen
  (0.75×–2× speed).
- Inline camera that never stops the recording: pinch or tap 0.5×/1×/2×/5× to zoom, tap to focus.
- Every photo marks a stop in the transcript, with GPS and what the professor was saying at that
  moment. After Claude's pass, each photo sits on its building's cheat-sheet card.
- **Now discussing…** banner: Apple Intelligence guesses the current building every ~40 s.
  Photos get tagged with that guess.
- **Lock-screen console** (Live Activity, also in the Dynamic Island): REC/PAUSED, live timer,
  photo count, last photo, and the building being discussed, with **Pause/Resume** that works without
  unlocking and **Photo**, which opens the camera after Face ID.
- Keeps recording with the screen locked, pauses for phone calls and resumes afterward,
  and saves continuously, so a crash never loses a class.
- Misheard names (for example "Lou Corbusier") are fixed in the transcript automatically.

## Requirements

- iPhone with **iOS 26**. Apple Intelligence (iPhone 15 Pro or newer) is needed only for the
  instant draft and the live "Now discussing" banner; everything else works without it.
- To install: a Mac with **Xcode 26** (free Apple ID), **or** a paid Apple Developer account for
  cloud builds to TestFlight (see below).
- A **Claude Pro or Max** subscription for the Opus 5.5 study notes.

## 1. Install the app on your iPhone

Apple only lets apps outside the App Store onto an iPhone through Xcode or TestFlight.
Pick one of these:

| | **A. Xcode (free)** | **B. TestFlight (no Mac needed after setup)** |
|---|---|---|
| Needs | A Mac with Xcode 26 and a free Apple ID | Apple Developer Program ($99/year) |
| Install | Cable or Wi-Fi from Xcode | TestFlight app on the iPhone |
| Expires | Re-install every **7 days** (free accounts) | Each build lasts 90 days; new builds with one tap |

### A. Xcode (free Apple ID)

1. Install **Xcode 26** from the Mac App Store and clone or download this repository.
2. Open `EZNoteTaker.xcodeproj`. In **Signing & Capabilities**, set **Team** to your Apple ID for
   **both** targets: **EZNoteTaker** and **EZNoteTakerWidgetsExtension** (the lock-screen console).
   If the bundle identifier is taken, don't edit it in the Signing tab; instead select the blue
   project icon › **Build Settings**, search for `APP_BUNDLE_ID`, and change it there (e.g.
   `com.yourname.EZNoteTaker`). Both targets follow it.
3. On the iPhone, turn on **Settings › Privacy & Security › Developer Mode** (it restarts).
4. Connect the iPhone, select it as the run destination at the top of Xcode and press **Run** (⌘R).
5. The first time, trust the developer on the phone: **Settings › General › VPN & Device
   Management** › your Apple ID › Trust.

With a free Apple ID the app stops opening after 7 days. Either re-run step 4, or set up the
automatic refresh below. Your data stays on the phone either way.

#### Automatic 7-day refresh (free)

Your Mac can rebuild and reinstall the app every night over Wi-Fi, using Xcode's own tools and
your free Apple ID, so it never expires.

1. Do the Xcode install above once, with your Apple ID selected as the Team.
2. In Xcode › **Window › Devices and Simulators**, select your iPhone and tick
   **Connect via network**. The phone can then be updated without the cable while it's on the
   same Wi-Fi as the Mac.
3. In Finder, open `tools/auto-refresh/` in this project and double-click
   **`install-auto-refresh.command`**. Type your iPhone's name when asked. It does a first refresh
   right away. If macOS asks whether `codesign` may use your keychain, enter your Mac password
   and choose **Always Allow**.

From then on it runs every night at 3:17 AM, or when the Mac next wakes up. It needs the Mac
powered on (asleep is fine) and the iPhone on the same Wi-Fi. A failed night is retried the next
night, and the Mac shows a notification only if the app is getting close to expiring.
Log: `~/.eznotetaker/refresh.log`.

### B. TestFlight (built in the cloud, installed from the TestFlight app)

This repository includes a GitHub Action ([`.github/workflows/testflight.yml`](.github/workflows/testflight.yml))
that builds the app on GitHub's Macs and uploads it to TestFlight.

1. Join the [Apple Developer Program](https://developer.apple.com/programs/).
2. In [App Store Connect](https://appstoreconnect.apple.com) › Apps › **+ New App**: platform iOS,
   name "EZNoteTaker" (or any free name), bundle ID `com.heppiriraid.EZNoteTaker` (register it under
   Certificates, Identifiers & Profiles › Identifiers first if it's not listed).
3. App Store Connect › Users and Access › Integrations › **App Store Connect API** › generate a key
   with the **App Manager** role. Download the `.p8` file and note the Key ID and Issuer ID.
4. In this GitHub repository › Settings › Secrets and variables › Actions, add:
   `APPLE_TEAM_ID` (Membership details page), `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_PRIVATE_KEY`
   (the full text of the `.p8` file). If you used a different bundle ID, add it as the variable `BUNDLE_ID`.
5. GitHub › Actions › **TestFlight** › *Run workflow*. When it finishes and Apple has processed the
   build (5–30 min), open App Store Connect › your app › TestFlight, add yourself as an internal
   tester, and install it on the iPhone with the **TestFlight** app.

Run the workflow again (or push a tag like `v1.1`) whenever you want an update.

### Then

In the app's **Settings** tab, enter your course name, the city and any architect or building
names the professor uses a lot.

## 2. Connect Claude (one-time, pick one)

### Option A: Cloud (GitHub), no computer needs to stay on

A GitHub Action in your own private repository runs Claude Code with your subscription.

1. Create a **private** GitHub repository, e.g. `eznotetaker-relay`, with a README.
2. On any computer with [Claude Code](https://claude.com/claude-code), run `claude setup-token`
   and sign in with your Claude subscription. In the repo, open **Settings › Secrets and
   variables › Actions** and add a secret named **`CLAUDE_CODE_OAUTH_TOKEN`** with that token.
3. Create a [fine-grained GitHub token](https://github.com/settings/personal-access-tokens/new)
   with access to **only that repository** and **Contents** and **Workflows** set to *Read and write*.
4. In the app: **Settings › Claude Opus 5.5 relay › Cloud (GitHub)**. Enter `owner/repo` and
   the token, then tap **Connect**. The app installs the workflow
   ([`EZNoteTaker/Relay/eznotetaker-workflow.yml`](EZNoteTaker/Relay/eznotetaker-workflow.yml)) for you.

### Option B: your Mac

1. In the app: **Settings › Claude Opus 5.5 relay › My Mac › Choose Folder**, then create or pick
   a folder in **iCloud Drive** (e.g. `EZNoteTaker`). The app copies the Mac installer into it.
2. On your Mac, open that folder in Finder and double-click **`install-relay.command`**.
   It installs Claude Code if needed, asks you to sign in with your Claude subscription, and
   installs a small background helper (`~/Library/LaunchAgents/com.eznotetaker.relay.plist`).
3. Keep the Mac on and signed in to iCloud. Log: `~/.eznotetaker/relay.log`.

If macOS blocks the helper from reading iCloud Drive (the log says "Operation not
permitted"), either give `/bin/bash` Full Disk Access, or run
`bash ~/.eznotetaker/ez-relay.sh --watch` in a Terminal window.

> **About terms of service:** the app never sees or uses your Claude login. Claude runs inside
> Anthropic's own Claude Code (on your Mac, or in your GitHub Action through the official
> `claude setup-token` flow) on your own lecture data. Usage counts toward your plan's normal
> limits. The app deliberately does **not** pull your subscription's login token into a
> third-party app; Anthropic's terms don't allow that and it can get accounts suspended.

## Using it in class

1. Tap **Record Class** when the tour starts.
2. Walk and listen. At each building, take a few photos with the big shutter button. The
   recording keeps running, and the photos mark the stop.
3. Tap **Finish**. The draft appears within a minute or two. Claude's version arrives a few
   minutes later and replaces it, and the app shows a banner when it's done.
4. Before the final, use **Cheat Sheet** and **Study**.

### Export the cheat sheet to Google Docs

**Cheat Sheet › Export (↑) › Google Docs**. In the share sheet, pick **Google Docs** (or **Drive**)
and it opens as an editable Google Doc with your photos, a heading per class day and per
building, and every architect, year, fact and story. The file is a standard `.docx`, so Word and
Pages open it too. **PDF for printing** is in the same menu.

Everything is editable: fix a year or architect, star buildings, add your own notes, or move a
photo to a different building (tap the photo › *Choose building*). Re-running Claude keeps your
notes, stars and manual photo choices.

## Project layout

```
EZNoteTaker/
  App/            App entry, tab bar, theme and shared UI pieces
  Models/         SwiftData models (Lecture, Building, LecturePhoto…) and the analysis importer
  Services/       Audio capture, transcription, camera, on-device AI, Claude relays
  Views/          Classes list, live recording, class detail, cheat sheet, study, settings
  Relay/          Mac relay script + installer, GitHub Action (bundled into the app)
Shared/           Live Activity model + Pause/Resume intent (app and widget extension)
EZNoteTakerWidgets/  Lock-screen / Dynamic Island recording console
tools/auto-refresh/  Free nightly rebuild + reinstall so the 7-day signature never expires
```
