# Ask Claude

A patch that sends a prompt to Claude and gives back the answer.

1. Install the extension and enter your Claude API key under **Keys**.
2. Add an **Ask Claude** patch. Cable text into **Prompt** and a pulse into **Ask**.
3. **Text** holds the answer when **Done** fires. **Loading** is on while it waits.

The key is kept in your keychain. This extension's code never sees it: the app adds it
to requests bound for `api.anthropic.com` and nowhere else.

**Model** is `claude-opus-5-5` unless you change it. Each request is billed to your key.
