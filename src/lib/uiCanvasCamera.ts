// Camera math for the design canvas. The canvas renders its content layer
// under `translate(x, y) scale(zoom)` with origin top-left; these helpers are
// the pure half of that — pan, cursor-anchored zoom, zoom-to-fit, and wheel
// normalization. The camera is view state only: it never enters the UISpec,
// never crosses the wire, and resets to a fit on mount.
//
// Coordinate spaces: `Camera.x/y` is the content layer's translation in
// viewport px; a world (frame-layout) point p maps to viewport space as
// `p * zoom + (x, y)`.

export type Camera = { x: number; y: number; zoom: number };

export const MIN_ZOOM = 0.1;
export const MAX_ZOOM = 4;
// Fit never blows small content past 100% — a single small screen should
// render at its natural size, not stretched to fill the panel.
export const FIT_MAX_ZOOM = 1;

export function clampZoom(zoom: number): number {
  if (!Number.isFinite(zoom)) return 1;
  return Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom));
}

export function panBy(camera: Camera, dx: number, dy: number): Camera {
  return { ...camera, x: camera.x + dx, y: camera.y + dy };
}

// Zoom keeping the world point under `point` (viewport px) fixed on screen:
// world = (point - t) / zoom, then t' = point - world * zoom'.
export function zoomAtPoint(
  camera: Camera,
  point: { x: number; y: number },
  nextZoom: number,
): Camera {
  const zoom = clampZoom(nextZoom);
  const scale = zoom / camera.zoom;
  return {
    x: point.x - (point.x - camera.x) * scale,
    y: point.y - (point.y - camera.y) * scale,
    zoom,
  };
}

// Fit content (layout px) into the viewport, centered. Capped at FIT_MAX_ZOOM
// and floored at MIN_ZOOM — huge specs may still overflow at the floor, which
// is what interactive pan is for.
export function fitCamera(
  content: { w: number; h: number },
  viewport: { w: number; h: number },
): Camera {
  if (content.w <= 0 || content.h <= 0 || viewport.w <= 0 || viewport.h <= 0) {
    return { x: 0, y: 0, zoom: 1 };
  }
  const zoom = Math.max(
    MIN_ZOOM,
    Math.min(FIT_MAX_ZOOM, viewport.w / content.w, viewport.h / content.h),
  );
  return {
    x: (viewport.w - content.w * zoom) / 2,
    y: (viewport.h - content.h * zoom) / 2,
    zoom,
  };
}

// WheelEvent deltas arrive in px, lines, or pages depending on device and
// platform (deltaMode 0/1/2). Normalize to px so pan speed and zoom feel are
// consistent.
const LINE_PX = 16;
const PAGE_PX = 800;

export function normalizeWheelDelta(
  dx: number,
  dy: number,
  deltaMode: number,
): { dx: number; dy: number } {
  const unit = deltaMode === 1 ? LINE_PX : deltaMode === 2 ? PAGE_PX : 1;
  return { dx: dx * unit, dy: dy * unit };
}

// Multiplicative zoom factor for a ctrl/meta wheel tick. The exponential
// curve makes pinch feel linear; the clamp keeps a single jumpy event (e.g.
// a discrete mouse-wheel notch reporting ±100+) from teleporting the zoom.
export function wheelZoomFactor(normalizedDeltaY: number): number {
  const clamped = Math.min(80, Math.max(-80, normalizedDeltaY));
  return Math.exp(-clamped * 0.01);
}
