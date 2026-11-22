// The tango assistant's link to Claude.
//
// The app starts this with Node and exchanges one JSON object per line:
//   app  -> here : {type:"start", systemPrompt, model?, effort?, claudePath?, apiKey?}
//                  {type:"effort", effort}   (null goes back to the model's default)
//                  {type:"user", text, images?: [{label, data, mediaType}]}
//                  {type:"tool_result", id, text, images?, isError?}
//                  {type:"interrupt"}
//   here -> app  : {type:"ready"}
//                  {type:"model", model}
//                  {type:"text", delta}
//                  {type:"thinking"}                  (the model began to think)
//                  {type:"tool_start", name, useId}   (the model began to write a call)
//                  {type:"tool_item", name, useId, item}   (one operation or step of it, written out)
//                  {type:"tool_call", id, name, input, useId?}   (useId: the call that was written)
//                  {type:"tool_abandoned", useId}     (a written call that never reached the app,
//                                                      such as one the SDK found malformed)
//                  {type:"done", costUSD?}
//                  {type:"error", message}
//
// The model has no tools of its own here: no files, no shell. Its only tools are the
// three below, and each one is answered by the app, which runs it on the open document.

import { createInterface } from "node:readline";
import { createSdkMcpServer, query, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");

// Tool calls waiting for the app's answer.
const waiting = new Map();
let nextCall = 1;

// Calls the model has written whose answer the app has not been asked for yet, so a call
// can be matched with the one the app watched being written.
const written = []; // {useId, name, text}

function claim(name, input) {
  const json = JSON.stringify(input);
  let at = written.findIndex((call) => call.name === name && sameJSON(call.text, json));
  if (at < 0) at = written.findIndex((call) => call.name === name);
  if (at < 0) return undefined;
  return written.splice(at, 1)[0].useId;
}

function sameJSON(text, json) {
  try {
    return JSON.stringify(JSON.parse(text)) === json;
  } catch {
    return false;
  }
}

function askApp(name, input) {
  const id = `call-${nextCall++}`;
  const useId = claim(name, input);
  return new Promise((resolve) => {
    waiting.set(id, resolve);
    send({ type: "tool_call", id, name, input, useId });
  });
}

function forward(name) {
  return async (input) => {
    const answer = await askApp(name, input);
    const content = [{ type: "text", text: answer.text ?? "" }];
    for (const image of answer.images ?? []) content.push({ type: "image", data: image, mimeType: "image/png" });
    return { content, isError: Boolean(answer.isError) };
  };
}

const paper = createSdkMcpServer({
  name: "paper",
  version: "1.0.0",
  tools: [
    tool(
      "get_document",
      "Read the open prototype as JSON with short ids: its tree of views with the ports each publishes, the patches and which view each is attached to or kept inside, the cables, what is selected and which view the person has stepped into. A shader view comes with its Metal code, its inputs and, when the code does not compile, the error.",
      {},
      forward("get_document"),
    ),
    tool(
      "edit_document",
      "Change the prototype with a batch of operations, applied in order as one undo step. See the system prompt for the operations. Returns the ids of what was created and any errors.",
      { operations: z.array(z.record(z.string(), z.any())).describe("Operations, each an object with an `op`.") },
      forward("edit_document"),
    ),
    tool(
      "view_prototype",
      "See the prototype as the Viewer shows it, shader views included. It is started fresh, optionally tapped once, then drawn after some seconds. Returns an image where one pixel is one point.",
      {
        tap: z.object({ x: z.number(), y: z.number() }).optional().describe("Where to tap, in screen points."),
        seconds: z.number().optional().describe("How long to let it run before drawing. Use about 1 after a tap."),
        screen: z.string().optional().describe("Start on this screen (its name or id) instead of the first."),
      },
      forward("view_prototype"),
    ),
    tool(
      "interact_prototype",
      "Use the prototype with several touches in a row and look at it along the way. It is started fresh, the steps run in order, and an image is returned for each `look` and one at the end.",
      {
        steps: z
          .array(z.record(z.string(), z.any()))
          .describe(
            'Each step is {do:"tap", at:{x,y}}, {do:"drag", from:{x,y}, to:{x,y}, seconds?} (a fast drag is a swipe), {do:"down", at:{x,y}} (a finger that stays down, so you can look while it is held), {do:"move", to:{x,y}, seconds?} and {do:"up"} for that finger (add finger:2 to any of the three for a second finger beside the first), {do:"wait", seconds}, {do:"type", text} (tap a text field first), {do:"press", key:"return"|"delete"}, {do:"pinch", at:{x,y}, scale, rotation?, pan?:{x,y}, seconds?} (two fingers 88 points apart around `at`, spread to `scale` times that, turned `rotation` degrees clockwise and carried `pan` points, then lifted; both must land on the view that listens), {do:"hover", at:{x,y}} or {do:"look"}. Points are screen points. A gesture patch counts from where its gesture began, about 10 points after the fingers set off, so it reports a little less than the fingers did.',
          ),
        screen: z.string().optional().describe("Start on this screen (its name or id) instead of the first."),
      },
      forward("interact_prototype"),
    ),
  ],
});

// What the person types, handed to the SDK as it arrives.
const pending = [];
let wake = null;
let closed = false;

async function* prompts() {
  while (!closed) {
    if (pending.length === 0) await new Promise((resolve) => (wake = resolve));
    while (pending.length > 0) {
      yield { type: "user", message: { role: "user", content: pending.shift() }, parent_tool_use_id: null };
    }
  }
}

let conversation = null;

// A tool call's input arrives as pieces of JSON while the model writes it, which for a big
// batch takes a minute. This follows the pieces and hands over each object of the
// call's list (`operations` or `steps`) the moment it is complete, so the app can say what
// is being planned before the call itself arrives.
class ItemScanner {
  constructor(onItem) {
    this.onItem = onItem;
    this.text = "";
    this.at = 0;
    this.depth = 0;
    this.inString = false;
    this.escaped = false;
    this.start = -1;
  }

  add(piece) {
    this.text += piece;
    for (; this.at < this.text.length; this.at++) {
      const c = this.text[this.at];
      if (this.inString) {
        if (this.escaped) this.escaped = false;
        else if (c === "\\") this.escaped = true;
        else if (c === '"') this.inString = false;
      } else if (c === '"') {
        this.inString = true;
      } else if (c === "{" || c === "[") {
        this.depth++;
        // The input is {"operations": [ {…}, … ]}: an item is an object two levels in.
        if (c === "{" && this.depth === 3) this.start = this.at;
      } else if (c === "}" || c === "]") {
        if (c === "}" && this.depth === 3 && this.start >= 0) {
          try {
            this.onItem(JSON.parse(this.text.slice(this.start, this.at + 1)));
          } catch {}
          this.start = -1;
        }
        this.depth--;
      }
    }
  }
}

const shortName = (name) => String(name ?? "").replace(/^mcp__paper__/, "");

async function run(start) {
  // Without an API key in its environment the SDK uses this Mac's Claude login. A key is
  // used only when the app sends one (the person chose it in Settings), never one that
  // happens to be in the environment.
  const env = { ...process.env };
  delete env.ANTHROPIC_API_KEY;
  if (start.apiKey) env.ANTHROPIC_API_KEY = start.apiKey;

  const options = {
    systemPrompt: start.systemPrompt,
    mcpServers: { paper },
    tools: [],
    allowedTools: ["mcp__paper__*"],
    permissionMode: "dontAsk",
    settingSources: [],
    includePartialMessages: true,
    maxTurns: 80,
    env,
  };
  if (start.model) options.model = start.model;
  if (start.effort) options.effort = start.effort;
  if (start.claudePath) options.pathToClaudeCodeExecutable = start.claudePath;

  conversation = query({ prompt: prompts(), options });
  let wroteText = false;
  // Tool calls being written, by their place in the message.
  const writing = new Map();
  for await (const message of conversation) {
    if (message.type === "system" && message.subtype === "init" && message.model) {
      send({ type: "model", model: message.model });
    } else if (message.type === "stream_event") {
      const event = message.event;
      if (event.type === "message_start") writing.clear();
      if (event.type === "content_block_start") {
        const block = event.content_block;
        if (block?.type === "thinking" || block?.type === "redacted_thinking") send({ type: "thinking" });
        if (block?.type === "tool_use") {
          const name = shortName(block.name);
          const useId = block.id;
          send({ type: "tool_start", name, useId });
          const call = { useId, name, text: "" };
          written.push(call);
          const scanner = new ItemScanner((item) => send({ type: "tool_item", name, useId, item }));
          writing.set(event.index, { call, scanner });
        }
      }
      if (event.type === "content_block_delta" && event.delta?.type === "input_json_delta") {
        const piece = event.delta.partial_json ?? "";
        const block = writing.get(event.index);
        if (block) {
          block.call.text += piece;
          block.scanner.add(piece);
        }
      }
      if (event.type === "content_block_stop") writing.delete(event.index);
      if (event.type === "content_block_start" && event.content_block?.type === "text" && wroteText) {
        send({ type: "text", delta: "\n\n" });
      }
      if (event.type === "content_block_delta" && event.delta?.type === "text_delta") {
        wroteText = true;
        send({ type: "text", delta: event.delta.text });
      }
    } else if (message.type === "user" && Array.isArray(message.message?.content)) {
      // Answers to calls. One the app was never asked about was refused on the way.
      for (const part of message.message.content) {
        if (part?.type !== "tool_result") continue;
        const at = written.findIndex((call) => call.useId === part.tool_use_id);
        if (at >= 0) {
          written.splice(at, 1);
          send({ type: "tool_abandoned", useId: part.tool_use_id });
        }
      }
    } else if (message.type === "result") {
      wroteText = false;
      written.length = 0;
      if (message.subtype === "success" && !message.is_error) {
        send({ type: "done", costUSD: message.total_cost_usd });
      } else {
        const detail = message.errors?.join("\n") || message.result || message.subtype;
        send({ type: "error", message: String(detail) });
        send({ type: "done" });
      }
    }
  }
}

const lines = createInterface({ input: process.stdin });
lines.on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  switch (message.type) {
    case "start":
      send({ type: "ready" });
      run(message).then(
        () => process.exit(0),
        (error) => {
          send({ type: "error", message: String(error?.message ?? error) });
          send({ type: "done" });
          process.exit(1);
        },
      );
      break;
    case "user": {
      // Pictures the person attached follow the text, each after a line saying what it is.
      const images = message.images ?? [];
      if (images.length === 0) {
        pending.push(message.text);
      } else {
        const content = [{ type: "text", text: message.text }];
        for (const image of images) {
          if (image.label) content.push({ type: "text", text: image.label });
          content.push({
            type: "image",
            source: { type: "base64", media_type: image.mediaType ?? "image/jpeg", data: image.data },
          });
        }
        pending.push(content);
      }
      wake?.();
      break;
    }
    case "effort":
      // Applies from the next message of the conversation in progress.
      conversation?.applyFlagSettings({ effortLevel: message.effort ?? null }).catch(() => {});
      break;
    case "tool_result":
      waiting.get(message.id)?.(message);
      waiting.delete(message.id);
      break;
    case "interrupt":
      // Answer anything the model is waiting on so the turn can end.
      for (const [id, resolve] of waiting) resolve({ id, text: "Stopped by the user.", isError: true });
      waiting.clear();
      conversation?.interrupt().catch(() => {});
      break;
  }
});
lines.on("close", () => {
  closed = true;
  wake?.();
  process.exit(0);
});
