// Face, role props and state effects — drawn per frame in body space.
import { mulberry32 } from "./schema.js";
import { hsl } from "./body.js";

const INK = "#1a1110";

function eye(g, x, y, r, kind, look) {
  g.lineCap = "round";
  if (kind === "open") {
    const ex = x + look[0] * 0.35, ey = y + look[1] * 0.35;
    const grad = g.createRadialGradient(ex - r * 0.3, ey - r * 0.4, r * 0.1, ex, ey, r * 1.1);
    grad.addColorStop(0, "#4a3330");
    grad.addColorStop(1, "#0b0706");
    g.fillStyle = grad;
    g.beginPath(); g.ellipse(ex, ey, r * 0.8, r, 0, 0, Math.PI * 2); g.fill();
    g.fillStyle = "rgba(255,255,255,0.95)";
    g.beginPath(); g.arc(ex - r * 0.28 + look[0] * 0.15, ey - r * 0.4 + look[1] * 0.12, r * 0.3, 0, Math.PI * 2); g.fill();
    g.fillStyle = "rgba(255,255,255,0.6)";
    g.beginPath(); g.arc(ex + r * 0.3, ey + r * 0.38, r * 0.13, 0, Math.PI * 2); g.fill();
    return;
  }
  g.strokeStyle = INK;
  g.lineWidth = Math.max(1.3, r * 0.34);
  g.beginPath();
  if (kind === "happy") { g.moveTo(x - r * 0.8, y + r * 0.3); g.quadraticCurveTo(x, y - r * 0.8, x + r * 0.8, y + r * 0.3); }
  else if (kind === "sleep") { g.moveTo(x - r * 0.8, y + r * 0.1); g.quadraticCurveTo(x, y + r * 0.6, x + r * 0.8, y + r * 0.1); }
  else { g.moveTo(x - r * 0.8, y + r * 0.15); g.quadraticCurveTo(x, y + r * 0.45, x + r * 0.8, y + r * 0.15); }
  g.stroke();
}

function mouth(g, x, y, w, kind) {
  g.lineCap = "round";
  g.strokeStyle = "#2c1514";
  g.lineWidth = Math.max(1.3, w * 0.2);
  g.beginPath();
  if (kind === "open") {
    g.moveTo(x - w * 0.55, y);
    g.quadraticCurveTo(x, y + w * 1.15, x + w * 0.55, y);
    g.closePath();
    g.fillStyle = "#5b1d22";
    g.fill();
    g.save(); g.clip();
    g.fillStyle = "#ef7f8c";
    g.beginPath(); g.ellipse(x, y + w * 0.62, w * 0.32, w * 0.24, 0, 0, Math.PI * 2); g.fill();
    g.restore();
    return;
  }
  if (kind === "frown") { g.moveTo(x - w * 0.42, y + w * 0.35); g.quadraticCurveTo(x, y - w * 0.12, x + w * 0.42, y + w * 0.35); }
  else if (kind === "o") { g.ellipse(x, y + w * 0.15, w * 0.17, w * 0.21, 0, 0, Math.PI * 2); g.fillStyle = "#2c1514"; g.fill(); return; }
  else if (kind === "sleepy") { g.moveTo(x - w * 0.25, y + w * 0.1); g.quadraticCurveTo(x, y + w * 0.3, x + w * 0.25, y + w * 0.1); }
  else { g.moveTo(x - w * 0.5, y); g.quadraticCurveTo(x, y + w * 0.6, x + w * 0.5, y); }
  g.stroke();
}

export function faceGeom(c, shape) {
  const eyeY = shape.topY + c.height * c.eyeHeight;
  const cx = shape.span(eyeY).reduce((a, b) => a + b) / 2;
  return { cx, eyeY, dx: (c.width * c.eyeSpacing) / 2, mouthY: eyeY + c.eyeSize * 1.15, r: c.eyeSize };
}

export function drawFace(g, c, shape, a) {
  const f = faceGeom(c, shape);
  const fx = f.cx + a.look[0] * 0.5, fy = f.eyeY + a.look[1] * 0.4;
  const blush = Math.min(1, c.blush + (a.blush || 0));
  if (blush > 0.01) {
    for (const s of [-1, 1]) {
      const bx = fx + s * f.dx * 1.2, by = fy + f.r * 1.35, br = f.r * 1.5;
      const grad = g.createRadialGradient(bx, by, 0, bx, by, br);
      grad.addColorStop(0, `hsla(350,85%,72%,${0.55 * blush})`);
      grad.addColorStop(1, "hsla(350,85%,72%,0)");
      g.fillStyle = grad;
      g.beginPath(); g.ellipse(bx, by, br, br * 0.7, 0, 0, Math.PI * 2); g.fill();
    }
  }
  for (const s of [-1, 1]) eye(g, fx + s * f.dx, fy, f.r, a.eyes, a.look);
  if (a.brows) {
    g.strokeStyle = hsl(c.hue, c.sat, c.light - 32);
    g.lineWidth = Math.max(1.2, f.r * 0.3);
    for (const s of [-1, 1]) {
      g.beginPath();
      g.moveTo(fx + s * (f.dx + f.r * 0.9), fy - f.r * 1.55);
      g.lineTo(fx + s * (f.dx - f.r * 0.6), fy - f.r * 2.15);
      g.stroke();
    }
  }
  mouth(g, fx, f.mouthY + a.look[1] * 0.4, c.smileWidth, a.mouth);
}

