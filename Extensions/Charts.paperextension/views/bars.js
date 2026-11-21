function draw(canvas, inputs, size) {
  var values = (Array.isArray(inputs.values) ? inputs.values : []).map(Number).filter(isFinite);
  if (values.length === 0) return;
  var high = Math.max.apply(null, values.concat([0])) || 1;
  var gap = Math.max(0, inputs.gap);
  var width = (size.width - gap * (values.length - 1)) / values.length;
  if (width <= 0) return;
  var picked = Math.round(inputs.highlight);

  for (var i = 0; i < values.length; i++) {
    var height = Math.max(0, values[i]) / high * size.height;
    canvas.fillStyle = i === picked ? inputs.highlightColor : inputs.color;
    canvas.beginPath();
    canvas.roundRect(i * (width + gap), size.height - height, width, height, Math.min(inputs.radius, width / 2));
    canvas.fill();
  }
}
