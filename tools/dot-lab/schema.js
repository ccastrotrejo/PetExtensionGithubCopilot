// Dot Lab config schema: modes, props, knobs (tested bounds + "nice" reroll ranges)
// and defaults. A config is a plain object holding every value below plus `seed`.

export const FRAME_W = 192;
export const FRAME_H = 208;
export const COLS = 8;
export const ROWS = 9;

// Petdex rows 0–7 in order (row 8 repeats idle). See docs/petdex.md.
export const STATES = ["idle", "wave", "run", "failed", "review", "jump", "sleep", "look"];
export const STATE_LABELS = {
  idle: "idle", wave: "wave · greet", run: "run · working", failed: "failed · worried",
  review: "review · thinking", jump: "jump · happy", sleep: "extra1 · sleep", look: "extra2 · look",
};

export const MODES = ["round", "bean", "pear", "star", "drop", "cloud"];
export const PROPS = ["headphones", "pocket", "scarf", "sprout", "beanie", "glasses", "bowtie", "none"];

/** Every taste decision. `modes` limits a knob to some silhouettes (it no-ops elsewhere). */
export const KNOBS = [
  { group: "Body", key: "hue", label: "Hue", min: 0, max: 360, step: 1, nice: [0, 360] },
  { group: "Body", key: "sat", label: "Saturation", min: 25, max: 95, step: 1, nice: [58, 85] },
  { group: "Body", key: "light", label: "Lightness", min: 38, max: 72, step: 1, nice: [48, 64] },
  { group: "Body", key: "width", label: "Width", min: 100, max: 144, step: 1, nice: [114, 138] },
  { group: "Body", key: "height", label: "Height", min: 100, max: 146, step: 1, nice: [112, 138] },
  { group: "Shape", key: "roundness", label: "Squareness", modes: ["round", "cloud"], min: 1.8, max: 3.4, step: 0.05, nice: [2, 2.8] },
  { group: "Shape", key: "lean", label: "Bean lean", modes: ["bean"], min: -0.7, max: 0.7, step: 0.01, nice: [-0.5, 0.5] },
  { group: "Shape", key: "taper", label: "Top taper", modes: ["bean", "pear"], min: 0, max: 1, step: 0.01, nice: [0.2, 0.8] },
  { group: "Shape", key: "points", label: "Star points", modes: ["star"], min: 4, max: 7, step: 1, nice: [5, 6] },
  { group: "Shape", key: "pointDepth", label: "Point depth", modes: ["star"], min: 0.06, max: 0.3, step: 0.01, nice: [0.12, 0.24] },
  { group: "Shape", key: "tip", label: "Tip sharpness", modes: ["drop"], min: 0.5, max: 2, step: 0.05, nice: [0.8, 1.6] },
  { group: "Shape", key: "lobes", label: "Cloud lobes", modes: ["cloud"], min: 3, max: 6, step: 1, nice: [3, 5] },
  { group: "Shape", key: "puff", label: "Puffiness", modes: ["cloud"], min: 0.03, max: 0.14, step: 0.005, nice: [0.06, 0.12] },
  { group: "Fur", key: "furLength", label: "Fur length", min: 1.2, max: 5.5, step: 0.1, nice: [2.2, 4.2] },
  { group: "Fur", key: "furDensity", label: "Fur density", min: 0.4, max: 2.2, step: 0.05, nice: [0.9, 1.6] },
  { group: "Fur", key: "furJitter", label: "Fur messiness", min: 0, max: 1, step: 0.01, nice: [0.25, 0.7] },
  { group: "Fur", key: "shading", label: "Shading", min: 0, max: 1.5, step: 0.05, nice: [0.8, 1.2] },
  { group: "Limbs", key: "armSize", label: "Arm size", min: 12, max: 30, step: 0.5, nice: [17, 26] },
  { group: "Limbs", key: "footSize", label: "Foot size", min: 12, max: 26, step: 0.5, nice: [16, 23] },
  { group: "Face", key: "eyeSize", label: "Eye size", min: 3.5, max: 9, step: 0.1, nice: [5, 7.5] },
  { group: "Face", key: "eyeSpacing", label: "Eye spacing", min: 0.18, max: 0.42, step: 0.005, nice: [0.24, 0.36] },
  { group: "Face", key: "eyeHeight", label: "Eye height", min: 0.3, max: 0.52, step: 0.005, nice: [0.36, 0.46] },
  { group: "Face", key: "smileWidth", label: "Smile width", min: 3, max: 12, step: 0.25, nice: [5, 9] },
  { group: "Face", key: "blush", label: "Blush", min: 0, max: 1, step: 0.01, nice: [0, 0.7] },
  { group: "Prop", key: "prop", label: "Prop", type: "select", options: PROPS },
  { group: "Prop", key: "propHue", label: "Prop hue", min: 0, max: 360, step: 1, nice: [0, 360] },
  { group: "Prop", key: "propSat", label: "Prop saturation", min: 5, max: 85, step: 1, nice: [20, 65] },
  { group: "Prop", key: "propLight", label: "Prop lightness", min: 30, max: 90, step: 1, nice: [60, 86] },
  { group: "Motion", key: "bounce", label: "Bounce", min: 0.3, max: 1.6, step: 0.05, nice: [0.7, 1.3] },
  { group: "Motion", key: "blink", label: "Blinks", min: 0, max: 1, step: 0.01, nice: [0.2, 0.9] },
];

export const DEFAULTS = {
  mode: "round", seed: 1,
  hue: 216, sat: 80, light: 52, width: 128, height: 126,
  roundness: 2.3, lean: 0.35, taper: 0.45, points: 5, pointDepth: 0.18, tip: 1.1, lobes: 4, puff: 0.09,
  furLength: 3.2, furDensity: 1.25, furJitter: 0.45, shading: 1,
  armSize: 21, footSize: 19,
  eyeSize: 6, eyeSpacing: 0.3, eyeHeight: 0.43, smileWidth: 7, blush: 0.25,
  prop: "headphones", propHue: 40, propSat: 30, propLight: 84,
  bounce: 1, blink: 0.5,
};

/** Fill missing keys with defaults and clamp numbers into knob bounds. */
export function normalize(config) {
  const c = { ...DEFAULTS, ...config };
  for (const k of KNOBS) {
    if (k.type === "select") { if (!k.options.includes(c[k.key])) c[k.key] = DEFAULTS[k.key]; continue; }
    const v = Number(c[k.key]);
    c[k.key] = Number.isFinite(v) ? Math.min(k.max, Math.max(k.min, v)) : DEFAULTS[k.key];
  }
  if (!MODES.includes(c.mode)) c.mode = DEFAULTS.mode;
  c.seed = Number(c.seed) >>> 0;
  return c;
}

/** Seeded PRNG — the only source of randomness in the render path. */
export function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Deterministically reroll every unlocked knob (and the mode) from `seed`. */
export function reroll(config, seed, locked = new Set()) {
  const rng = mulberry32(seed ^ 0x9e3779b9);
  const c = { ...config, seed };
  const modeRoll = rng();
  if (!locked.has("mode")) c.mode = MODES[Math.floor(modeRoll * MODES.length)];
  for (const k of KNOBS) {
    const r = rng();
    if (locked.has(k.key)) continue;
    if (k.type === "select") { c[k.key] = k.options[Math.floor(r * k.options.length)]; continue; }
    const [lo, hi] = k.nice;
    c[k.key] = +(Math.round((lo + r * (hi - lo)) / k.step) * k.step).toFixed(4);
  }
  return normalize(c);
}
