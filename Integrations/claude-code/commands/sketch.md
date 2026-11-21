---
description: Build a screen from this codebase in tango, so it can be played with there.
argument-hint: <file or view to sketch>
---

The person wants to sketch `$ARGUMENTS` in tango, a macOS prototyping app, and play with it there. The code stays the source of truth: you build a faithful copy from it, and later carry their changes back with `/tango:apply`.

If `$ARGUMENTS` is empty, ask which screen or view to sketch.

1. Call the tango tool `get_reference` and read it all, above all the section "Sketching from code". It says how the code's structure, tokens, state and motion map onto views and patches. Follow it.
2. Read the code for the screen and everything it uses: subviews, theme and token files, the data it shows.
3. Call `get_document`. If the open document already has views in it, stop and ask the person to make a new one in tango (File > New), then continue.
4. Build the screen with `edit_document`, writing `source` (file, line, what it is) on every view and patch.
5. If you can get a picture of the real screen (a simulator screenshot, a preview, a snapshot test), check your work with `compare_prototype` and fix what differs. Otherwise look at it with `view_prototype`, and try each interaction with `interact_prototype`.
6. Call `mark_baseline` with `source` naming the screen.
7. Tell the person, in a few plain sentences, what is there to play with and what you could only approximate.

If the tools are missing, tango is not running or its agent server is off: ask the person to open the app and check Settings > Agents.
