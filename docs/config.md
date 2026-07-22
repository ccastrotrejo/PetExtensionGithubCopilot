# Configuration

The pet works with zero configuration. To customize it, create a `config.json` next to the extension
and edit the keys you care about — everything is optional and missing keys keep their defaults.

## Location

```
~/.copilot/extensions/copilot-pet/config.json
```

A ready-to-copy template lives in the repo:

```sh
cp ~/.copilot/extensions/copilot-pet/config.example.json \
   ~/.copilot/extensions/copilot-pet/config.json
```

`config.json` is git-ignored, so your personal settings never get committed.

## Hot-reload

The pet polls `config.json` a few times a second and applies changes **live** — no restart needed.
Save the file and the pet resizes, mutes, or stills itself within a moment. An absent, empty, or
malformed file simply falls back to the defaults (and the extension logs a warning for invalid JSON).

## Keys

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `size` | number | `62` | Pet size in points. Clamped to `32`–`160`; the window grows/shrinks to fit. Cells are integer-sized so the sprite stays crisp at any size. |
| `speed` | number | `1` | Animation speed multiplier. Clamped to `0.5`–`2.0` — lower is calmer, higher is livelier. Scales the whole animation clock (breathing, wag, idle antics). |
| `lookAroundInterval` | number \| `[min, max]` | `[4, 9]` | Seconds between autonomous glances (left / right / at-you). A single number fixes the interval; a pair randomizes within the range. Values below `1` are raised to `1`. |
| `enabledBehaviors` | string[] | `["lookAround", "bubbles"]` | Which autonomous behaviors are on. Known values: `lookAround` (glancing), `bubbles` (speech bubbles). Unknown entries are ignored; an empty list turns them all off. |
| `muted` | boolean | `false` | When `true`, suppresses all speech bubbles (a quick "quiet" toggle, independent of `enabledBehaviors`). |
| `reduceMotion` | boolean | `false` | Accessibility: when `true`, non-essential motion (whole-body bob/breathing, head tilt/trembling, tail wag and ear-flap amplitude, accessory bob) is damped to ~15% and the gear/sparkle/panting-tongue animations freeze on one frame; look-around stops too. Expressions (eyes, mouth, accessory, speech bubble) are unaffected. Combines with (does not replace) the OS-level Reduce Motion accessibility setting — either one stills the pet. |
| `palette` | string | `"chestnut"` | Coat colour scheme. One of `chestnut` (red-and-tan), `black-and-tan`, `red`, or `cream`. Matched case-insensitively; an unknown name falls back to `chestnut`. |
| `name` | string | `""` | Give the pet a name. Shown subtly: on hover (tooltip) and in its greeting when a session starts ("hi, I'm …!"). Trimmed to 24 characters. |
| `breed` | string | `"dachshund"` | **Reserved** for the personalization work. Parsed and stored today, but only the dachshund is drawn. |
| `openOnDoubleClick` | string | `""` | What **double-clicking the pet** opens. Empty (default) launches/focuses the **GitHub Copilot host app** that spawned the pet. Set a bundle id (`"com.github.githubapp"`), an app name (`"Copilot"`) or full path (`"/Applications/Copilot.app"`) to target something else, or `"none"`/`"off"` to disable double-click entirely. Single-click-drag still moves the pet regardless. |

## Examples

A big, calm, quiet pet (good while pairing or presenting):

```json
{
  "size": 96,
  "muted": true,
  "reduceMotion": true
}
```

A small pet that glances around often:

```json
{
  "size": 48,
  "lookAroundInterval": [2, 4]
}
```

A pet that stays put and never speaks, but still animates:

```json
{
  "enabledBehaviors": []
}
```

A personalized companion — a named cream dachshund that moves calmly:

```json
{
  "name": "Biscuit",
  "palette": "cream",
  "speed": 0.8
}
```

## Where it's read

Both halves of the extension use the file:

- **`extension.mjs`** passes the config path to the pet and warns (via `session.log`) if the JSON is invalid.
- **`pet.swift`** reads and hot-reloads it, mapping keys to size, look-around timing, behaviors, mute, and Reduce Motion.

The parsing and defaults live in the pure, unit-tested `PetConfig` type in `PetCore.swift`
(see `Tests/PetCoreTests.swift`).