// --- Props: one per Dot, in a contrasting material. ---

const material = (c, dl = 0) => hsl(c.propHue, c.propSat, c.propLight + dl);

function plastic(g, x, y, w, h, c) {
  const grad = g.createLinearGradient(x - w, y - h, x + w, y + h);
  grad.addColorStop(0, material(c, 8));
  grad.addColorStop(0.6, material(c));
  grad.addColorStop(1, material(c, -16));
  return grad;
}

const PROP_DRAW = {
  headphones(g, c, shape) {
    const cupY = faceGeom(c, shape).eyeY + c.eyeSize * 0.3;
    const [l, r] = shape.span(cupY);
    const mid = (l + r) / 2, crx = c.width * 0.09, cry = c.height * 0.15;
    g.lineCap = "round";
    const ry = cupY - shape.topY + c.furLength + 3;
    g.strokeStyle = material(c, -18); g.lineWidth = 7.5;
    g.beginPath(); g.ellipse(mid, cupY, (r - l) / 2 + 1, ry, 0, Math.PI, Math.PI * 2); g.stroke();
    g.strokeStyle = material(c, 4); g.lineWidth = 5;
    g.beginPath(); g.ellipse(mid, cupY - 0.8, (r - l) / 2 + 1, ry, 0, Math.PI * 1.04, Math.PI * 1.96); g.stroke();
    for (const [x, s] of [[l, -1], [r, 1]]) {
      const ex = x + s * crx * 0.25;
      g.fillStyle = plastic(g, ex, cupY, crx, cry, c);
      g.beginPath(); g.ellipse(ex, cupY, crx, cry, 0, 0, Math.PI * 2); g.fill();
      g.fillStyle = material(c, -14);
      g.beginPath(); g.ellipse(ex - s * crx * 0.55, cupY, crx * 0.45, cry * 0.85, 0, 0, Math.PI * 2); g.fill();
      g.strokeStyle = "rgba(255,255,255,0.55)"; g.lineWidth = 1.4;
      g.beginPath(); g.ellipse(ex, cupY, crx * 0.6, cry * 0.7, 0, Math.PI * 1.1, Math.PI * 1.5); g.stroke();
    }
  },
  pocket(g, c, shape, rng) {
    const w = c.width * 0.4, h = c.height * 0.22, y = shape.bottomY - c.height * 0.18 - h / 2;
    const x = shape.span(y).reduce((a, b) => a + b) / 2;
    g.save(); g.translate(x, y); g.rotate((rng() - 0.5) * 0.08);
    const rr = new Path2D(); rr.roundRect(-w / 2, -h / 2, w, h, [3, 3, w * 0.22, w * 0.22]);
    g.fillStyle = plastic(g, 0, 0, w / 2, h / 2, c); g.fill(rr);
    g.fillStyle = material(c, -10);
    for (let i = 0; i < 90; i++) g.fillRect(-w / 2 + rng() * w, -h / 2 + rng() * h, 0.5, 0.5);
    g.setLineDash([2.2, 1.6]); g.strokeStyle = material(c, 14); g.lineWidth = 0.9;
    const st = new Path2D(); st.roundRect(-w / 2 + 2.6, -h / 2 + 2.6, w - 5.2, h - 5.2, [2, 2, w * 0.18, w * 0.18]);
    g.stroke(st);
    g.beginPath(); g.moveTo(-w / 2 + 3, -h / 2 + 6); g.lineTo(w / 2 - 3, -h / 2 + 6); g.stroke();
    g.setLineDash([]);
    g.restore();
  },
  scarf(g, c, shape, rng, a) {
    const fg = faceGeom(c, shape);
    const y0 = Math.max(shape.topY + c.height * 0.58, fg.mouthY + c.smileWidth * 0.6 + 4), t = c.height * 0.11;
    const [l, r] = shape.span(y0 + t / 2);
    const tx = r - c.width * 0.2;
    g.save(); g.translate(tx, y0 + t * 0.6); g.rotate(0.12 + Math.sin(a.phase * Math.PI * 2) * 0.04);
    const tl = c.height * 0.26, tw = t * 0.85;
    g.fillStyle = plastic(g, 0, tl / 2, tw, tl, c); g.fillRect(-tw / 2, 0, tw, tl);
    g.strokeStyle = material(c, -12); g.lineWidth = 1;
    for (let i = 0; i < 6; i++) { const fx = -tw / 2 + 1 + (i / 5) * (tw - 2); g.beginPath(); g.moveTo(fx, tl); g.lineTo(fx + (rng() - 0.5), tl + 3.5); g.stroke(); }
    g.restore();
    const band = new Path2D();
    band.moveTo(l - 2, y0); band.quadraticCurveTo((l + r) / 2, y0 + 6, r + 2, y0);
    band.lineTo(r + 2, y0 + t); band.quadraticCurveTo((l + r) / 2, y0 + t + 7, l - 2, y0 + t); band.closePath();
    g.fillStyle = plastic(g, (l + r) / 2, y0 + t / 2, (r - l) / 2, t, c); g.fill(band);
    g.save(); g.clip(band); g.strokeStyle = material(c, -12); g.lineWidth = 0.8; g.globalAlpha = 0.55;
    for (let x = l; x < r + 2; x += 2.6) { g.beginPath(); g.moveTo(x, y0 - 2); g.lineTo(x + 1, y0 + t + 8); g.stroke(); }
    g.restore();
  },
  sprout(g, c, shape, rng, a) {
    const [tx, ty] = shape.top, sway = Math.sin(a.phase * Math.PI * 2) * 0.08;
    const s = c.height / 130;
    g.save(); g.translate(tx, ty + 3); g.rotate(sway);
    g.strokeStyle = material(c, -20); g.lineWidth = 2.6 * s; g.lineCap = "round";
    g.beginPath(); g.moveTo(0, 0); g.quadraticCurveTo(1, -5 * s, 0, -9 * s); g.stroke();
    for (const side of [-1, 1]) {
      g.save(); g.translate(0, -9 * s); g.rotate(side * 0.95);
      const L = 17 * s, W = 7.5 * s;
      const leaf = new Path2D(); leaf.moveTo(0, 0); leaf.quadraticCurveTo(W, -L / 2, 0, -L); leaf.quadraticCurveTo(-W, -L / 2, 0, 0);
      g.fillStyle = plastic(g, 0, -L / 2, W, L / 2, c); g.fill(leaf);
      g.strokeStyle = material(c, -16); g.lineWidth = 0.8;
      g.beginPath(); g.moveTo(0, -1); g.lineTo(0, -L * 0.8); g.stroke();
      g.restore();
    }
    g.restore();
  },
  beanie(g, c, shape, rng) {
    const fg = faceGeom(c, shape);
    const cut = Math.min(shape.topY + c.height * 0.27, fg.eyeY - c.eyeSize - 8);
    const [l, r] = shape.span(cut), mid = (l + r) / 2;
    const ry = cut - shape.topY + c.furLength + 2;
    g.fillStyle = plastic(g, mid, cut - ry / 2, (r - l) / 2, ry, c);
    g.beginPath(); g.ellipse(mid, cut, (r - l) / 2 + 2.5, ry, 0, Math.PI, Math.PI * 2); g.fill();
    const brim = new Path2D(); brim.roundRect(l - 4, cut - 3, r - l + 8, 8, 4);
    g.fillStyle = material(c, -8); g.fill(brim);
    g.save(); g.clip(brim); g.strokeStyle = material(c, -22); g.lineWidth = 0.8;
    for (let x = l - 4; x < r + 4; x += 2.4) { g.beginPath(); g.moveTo(x, cut - 3); g.lineTo(x, cut + 5); g.stroke(); }
    g.restore();
    const py = cut - ry - 3;
    for (let i = 0; i < 70; i++) {
      const ang = rng() * Math.PI * 2, d = Math.sqrt(rng()) * 6;
      g.strokeStyle = material(c, (rng() - 0.3) * 18); g.lineWidth = 1;
      g.beginPath(); g.moveTo(mid + Math.cos(ang) * d * 0.4, py + Math.sin(ang) * d * 0.4); g.lineTo(mid + Math.cos(ang) * (d + 1.5), py + Math.sin(ang) * (d + 1.5)); g.stroke();
    }
  },
  glasses(g, c, shape, rng, a) {
    const f = faceGeom(c, shape), fx = f.cx + a.look[0] * 0.5, fy = f.eyeY + a.look[1] * 0.4, R = f.r * 1.75;
    g.lineWidth = 2.2; g.strokeStyle = material(c, -30);
    for (const s of [-1, 1]) {
      g.fillStyle = "rgba(255,255,255,0.14)";
      g.beginPath(); g.arc(fx + s * f.dx, fy, R, 0, Math.PI * 2); g.fill(); g.stroke();
      g.strokeStyle = "rgba(255,255,255,0.5)"; g.lineWidth = 1;
      g.beginPath(); g.arc(fx + s * f.dx, fy, R * 0.7, Math.PI * 1.15, Math.PI * 1.45); g.stroke();
      g.lineWidth = 2.2; g.strokeStyle = material(c, -30);
    }
    g.beginPath(); g.moveTo(fx - f.dx + R, fy); g.quadraticCurveTo(fx, fy - R * 0.5, fx + f.dx - R, fy); g.stroke();
  },
  bowtie(g, c, shape) {
    const fg = faceGeom(c, shape);
    const y = Math.max(fg.mouthY + c.smileWidth * 0.6 + 8, shape.topY + c.height * 0.62), x = fg.cx;
    for (const s of [-1, 1]) {
      const w = new Path2D(); w.moveTo(x, y); w.lineTo(x + s * 13, y - 7.5); w.quadraticCurveTo(x + s * 16, y, x + s * 13, y + 7.5); w.closePath();
      g.fillStyle = plastic(g, x + s * 7, y, 8, 8, c); g.fill(w);
    }
    const k = new Path2D(); k.roundRect(x - 3.5, y - 4.5, 7, 9, 2.5);
    g.fillStyle = material(c, -10); g.fill(k);
  },
  none() {},
};

