# Dodoma

Dodoma is a macOS menu-bar utility that fixes text typed with the wrong keyboard
layout. Typing Arabic while the US layout is active (or the reverse) produces
mojibake such as `hgsghl` instead of `السلام`; Dodoma watches what you type,
detects when a word only makes sense under the other layout, and rewrites it in
place. It runs as a background agent with no dock icon, does no networking, and
keeps everything it observes on the machine.

Current state: M0 scaffolding — bundle, code signing and the permissions shell.
Detection and rewriting land in later milestones.

## Prerequisites

- macOS 14 or newer
- Xcode Command Line Tools with Swift 6 (`xcode-select --install`)
- No Xcode project is used; everything builds from `Package.swift` via `make`.

## One-time setup: a stable code-signing identity

```
scripts/make-cert.sh
```

Dodoma needs Accessibility and Input Monitoring permissions. macOS ties those
grants to the app's code signature. An ad-hoc signature (`codesign --sign -`)
changes on every rebuild, so macOS treats each build as a new app and drops the
grants, forcing re-approval after every `make install`.

`scripts/make-cert.sh` creates a self-signed code-signing certificate named
`Dodoma Dev` in the login keychain and trusts it for code signing. The build
then signs with a stable identity and the grants persist. The script asks for
the login keychain password (to set the key partition list) and may raise a GUI
trust prompt. It is idempotent; re-running it when the identity exists is a
no-op.

Building without the certificate still works — `make sign` falls back to ad-hoc
signing and prints a warning.

## Build and install

```
make build      # swift build -c release
make bundle     # assemble build/Dodoma.app
make sign       # sign the bundle
make install    # build + bundle + sign, install to /Applications, launch
make run        # build + bundle + sign, launch from build/ without installing
make test       # swift test
make logs       # stream os_log output for subsystem com.ali.dodoma
make clean      # remove .build and build
```

## Granting permissions

On first launch Dodoma requests both permissions and shows its state in the
menu-bar menu:

- `Needs Accessibility permission` — Dodoma cannot read or replace text yet.
- `Needs Input Monitoring permission` — Dodoma cannot observe keystrokes yet.
- `Active` — both grants are in place.

To grant them:

1. Open the Dodoma menu-bar item.
2. Choose **Open Accessibility Settings…**, then enable Dodoma under
   Privacy & Security → Accessibility.
3. Choose **Open Input Monitoring Settings…**, then enable Dodoma under
   Privacy & Security → Input Monitoring.

The status line refreshes every two seconds, so it flips to `Active` without a
restart.

## Removal

```
scripts/uninstall.sh   # quit, delete /Applications/Dodoma.app, reset grants
scripts/reset-tcc.sh   # reset the two privacy grants only
```
