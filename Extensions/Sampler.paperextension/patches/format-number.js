// A patch is a function from inputs to outputs. Its ports are declared in
// extension.json; here they are already in `inputs` and `outputs`.
function evaluate(inputs, outputs) {
  var decimals = Math.max(0, Math.min(10, Math.round(inputs.decimals)));
  var parts = Math.abs(inputs.value).toFixed(decimals).split(".");
  if (inputs.thousands) parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  var sign = inputs.value < 0 ? "-" : "";
  outputs.text = inputs.prefix + sign + parts.join(".") + inputs.suffix;
}
