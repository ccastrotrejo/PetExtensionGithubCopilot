// Silhouettes and fur. Builds the static, furry "parts" (body, arm, foot bitmaps)
// once per config; frames only transform them, so fur never shimmers.
import { mulberry32 } from "./schema.js";

export const GROUND_Y = 200;
const CX = 96;
const N = 480;
const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };

export function makeCanvas(w, h) {
  if (typeof document !== "undefined") return Object.assign(document.createElement("canvas"), { width: w, height: h });
  return new OffscreenCanvas(w, h);
}

// Unit silhouette point for parameter th, y up, roughly in [-1, 1].
function unitPoint(c, th) {
  let x = Math.cos(th), y = Math.sin(th);
  switch (c.mode) {
    case "round": case "cloud": {
      const n = c.roundness;
      x = Math.sign(x) * Math.abs(x) ** (2 / n);
      y = Math.sign(y) * Math.abs(y) ** (2 / n);
      if (c.mode === "cloud") {
        const r = 1 + c.puff * smooth(-0.15, 0.35, Math.sin(th)) * Math.abs(Math.cos(c.lobes * (th - Math.PI / 2))) ** 0.6;
        x *= r; y *= r;
      }
      break;
    }
    case "bean": {
      x = x * (1 - c.taper * 0.3 * (y + 1) / 2) + c.lean * 0.55 * Math.max(0, y) ** 1.5 - c.lean * 0.12 * Math.max(0, -y);
      break;
    }
    case "pear": {
      x *= 1 - (0.22 + 0.22 * c.taper) * smooth(-0.4, 1, y);
      break;
    }
    case "star": {
      const k = Math.round(c.points);
      const r = 1 - c.pointDepth * ((1 - Math.cos(k * (th - Math.PI / 2))) / 2) ** 0.85;
      x *= r; y *= r;
      break;
    }
    case "drop": {
      // Teardrop with its tip up: th=π/2 is the tip.
      const p = th - Math.PI / 2;
      x = -Math.sin(p) * Math.abs(Math.sin(p / 2)) ** c.tip;
      y = Math.cos(p);
      break;
    }
  }
  if (y < -0.8) y = -0.8 + (y + 0.8) * 0.35; // sit flat on its feet
  return [x, y];
}

function polygonPath(pts) {
  const p = new Path2D();
  pts.forEach(([x, y], i) => (i ? p.lineTo(x, y) : p.moveTo(x, y)));
  p.closePath();
  return p;
}

function inside(pts, x, y) {
  let hit = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i], [xj, yj] = pts[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) hit = !hit;
  }
  return hit;
}

// Outward unit normals, using the polygon's winding so concave shapes work.
function normals(pts) {
  let area = 0;
  for (let i = 0; i < pts.length; i++) {
    const [x1, y1] = pts[i], [x2, y2] = pts[(i + 1) % pts.length];
    area += x1 * y2 - x2 * y1;
  }
  const sgn = area > 0 ? 1 : -1;
  return pts.map((_, i) => {
    const [x0, y0] = pts[(i - 1 + pts.length) % pts.length], [x1, y1] = pts[(i + 1) % pts.length];
    const dx = x1 - x0, dy = y1 - y0, l = Math.hypot(dx, dy) || 1;
    return [(dy / l) * sgn, (-dx / l) * sgn];
  });
}

/** Body geometry in frame coordinates (192×208, y down). */
export function bodyShape(c) {
  const raw = [];
  for (let i = 0; i < N; i++) raw.push(unitPoint(c, (i / N) * Math.PI * 2));
  const xs = raw.map((p) => p[0]), ys = raw.map((p) => p[1]);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
  const bottomY = GROUND_Y - c.footSize * 0.42;
  const topY = bottomY - c.height;
  const pts = raw.map(([x, y]) => [CX + ((x - (minX + maxX) / 2) / (maxX - minX)) * c.width, bottomY - ((y - minY) / (maxY - minY)) * c.height]);
  const top = pts.reduce((a, b) => (b[1] < a[1] ? b : a));
  return {
    pts, nrm: normals(pts), path: polygonPath(pts), cx: CX, topY, bottomY, top,
    cy: topY + c.height / 2,
    /** [left, right] extent of the silhouette at height y. */
    span(y) {
      let l = Infinity, r = -Infinity;
      for (let i = 0; i < pts.length; i++) {
        const [x1, y1] = pts[i], [x2, y2] = pts[(i + 1) % pts.length];
        if ((y1 - y) * (y2 - y) <= 0 && y1 !== y2) {
          const x = x1 + ((y - y1) / (y2 - y1)) * (x2 - x1);
          l = Math.min(l, x); r = Math.max(r, x);
        }
      }
      return l === Infinity ? [CX - 10, CX + 10] : [l, r];
    },
  };
}

const hsl = (h, s, l, a = 1) => `hsla(${h.toFixed(1)},${s.toFixed(1)}%,${Math.min(96, Math.max(3, l)).toFixed(1)}%,${a})`;

/**
 * Rasterize a furry blob. `pts` is the outline in logical coords; `light` is the
 * key-light point; `dark` darkens the whole blob (limbs sit in the body's shade).
 */
