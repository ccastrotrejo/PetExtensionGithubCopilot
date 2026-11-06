// Dot renderer entry: render(config, state, frame) is a pure function of the config.
import { FRAME_W, FRAME_H, COLS, ROWS, STATES, normalize } from "./schema.js";
import { buildParts, blit, makeCanvas, GROUND_Y } from "./body.js";
import { drawFace, drawProp, drawEffects } from "./face.js";

export * from "./schema.js";

const TAU = Math.PI * 2;
const PROP_TOP = { headphones: 6, sprout: 30, beanie: 14 };

/** Uniform scale (≤1) that keeps the worst-case pose of this config inside the frame. */
export function fitScale(c) {
  const halfW = Math.max(c.width / 2 + c.armSize * 1.25, c.width * 0.62) + c.furLength * 2 + 5;
  const top = c.height + c.footSize * 0.42 + Math.max(PROP_TOP[c.prop] || 0, 16) + c.furLength * 2 + 18 * c.bounce + 2;
  return Math.min(1, (FRAME_W / 2 - 2) / halfW, (GROUND_Y - 2) / top);
}

/**
 * Pose for one of the 8 frames of a Petdex state. The pet plays sheets at a fixed
 * 6 fps (SpriteSheet.defaultFPS), so active states use keyed per-frame poses with
 * big deltas and anticipation squash; smooth sines read as floaty at 6 fps.
 */
export function animate(c, state, f, shape) {
  const t = f / 8, b = c.bounce;
  const a = { dx: 0, lift: 0, sx: 1, sy: 1, tilt: 0, armL: 0.38, armR: -0.38, eyes: "open", look: [0, 0], mouth: "smile", brows: false, blush: 0, fx: null, phase: t };
  const maxLift = Math.max(0, shape.topY - 22);
  const squash = (sy) => { a.sy = 1 + (sy - 1) * b; a.sx = 1 / Math.sqrt(a.sy); };
  switch (state) {
    case "idle": {
      const br = Math.sin(TAU * t);
      squash(1 + 0.035 * br);
      a.tilt = 0.02 * b * Math.sin(TAU * t + 1);
      a.armL += 0.1 * br; a.armR -= 0.1 * br;
      if ((c.blink >= 0.15 && f === 6) || (c.blink >= 0.65 && f === 2)) a.eyes = "blink";
      break;
    }
    case "wave":
      // A wag on every frame: three waves a second.
      a.armR = f % 2 ? -2.8 : -2.0;
      a.tilt = (f % 2 ? -0.07 : -0.035) * b;
      squash(f % 4 === 0 ? 0.95 : 1.02);
      a.mouth = "open"; a.blush = 0.25;
      break;
    case "run": {
      // One hop every two frames: ground (squash + dust) → air (stretch).
      const air = f % 2 === 1;
      a.lift = Math.min(maxLift, air ? 9 * b : 0);
      squash(air ? 1.06 : 0.9);
      const sw = (f % 4 < 2 ? 1 : -1) * 0.65;
      a.armL = 0.38 + sw; a.armR = -0.38 + sw;
      a.tilt = 0.08 * b;
      a.look = [2.4, 0.8]; a.fx = air ? null : "dust";
      break;
    }
    case "failed":
      a.dx = (f % 2 ? 1.3 : -1.3) * b;
      squash(f % 4 === 0 ? 0.92 : 0.95);
      a.tilt = 0.04;
      a.armL = 0.12; a.armR = -0.12;
      a.look = [0, 1.4]; a.brows = true; a.mouth = "frown"; a.fx = "sweat";
      break;
    case "review":
      a.tilt = (f < 4 ? 0.1 : 0.06) * b;
      a.look = f % 4 < 2 ? [2.2, -2.2] : [1.2, -2.4];
      a.mouth = "o"; a.fx = "think";
      a.armR = f % 2 ? -0.15 : -0.3;
      break;
    case "jump": {
      // Two hops per loop, each with an anticipation squash and arms up in the air.
      const LIFT = [0, 14, 18, 10, 0, 12, 15, 6];
      const SY = [0.84, 1.1, 1.05, 1.0, 0.86, 1.09, 1.04, 0.98];
      a.lift = Math.min(maxLift, LIFT[f] * b);
      squash(SY[f]);
      a.armL = LIFT[f] ? 2.55 : 1.7; a.armR = -a.armL;
      a.eyes = "happy"; a.mouth = "open"; a.blush = 0.35; a.fx = "sparkle";
      break;
    }
    case "sleep": {
      const br = Math.sin(TAU * t);
      squash(1 + 0.03 * br);
      a.tilt = 0.06; a.armL = 0.25; a.armR = -0.25;
      a.eyes = "sleep"; a.mouth = "sleepy"; a.fx = "zzz";
      break;
    }
    case "look": {
      // Snap to each side and hold; a blink sells the switch.
      const side = f < 4 ? -1 : 1;
      a.look = [2.6 * side, 0]; a.tilt = 0.05 * side * b;
      if (f === 4 && c.blink >= 0.15) a.eyes = "blink";
      break;
    }
  }
  return a;
}

