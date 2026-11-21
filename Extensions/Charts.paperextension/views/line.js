function numbers(values) {
  return (Array.isArray(values) ? values : []).map(Number).filter(isFinite);
}

function draw(canvas, inputs, size) {
  var values = numbers(inputs.values);
  if (values.length < 2) return;
  var low = Math.min.apply(null, values), high = Math.max.apply(null, values);
  var span = high - low || 1;
  var inset = Math.max(inputs.lineWidth, inputs.dots ? inputs.lineWidth * 2 : 0) / 2 + 1;
  var width = size.width - inset * 2, height = size.height - inset * 2;
  function x(index) { return inset + width * index / (values.length - 1); }
  function y(value) { return inset + height * (1 - (value - low) / span); }

  function trace() {
    canvas.moveTo(x(0), y(values[0]));
    for (var i = 1; i < values.length; i++) {
      if (inputs.smooth) {
        var middle = (x(i - 1) + x(i)) / 2;
        canvas.bezierCurveTo(middle, y(values[i - 1]), middle, y(values[i]), x(i), y(values[i]));
      } else {
        canvas.lineTo(x(i), y(values[i]));
      }
    }
  }

  if (inputs.fill) {
    // From the line's color at the top to nothing at the bottom.
    var fade = canvas.createLinearGradient(0, inset, 0, size.height);
    fade.addColorStop(0, inputs.color.hex.slice(0, 7) + "55");
    fade.addColorStop(1, inputs.color.hex.slice(0, 7) + "00");
    canvas.fillStyle = fade;
    canvas.beginPath();
    trace();
    canvas.lineTo(x(values.length - 1), size.height);
    canvas.lineTo(x(0), size.height);
    canvas.closePath();
    canvas.fill();
  }

  canvas.strokeStyle = inputs.color;
  canvas.lineWidth = Math.max(0.5, inputs.lineWidth);
  canvas.lineJoin = "round";
  canvas.lineCap = "round";
  canvas.beginPath();
  trace();
  canvas.stroke();

  if (inputs.dots) {
    canvas.fillStyle = inputs.color;
    for (var i = 0; i < values.length; i++) {
      canvas.beginPath();
      canvas.arc(x(i), y(values[i]), inputs.lineWidth, 0, Math.PI * 2);
      canvas.fill();
    }
  }
}
