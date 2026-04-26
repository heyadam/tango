'use client';

// Brief scan-shader effect that plays over an image when something is
// transmitted to the terminal. Subscribes to transmitBus; while idle,
// renders nothing (no WebGL context) so it has zero ongoing cost.
//
// This is the only file allowed to import three / @react-three/fiber.
// Both touch `window`-shaped APIs and would explode under SSR if imported
// elsewhere — page.tsx pulls this in via `dynamic(..., { ssr: false })`.

import { useEffect, useMemo, useRef, useState } from 'react';
import { Canvas, useFrame } from '@react-three/fiber';
import * as THREE from 'three';
import { transmitBus, type TransmitEvent } from '@/lib/transmitBus';

const FADE_IN_MS = 150;
const SCAN_MS = 1050;
const FADE_OUT_MS = 300;
const TOTAL_MS = FADE_IN_MS + SCAN_MS + FADE_OUT_MS;

type ActiveEvent = TransmitEvent & { id: number };

export default function TransmitOverlay() {
  const [event, setEvent] = useState<ActiveEvent | null>(null);
  const idRef = useRef(0);

  useEffect(() => {
    return transmitBus.subscribe((e) => {
      idRef.current += 1;
      setEvent({ ...e, id: idRef.current });
    });
  }, []);

  useEffect(() => {
    if (!event) return;
    const t = window.setTimeout(() => {
      setEvent((cur) => (cur && cur.id === event.id ? null : cur));
    }, TOTAL_MS);
    return () => window.clearTimeout(t);
  }, [event]);

  if (!event) return null;

  return (
    <div
      className="pointer-events-none fixed inset-0 z-[99998] flex items-center justify-center bg-background/40 backdrop-blur-sm"
      aria-hidden="true"
    >
      <div className="flex flex-col items-center gap-2">
        <ScanCard key={event.id} src={event.src} />
        {event.label ? (
          <div className="font-mono text-[11px] text-muted-foreground">
            {event.label} → terminal
          </div>
        ) : null}
      </div>
    </div>
  );
}

function ScanCard({ src }: { src: string }) {
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  const [texture, setTexture] = useState<THREE.Texture | null>(null);
  const startRef = useRef<number>(performance.now());

  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    const img = new Image();
    img.onload = () => {
      if (cancelled) return;
      const t = new THREE.Texture(img);
      t.colorSpace = THREE.SRGBColorSpace;
      t.needsUpdate = true;
      startRef.current = performance.now();
      setSize({ w: img.naturalWidth, h: img.naturalHeight });
      setTexture(t);
    };
    img.onerror = () => {
      if (cancelled) return;
      setFailed(true);
    };
    img.src = src;
    return () => {
      cancelled = true;
    };
  }, [src]);

  useEffect(() => {
    return () => {
      texture?.dispose();
    };
  }, [texture]);

  if (failed || !size || !texture) return null;

  const maxW = window.innerWidth * 0.6;
  const maxH = window.innerHeight * 0.6;
  const scale = Math.min(maxW / size.w, maxH / size.h, 1);
  const w = Math.round(size.w * scale);
  const h = Math.round(size.h * scale);

  return (
    <div
      style={{ width: w, height: h }}
      className="overflow-hidden rounded-md ring-1 ring-border/40 shadow-2xl"
    >
      <Canvas
        orthographic
        camera={{ position: [0, 0, 1], zoom: 1 }}
        gl={{ alpha: true, antialias: false, premultipliedAlpha: false }}
        style={{ background: 'transparent' }}
        dpr={[1, 2]}
      >
        <ScanMesh texture={texture} startRef={startRef} />
      </Canvas>
    </div>
  );
}

function ScanMesh({
  texture,
  startRef,
}: {
  texture: THREE.Texture;
  startRef: React.RefObject<number>;
}) {
  const matRef = useRef<THREE.ShaderMaterial>(null);

  const uniforms = useMemo(
    () => ({
      uTexture: { value: texture },
      uTime: { value: 0 },
      uProgress: { value: 0 },
      uOpacity: { value: 0 },
    }),
    [texture],
  );

  useFrame(({ clock }) => {
    const mat = matRef.current;
    if (!mat) return;
    const elapsed = performance.now() - startRef.current;
    let opacity: number;
    let progress: number;
    if (elapsed < FADE_IN_MS) {
      opacity = elapsed / FADE_IN_MS;
      progress = 0;
    } else if (elapsed < FADE_IN_MS + SCAN_MS) {
      opacity = 1;
      progress = (elapsed - FADE_IN_MS) / SCAN_MS;
    } else {
      const t = (elapsed - FADE_IN_MS - SCAN_MS) / FADE_OUT_MS;
      opacity = Math.max(0, 1 - t);
      progress = 1;
    }
    mat.uniforms.uTime.value = clock.elapsedTime;
    mat.uniforms.uProgress.value = progress;
    mat.uniforms.uOpacity.value = opacity;
  });

  return (
    <mesh>
      <planeGeometry args={[2, 2]} />
      <shaderMaterial
        ref={matRef}
        uniforms={uniforms}
        vertexShader={vertexShader}
        fragmentShader={fragmentShader}
        transparent
      />
    </mesh>
  );
}

const vertexShader = /* glsl */ `
  varying vec2 vUv;
  void main() {
    vUv = uv;
    gl_Position = vec4(position, 1.0);
  }
`;

const fragmentShader = /* glsl */ `
  precision highp float;
  varying vec2 vUv;
  uniform sampler2D uTexture;
  uniform float uTime;
  uniform float uProgress;
  uniform float uOpacity;

  float rand(vec2 co) {
    return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
  }

  void main() {
    vec4 tex = texture2D(uTexture, vUv);
    vec3 color = tex.rgb;

    // Soft white scan band sweeping top → bottom.
    float scanY = 1.0 - uProgress;
    float band = exp(-pow((vUv.y - scanY) * 22.0, 2.0));
    color += vec3(band * 0.45);

    // Faint trailing brighten just below the band so it reads as a sweep
    // not a static highlight.
    float trail = smoothstep(0.0, 0.18, scanY - vUv.y) * (1.0 - smoothstep(0.18, 0.32, scanY - vUv.y));
    color += vec3(trail * 0.06);

    // Subtle horizontal scanlines.
    color *= 0.97 + 0.03 * sin(vUv.y * 600.0);

    // Subtle grain (animated so it reads as living noise, not static dots).
    color += (rand(vUv * (uTime + 1.0)) - 0.5) * 0.035;

    gl_FragColor = vec4(color, tex.a * uOpacity);
  }
`;