/**
 * Draw one frame into `ctx` (already sized FRAME_W*s × FRAME_H*s, cleared by caller).
 * `bmpScale` is the fur bitmap resolution; the same bitmaps serve every frame.
 */
export function renderFrame(ctx, config, state, f, s = 1, bmpScale = 3) {
  const c = normalize(config);
  const p = buildParts(c, bmpScale);
  const { shape } = p;
  const a = animate(c, state, f, shape);
  ctx.save();
  ctx.scale(s, s);
  ctx.imageSmoothingQuality = "high";
  const fit = fitScale(c);
  ctx.translate(shape.cx, GROUND_Y + 4); ctx.scale(fit, fit); ctx.translate(-shape.cx, -GROUND_Y - 4);

  // Contact shadow shrinks and fades as the Dot leaves the ground.
  const k = Math.max(0.3, 1 - a.lift / 40);
  const sh = ctx.createRadialGradient(shape.cx, GROUND_Y + 1, 0, shape.cx, GROUND_Y + 1, c.width * 0.45 * k);
  sh.addColorStop(0, `rgba(20,16,30,${0.26 * k})`);
  sh.addColorStop(1, "rgba(20,16,30,0)");
  ctx.fillStyle = sh;
  ctx.beginPath(); ctx.ellipse(shape.cx, GROUND_Y + 1, c.width * 0.45 * k, 5.5 * k, 0, 0, TAU); ctx.fill();

  // Feet (no squash — they're on the floor).
  for (const side of [-1, 1]) {
    ctx.save();
    ctx.translate(shape.cx + side * c.width * 0.2 + a.dx, GROUND_Y - c.footSize * 0.5 - a.lift);
    blit(ctx, p.foot);
    ctx.restore();
  }

  // Body space: squash/stretch + tilt anchored at the bottom centre.
  ctx.save();
  ctx.translate(shape.cx + a.dx, shape.bottomY - a.lift);
  ctx.rotate(a.tilt);
  ctx.scale(a.sx, a.sy);
  ctx.translate(-shape.cx, -shape.bottomY);
  const shoulderY = shape.topY + c.height * 0.6;
  const [l, r] = shape.span(shoulderY);
  // Hanging arms tuck behind the body; raised ones (wave/jump) come in front so they read.
  const arms = [[l + 4, a.armL, -1], [r - 4, a.armR, 1]];
  const drawArm = ([x, ang, side]) => {
    const raised = Math.abs(ang) > 1.3;
    ctx.save(); ctx.translate(raised ? x + side * 5 : x, raised ? shoulderY - 4 : shoulderY); ctx.rotate(ang); blit(ctx, p.arm); ctx.restore();
  };
  arms.filter(([, ang]) => Math.abs(ang) <= 1.3).forEach(drawArm);
  blit(ctx, p.body);
  drawFace(ctx, c, shape, a);
  drawProp(ctx, c, shape, a);
  arms.filter(([, ang]) => Math.abs(ang) > 1.3).forEach(drawArm);
  ctx.restore();

  drawEffects(ctx, c, shape, a, f);
  ctx.restore();
}

/** Full Petdex spritesheet (8×9 grid of 192×208). Row 8 repeats idle. */
export function renderSheet(config, superSample = 2) {
  const sheet = makeCanvas(FRAME_W * COLS, FRAME_H * ROWS);
  const sg = sheet.getContext("2d");
  sg.imageSmoothingQuality = "high";
  const tmp = makeCanvas(FRAME_W * superSample, FRAME_H * superSample);
  const tg = tmp.getContext("2d");
  for (let row = 0; row < ROWS; row++) {
    const state = STATES[row] || "idle";
    for (let col = 0; col < COLS; col++) {
      tg.clearRect(0, 0, tmp.width, tmp.height);
      renderFrame(tg, config, state, col, superSample);
      sg.drawImage(tmp, col * FRAME_W, row * FRAME_H, FRAME_W, FRAME_H);
    }
  }
  return sheet;
}
