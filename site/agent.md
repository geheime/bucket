# Install Bucket on this Mac

You are an AI coding agent. The person you are working with wants Bucket installed. Bucket is an open source
(MIT) menu bar app for macOS: they press Cmd+Shift+4, screenshots collect in a bucket, and one Cmd+V in the terminal
pastes the paths of all of them, so you receive every screenshot as an image. Source and full docs:
https://github.com/geheime/bucket

Install it with Homebrew, then guide the person through the two steps only they can do. Work step by step, show each
command before you run it, and tell them what happened after each step.

## Rules

- Do not use `sudo`.
- Do not change macOS settings, `defaults`, or privacy databases. Permissions and shortcuts are the person's to set;
  you only tell them where.
- Do not remove quarantine flags (`xattr`). The Homebrew install compiles Bucket on this Mac, so it does not need it.
- Only run the Bucket commands in this guide. Other Bucket subcommands are development tools.

## 1. Check the requirements

```sh
sw_vers -productVersion     # needs 14.0 or later
command -v brew             # needs Homebrew
xcode-select -p             # needs Xcode or the Command Line Tools (Swift)
```

- macOS older than 14: stop and tell the person Bucket needs macOS 14 (Sonoma) or later.
- No Homebrew: stop and point them to https://brew.sh, or to the zip in
  https://github.com/geheime/bucket/releases/latest (the README explains its first launch).
- No `xcode-select` path: ask them to run `xcode-select --install` and accept the dialog, then continue.

## 2. Install

```sh
brew install geheime/tap/bucket
```

This builds Bucket from source. It can take a few minutes; say so before you start.

## 3. Put the app where macOS can open it

```sh
ls -ld ~/Applications/Bucket.app 2>/dev/null   # check first
mkdir -p ~/Applications && ln -sfn "$(brew --prefix bucket)/Bucket.app" ~/Applications/Bucket.app
```

If `~/Applications/Bucket.app` already exists and is a real folder, not a link (an earlier install from the zip),
`ln` would put the link inside it. Ask the person to quit Bucket and move that copy to the Trash, then run the line.

## 4. Add the Claude Code skill (if you are Claude Code)

The skill lets you find the person's old screenshots by the text in them. Ask before installing it:

```sh
mkdir -p ~/.claude/skills
cp -R "$(brew --prefix bucket)/share/bucket/integrations/claude-code/bucket-search" ~/.claude/skills/
```

Suggest a narrow permission, so you can search and nothing else:
`Bash(~/Applications/Bucket.app/Contents/MacOS/Bucket search:*)`

## 5. Open Bucket

```sh
open ~/Applications/Bucket.app
```

A bucket icon appears in the menu bar. There is no Dock icon.

## 6. Guide the person through the two steps only they can do

Tell them, in your own words:

1. **Turn off the macOS Cmd+Shift+4 shortcut.** System Settings > Keyboard > Keyboard Shortcuts... > Screenshots >
   untick "Save picture of selected area as a file". (Or keep it and pick another shortcut in Bucket's menu, under
   Capture shortcut.)
2. **Allow Screen Recording.** Press Cmd+Shift+4 and select any area. macOS asks for Screen Recording: turn Bucket on
   in System Settings > Privacy & Security > Screen Recording, come back and capture again. While the permission is
   missing, the menu bar icon is struck through.

## 7. Test it together

Ask them to capture two areas with Cmd+Shift+4, then click into this terminal and press Cmd+V. You should receive
both screenshots as images. Describe what you see in them so they know it works. The bucket empties itself after
the paste.

## 8. Tell them what to know

- Screenshots live in `~/Bucket`, with the text read from them (on this Mac, with Apple Vision) stored in the clear.
  Nothing is deleted automatically. FileVault is the best protection for it.
- Bucket makes no network connections and has no accounts or analytics.
- Opt+Shift+V puts the last batch back on the clipboard.
- Every `brew upgrade` rebuilds the app, and macOS may ask for Screen Recording again.
