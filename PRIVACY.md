# Simbi Privacy Policy

**Effective date:** August 18, 2026

Simbi is a macOS notetaking app made by Andrew Sangwoo Ye ("I", "me"). This
policy explains what data Simbi handles and where it goes. The short version:
**I run no servers, require no account, include no analytics, and never
receive your data.** Everything Simbi produces lives in files on your Mac,
and the only remote service your content is sent to is your own ChatGPT
account.

## Data I collect

None. Simbi has no backend, no user accounts, no telemetry, no crash
reporting, and no advertising or tracking of any kind. I have no way to see
your notes, recordings, transcripts, or anything else you do in the app.

## Data stored on your Mac

Everything Simbi creates is stored as plain files in the `~/Simbi` folder on
your computer:

- your notes (markdown files),
- audio recordings you make (microphone and, if you enable it, system audio),
- transcripts of those recordings,
- files you attach to notes and markdown conversions of them.

These files never leave your Mac except as described below. You can read,
copy, back up, or delete them at any time with the Finder; deleting a note's
folder deletes everything Simbi knows about that note.

## Recording

Simbi records audio only when you explicitly start a recording, and macOS
separately asks for your permission before Simbi can access the microphone or
capture system audio. Recordings are saved locally in the note's folder.

If you record a conversation, you are responsible for complying with the laws
that apply to you. Some jurisdictions require the consent of everyone being
recorded. See the [Terms of Use](TERMS.md).

## Services Simbi connects to

Simbi talks to a small, fixed set of services. In each case the connection is
made directly from your Mac; nothing passes through any server of mine.

### OpenAI (ChatGPT)

Simbi's intelligence features use your own ChatGPT account, through the
ChatGPT desktop app's bundled Codex tooling and your existing sign-in on your
Mac. When you use these features, content is sent to OpenAI:

- audio segments of your recordings, for transcription;
- note and transcript content, when features such as transcript cleanup, file
  conversion, summaries, or per-note chat run Codex threads over your note.

This data is sent under your OpenAI credentials and is governed by OpenAI's
own terms and privacy policy (<https://openai.com/policies/privacy-policy>),
including whatever data-retention and training settings your OpenAI account
has. If the ChatGPT app is not installed or you are signed out, Simbi keeps
working locally (recording and diarization continue; transcription segments
queue on your disk until a connection is available).

### GitHub (software updates)

Simbi checks for updates using the Sparkle framework by fetching a feed from
GitHub Pages and downloading updates from GitHub Releases. These requests
expose your IP address and the app version to GitHub, like any web request.
No identifier for you or your data is included. You can change or disable
update checking in Simbi's settings.

### Hugging Face (model downloads)

On first run, Simbi downloads the speech models it uses for voice activity
detection and speaker identification from Hugging Face. This is a one-time
download of public model files; it exposes your IP address to Hugging Face
and sends nothing about you or your content. The models then run entirely on
your Mac.

## What I never do

- I never sell, share, or monetize any data (I never have any).
- Simbi contains no third-party analytics or advertising SDKs.
- Simbi sends your content nowhere except OpenAI, at your direction, under
  your own account.

## Children

Simbi is not directed at children under 13.

## Your rights

Because I hold no data about you, requests to access or delete personal data
can be satisfied entirely on your own Mac: your data is in `~/Simbi`, and
deleting it removes it completely. For anything sent to OpenAI, use the
privacy controls of your OpenAI account. If you have questions about this
policy, contact me at <me@predict-woo.com>.

## Changes

If Simbi's data practices ever change, this policy will be updated and the
change will be noted in the release notes of the version that changes them.
