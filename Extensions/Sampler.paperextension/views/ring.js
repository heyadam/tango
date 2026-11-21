// A view is drawn by a function. `canvas` works like an HTML canvas; `size` is the
// view's size in points. It is called again when an input or the size changes.
function draw(canvas, inputs, size) {
  var progress = Math.max(0, Math.min(1, inputs.progress));
  var thickness = Math.max(1, inputs.thickness);
  var radius = Math.max(0, Math.min(size.width, size.height) / 2 - thickness / 2);
  var x = size.width / 2, y = size.height / 2;
  var top = -Math.PI / 2;

  canvas.lineWidth = thickness;
  canvas.strokeStyle = inputs.track;
  canvas.beginPath();
  canvas.arc(x, y, radius, 0, Math.PI * 2);
  canvas.stroke();

  if (progress > 0) {
    canvas.strokeStyle = inputs.color;
    canvas.lineCap = "round";
    canvas.beginPath();
    canvas.arc(x, y, radius, top, top + Math.PI * 2 * progress);
    canvas.stroke();
  }

  if (inputs.label) {
    canvas.fillStyle = inputs.color;
    canvas.font = "bold " + Math.round(radius * 0.5) + "px sans-serif";
    canvas.textAlign = "center";
    canvas.textBaseline = "middle";
    canvas.fillText(Math.round(progress * 100) + "%", x, y);
  }
}
