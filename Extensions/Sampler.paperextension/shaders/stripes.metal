// A shader view from an extension is copied into the document when it is added:
// from then on it is the document's own, and this code can be changed there.
struct Inputs {
    float4 first = float4(0.0, 0.48, 1.0, 1.0);
    float4 second = float4(0.35, 0.78, 0.98, 1.0);
    float width = 12;
};

float4 shader(Frame frame, Inputs in) {
    float along = (frame.position.x + frame.position.y) / max(in.width * 2.0, 1.0);
    return mix(in.first, in.second, step(0.5, fract(along)));
}
