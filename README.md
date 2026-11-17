# Siri Flow Guard with Alfred Support

<img src="assets/icon.png" width="96" alt="Siri Flow Guard app icon">

> **This is a modified copy** of shivexe's [Siri Flow Guard](https://github.com/shivexe/siri-flow-guard). I added three things: it also catches Siri opened from Alfred, it treats Return as a Siri trigger whenever a Siri window is on screen, and it hides LanguageTool for Desktop along with Wispr Flow. I tested it on one Mac mini running macOS 27.0.1. It worked for me, but it may not work for you. I'm not a developer and wrote these changes with Claude's help, so read the code before you give it the permissions it needs.

On the macOS 27 Siri beta, opening a conversation or sending a message can bring Wispr Flow's Hub to the front, even when the Hub is closed. This guard stops that.

## What this copy changes

- **Alfred:** pressing Return in Alfred's bar while Alfred is open counts as a Siri trigger. Flow stays hidden for 1.5 seconds in that case (0.5 seconds for everything else), so Siri has time to finish looking at the screen.
- **Siri windows:** pressing Return counts as a Siri trigger whenever a Siri window is on screen, not only when Siri is the front app. On my Mac the Siri bubble never became the front app, so Return was ignored before.
- **LanguageTool for Desktop:** when the guard hides Flow, it also hides LanguageTool (`org.languagetool.desktop`) and restores it afterward, if it was visible before. LanguageTool started popping open instead of Flow once Flow was handled. This is hardcoded for that one app, so no other apps are covered.

If you don't use Alfred or LanguageTool, those parts do nothing.

## What causes it

*This section is from the original README.*

Siri asks `intelligencecontextd` for on-screen context. Flow keeps a `Status` utility window on screen even after its Hub is closed. In the failing sequence, the context service selected Flow, requested a background App Intents connection, and macOS sent the already-running Flow process an `aevt/rapp` reopen event. Flow's Electron activation handler then showed the Hub. A typed Siri message reproduced the issue without using Flow's dictation shortcut.

## What the guard does

The guard runs outside both apps. Before a mouse click in Siri or a Return keypress reaches Siri (or reaches Alfred while Alfred is open), it briefly hides Flow so its `Status` window is absent from the context snapshot. It forwards the original input unchanged. Flow is restored after a short interval, or before the next key, modifier, Dock, or Flow interaction. This lets Flow's dictation shortcut keep working in Siri.

Rapid changes to Siri's chat list sometimes make Accessibility hit testing fail. The guard also checks the window under the pointer, ignoring Flow's known `Status` overlay, so it can recognize those clicks. It leaves an already-open Hub or an intentionally hidden Flow alone.

The guard only sees windows on your current desktop. If a Hub is open on another desktop, it won't know.

## Install

The script builds a small local macOS app and installs a per-user LaunchAgent. The LaunchAgent starts at login and restarts the guard if it exits unexpectedly. It does not modify Siri or Wispr Flow.

Requirements: macOS with the dedicated Siri beta app (Siri AI), Wispr Flow, and Xcode Command Line Tools (`xcode-select --install` if needed). Alfred and LanguageTool for Desktop are optional.

```sh
git clone https://github.com/notyouravgtyrone/siri-flow-guard.git
cd siri-flow-guard
./guard.sh build
```

In **System Settings → Privacy & Security**, add `Siri Flow Guard.app` from this cloned folder to all three of these lists, and turn on each switch:

1. **Accessibility**
2. **Input Monitoring**
3. **Screen & System Audio Recording**

**The Accessibility list may have a different name.** On macOS 27.0.1 on my Mac there was no "Accessibility" entry. The same list was called **Device Control and Data Access**. Once I turned that one on, the guard's log reported Accessibility as granted. If you can't find Accessibility, use Device Control and Data Access instead.

macOS treats this login service separately from Terminal, so Terminal's existing permissions don't cover it. The guard uses Screen Recording access to read window names; it does not save screenshots.

Then run:

```sh
./guard.sh start
./guard.sh status
```

`start` enables startup at login and keeps one guard instance running. `status` reports the guard process, event tap, and Flow window state.

### Stopping it

```sh
./guard.sh stop
```

This shuts down the guard, restores any temporary hide, and disables startup at login.

> **Warning: never turn the guard's permissions off while it is running.** On my Mac, doing that froze the keyboard and mouse. Always run `./guard.sh stop` first, then change the permissions. If your input freezes, wait about 30 seconds. If it doesn't come back, hold the power button to force a restart, then run `./guard.sh stop` once you're back in.

### Rebuilding

If you rebuild or move the app, macOS treats it as a new app. Remove it and add it again in **all three** permission lists, with the guard stopped. The diagnostic log is `guard.log`. Generated files and logs stay local and are excluded from Git.

## Checking that it works

The permission lines in `./guard.sh status` can read `false` even when the guard is working. That output comes from Terminal, not the app. `./guard.sh observe` and `./guard.sh run` from Terminal fail for the same reason. Use `start`, then look at the log:

```sh
tail -20 guard.log
```

- `started mode=--run` with no `ERROR` after it means it started with its permissions.
- `pre-hidden` followed by `restored` means it hid Flow and put it back. That is the guard working.
- `skipped: Hub=true` means a Flow Hub window is already open. The guard leaves an open Hub alone by design. Close it, check your other desktops too, and try again.
- `return ignored: front=other` is normal. It means you pressed Return in an app the guard doesn't care about.

If a different app pops open instead of Flow (LanguageTool did for me), the guard doesn't cover it unless the code is changed.

## Limits

- The Alfred fix covers pressing Return in Alfred's bar. I did not test opening Siri with only a hotkey, with "Hey Siri," or from other launchers such as Spotlight or Raycast, so those may not be covered.
- Any Return pressed in Alfred or while a Siri window is open briefly hides Flow's dictation pill. It comes back on its own.
- This is a workaround for the verified Siri and Flow interaction. If hiding Flow takes more than 60 ms, the guard passes the input and restores Flow. Other Siri entry paths and future beta versions may need changes. The underlying background reopen behavior needs an Apple-level fix.

## What was tested

The original author checked rapid Siri chat switching, typed Return, Flow dictation in and outside Siri, deliberate Dock opening, Flow restart, and guard stop/restart on macOS 27.0 (26A428) with Flow 1.6.897.

I tested my changes (Alfred, Siri bubble and chat window, LanguageTool) on a Mac mini running macOS 27.0.1. I did not record the Flow or Alfred versions I used.

The guard observes event types and window metadata; it does not store typed text, audio, or conversation content. My additions only check whether Siri's or Alfred's windows are on screen.

## Uninstall

```sh
./guard.sh stop
```

Then delete the `siri-flow-guard` folder and remove **Siri Flow Guard** from the three permission lists.

## Credits

The original project and most of this README are by [shivexe](https://github.com/shivexe/siri-flow-guard). It has no license file. The Alfred, Siri window, and LanguageTool changes are mine, written with Claude's help.
