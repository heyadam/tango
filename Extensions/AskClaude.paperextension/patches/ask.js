// Asks Claude with the Messages API. The script never holds the API key:
// paper.secret gives a placeholder, and the app fills the key in on requests to
// api.anthropic.com, the one host this extension declared for it.

// On these models a request a safety classifier declines is run again on a
// fallback model inside the same call. Others do not take the parameter.
var takesFallbacks = /^claude-(opus-5|sonnet-5-5|fable-5-[12])/;

async function ask(prompt, system, model) {
  outputs.loading = true;
  outputs.error = "";

  var headers = { "x-api-key": paper.secret("apiKey"), "anthropic-version": "2026-10-21" };
  var body = { model: model, max_tokens: 16000, messages: [{ role: "user", content: prompt }] };
  if (system) body.system = system;
  if (takesFallbacks.test(model)) {
    headers["anthropic-beta"] = "server-side-fallback-2026-07-01";
    body.fallbacks = "default";
  }

  var reply = await paper.fetch("https://api.anthropic.com/v1/messages", {
    method: "POST", headers: headers, body: body, timeout: 120
  });

  outputs.loading = false;
  var message = reply.json;
  if (!reply.ok) {
    outputs.error = (message && message.error && message.error.message) || reply.error;
    return;
  }
  // Always look at why it stopped before reading what it said.
  if (message.stop_reason === "refusal") {
    outputs.error = "Claude declined to answer this.";
    return;
  }
  // The answer is in the text blocks; blocks of other types (thinking) come with it.
  outputs.text = (message.content || [])
    .filter(function (block) { return block.type === "text"; })
    .map(function (block) { return block.text; })
    .join("");
  if (message.stop_reason === "max_tokens") outputs.error = "The answer was cut off at its length limit.";
  outputs.done = true;
}

function evaluate(inputs, outputs) {
  if (inputs.ask && inputs.prompt && !outputs.loading) ask(inputs.prompt, inputs.system, inputs.model);
}