export function drawProp(g, c, shape, a) {
  PROP_DRAW[c.prop](g, c, shape, mulberry32(c.seed ^ 0x9209), a);
}

// --- State effects (screen space, unaffected by squash). ---
export function drawEffects(g, c, shape, a, f) {
  const rng = mulberry32(c.seed ^ 0xeff);
  const t = f / 8, right = shape.span(shape.topY + c.height * 0.25)[1];
  if (a.fx === "sweat") {
    const x = right - 4, y = shape.topY + c.height * 0.2 + t * 10 - a.lift;
    const d = new Path2D(); d.moveTo(x, y - 6); d.quadraticCurveTo(x + 4.5, y + 1, x, y + 3.5); d.quadraticCurveTo(x - 4.5, y + 1, x, y - 6);
    g.fillStyle = "hsla(200,85%,82%,0.95)"; g.fill(d);
    g.fillStyle = "rgba(255,255,255,0.9)"; g.beginPath(); g.arc(x - 1.2, y, 1, 0, Math.PI * 2); g.fill();
  }
  if (a.fx === "sparkle") {
    for (let i = 0; i < 5; i++) {
      const ang = rng() * Math.PI * 2, d = c.width * (0.5 + rng() * 0.1);
      const x = shape.cx + Math.cos(ang) * d * 0.95, y = shape.cy - a.lift + Math.sin(ang) * d * 0.7;
      const s = (2.5 + rng() * 3) * (0.4 + 0.6 * Math.abs(Math.sin((t + i / 5) * Math.PI * 2)));
      g.fillStyle = "hsl(46,100%,72%)";
      g.beginPath(); g.moveTo(x, y - s * 2); g.quadraticCurveTo(x, y, x + s * 2, y); g.quadraticCurveTo(x, y, x, y + s * 2); g.quadraticCurveTo(x, y, x - s * 2, y); g.quadraticCurveTo(x, y, x, y - s * 2); g.fill();
    }
  }
  if (a.fx === "think") {
    const n = Math.floor(f / 2) % 4;
    for (let i = 0; i < n; i++) {
      g.fillStyle = "rgba(255,255,255,0.95)"; g.strokeStyle = "rgba(40,40,60,0.35)"; g.lineWidth = 1;
      g.beginPath(); g.arc(right + 2 + i * 7, shape.topY + 2 - i * 5, 2.2 + i * 0.8, 0, Math.PI * 2); g.fill(); g.stroke();
    }
  }
  if (a.fx === "zzz") {
    g.textAlign = "center";
    for (let i = 0; i < 2; i++) {
      const p = (t + i * 0.5) % 1;
      g.font = `700 ${9 + p * 6}px ui-rounded, system-ui, sans-serif`;
      g.fillStyle = `rgba(90,110,170,${(1 - p) * 0.9})`;
      g.fillText("z", right + p * 8, shape.topY + 6 - p * 18);
    }
  }
  if (a.fx === "dust" && a.lift < 1.5) {
    g.fillStyle = "rgba(160,150,140,0.35)";
    for (const s of [-1, 1]) { g.beginPath(); g.arc(shape.cx + s * c.width * 0.36, 197, 2.5 + rng() * 2, 0, Math.PI * 2); g.fill(); }
  }
}