function furBlob(c, pts, { cx, cy, rx, ry, dark = 0, seed }, scale) {
  const rng = mulberry32(seed);
  const len = c.furLength, pad = len * 2 + 3;
  const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
  const x0 = Math.min(...xs) - pad, y0 = Math.min(...ys) - pad;
  const w = Math.max(...xs) + pad - x0, h = Math.max(...ys) + pad - y0;
  const cv = makeCanvas(Math.ceil(w * scale), Math.ceil(h * scale));
  const g = cv.getContext("2d");
  g.scale(scale, scale);
  g.translate(-x0, -y0);
  g.lineCap = "round";
  const { hue: H, sat: S, light: L, shading: sh } = c;
  const lx = cx - rx * 0.4, ly = cy - ry * 0.5;
  const shade = (x, y) => {
    const nx = (x - cx) / rx, ny = (y - cy) / ry;
    const hl = Math.max(0, 1 - Math.hypot(nx + 0.4, ny + 0.5) / 1.3);
    const edge = Math.min(1, Math.max(0, Math.hypot(nx, ny) - 0.5) / 0.5);
    return sh * (15 * hl * hl - 13 * edge ** 1.4 - 9 * Math.max(0, ny) ** 2) - dark;
  };
  // Base: a soft radial key light, so gaps between strands still read as form.
  const grad = g.createRadialGradient(lx, ly, 0, cx, cy, Math.max(rx, ry) * 1.15);
  grad.addColorStop(0, hsl(H, S, L + 10 * sh - dark));
  grad.addColorStop(0.55, hsl(H, S, L - dark));
  grad.addColorStop(1, hsl(H, S + 4, L - 14 * sh - dark));
  g.fillStyle = grad;
  g.fill(polygonPath(pts));

  const strand = (x, y, ang, l, lit, alpha, width) => {
    const ex = x + Math.cos(ang) * l, ey = y + Math.sin(ang) * l, curl = (rng() - 0.5) * l * 0.5;
    g.strokeStyle = hsl(H, S + 3, L + shade(x, y) + lit, alpha);
    g.lineWidth = width;
    g.beginPath();
    g.moveTo(x, y);
    g.quadraticCurveTo((x + ex) / 2 - Math.sin(ang) * curl, (y + ey) / 2 + Math.cos(ang) * curl, ex, ey);
    g.stroke();
  };
  const dirAt = (x, y) => {
    const nx = (x - cx) / rx, ny = (y - cy) / ry;
    return Math.atan2(ny * 0.55 + 0.8, nx * 0.55) + (rng() - 0.5) * 2 * (0.25 + c.furJitter * 0.9);
  };
  // Interior strands, combed down-and-out from the centre.
  const area = w * h * 0.6;
  const count = Math.round((c.furDensity * area) / 3);
  for (let i = 0; i < count; i++) {
    const x = x0 + pad + rng() * (w - 2 * pad), y = y0 + pad + rng() * (h - 2 * pad);
    if (!inside(pts, x, y)) continue;
    const lit = (rng() - 0.5) * (6 + 8 * c.furJitter) + (rng() < 0.12 ? 7 : 0);
    strand(x, y, dirAt(x, y), len * (0.55 + rng() * 0.7), lit, 0.5 + rng() * 0.35, 0.45 + rng() * 0.45);
  }
  // Edge fuzz: strands straddle the outline so it is never a clean curve.
  const nrm = normals(pts);
  const step = Math.max(1, Math.round(pts.length / (pts.length * 0.9 * c.furDensity + 40)));
  for (let pass = 0; pass < 2; pass++) {
    for (let i = 0; i < pts.length; i += step) {
      const [px, py] = pts[i], [nx, ny] = nrm[i];
      const ang = Math.atan2(ny + 0.3, nx) + (rng() - 0.5) * (0.5 + c.furJitter);
      const l = len * (0.45 + rng() * 0.55), back = l * (0.35 + rng() * 0.3);
      const rim = Math.max(0, -0.6 * nx - 0.8 * ny) * 7 * sh;
      strand(px - Math.cos(ang) * back, py - Math.sin(ang) * back, ang, l, rim - 2 + (rng() - 0.5) * 6, 0.85, 0.5 + rng() * 0.4);
    }
  }
  return { canvas: cv, x: x0, y: y0, w, h };
}

function ellipsePts(cx, cy, rx, ry, n = 96) {
  return Array.from({ length: n }, (_, i) => [cx + Math.cos((i / n) * Math.PI * 2) * rx, cy + Math.sin((i / n) * Math.PI * 2) * ry]);
}

const cache = new Map();

/** Static parts for a config, cached. Limbs are built around their own origin. */
export function buildParts(c, scale = 3) {
  const key = JSON.stringify(c) + "@" + scale;
  if (cache.has(key)) return cache.get(key);
  const shape = bodyShape(c);
  const body = furBlob(c, shape.pts, { cx: shape.cx, cy: shape.cy, rx: c.width / 2, ry: c.height / 2, seed: c.seed }, scale);
  const arx = c.armSize * 0.4, ary = c.armSize * 0.6;
  const arm = furBlob(c, ellipsePts(0, ary * 0.7, arx, ary), { cx: 0, cy: ary * 0.7, rx: arx, ry: ary, dark: 5, seed: c.seed ^ 0xa11 }, scale);
  const frx = c.footSize * 0.72, fry = c.footSize * 0.5;
  const foot = furBlob(c, ellipsePts(0, 0, frx, fry), { cx: 0, cy: 0, rx: frx, ry: fry, dark: 7, seed: c.seed ^ 0xf007 }, scale);
  const parts = { shape, body, arm, foot, scale };
  cache.set(key, parts);
  if (cache.size > 24) cache.delete(cache.keys().next().value);
  return parts;
}

export function blit(ctx, bmp) {
  ctx.drawImage(bmp.canvas, bmp.x, bmp.y, bmp.w, bmp.h);
}

export { hsl };
