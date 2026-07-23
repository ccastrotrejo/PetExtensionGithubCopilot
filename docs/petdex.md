# Petdex interop

`copilot-pet` interoperates with [**Petdex**](https://petdex.dev) — the public
gallery of animated coding-agent companions ([crafter-station/petdex](https://github.com/crafter-station/petdex)).
This is the ecosystem work from **issue #10** (built on the pet-pack format +
spritesheet loader from #9). It has two halves:

- **Consume** — browse the public Petdex gallery and install community pets, so
  the desktop companion isn't limited to our one dog.
- **Contribute** — export our flagship dachshund as a valid Petdex pet you can
  submit back to the gallery.

The bespoke, code-drawn dachshund stays the **default and flagship**. Petdex
packs are strictly opt-in (`activePet` in [`config.json`](config.md)).

## The pet-pack format

A Petdex pet is a folder with two files:

```
my-pet/
├── pet.json          { id, displayName, description, spritesheetPath }
└── spritesheet.webp  a grid of 192×208 frames (also accepts .png)
```

The spritesheet is a grid of **192×208-pixel frames**. Each **row is an
animation state**; each **column is one frame** of that state's loop:

| Row | State | Our mood(s) |
| --- | --- | --- |
| 0 | `idle` | `idle`, `sleeping` |
| 1 | `wave` | `greet`, `nudge`, `loved` |
| 2 | `run` | `working` |
| 3 | `failed` | `worried` |
| 4 | `review` | `thinking` |
| 5 | `jump` | `happy`, `celebrate` |
| 6 | `extra1` | — |
| 7 | `extra2` | — |

Petdex documents an 8×9 grid (1536×1872), but the **frame size (192×208) is the
real invariant** — curated sheets vary in row count (e.g. `homelander` is 8×9,
`boba` is 8×11). We derive the grid by dividing the decoded image by 192×208, so
both load correctly. Only rows 0–7 are mapped to moods; extra rows are ignored.
Playback is **6 fps** (~1100 ms per 8-frame loop).

The frame math, the `Mood → PetdexState` mapping, and `pet.json` parsing are all
pure and unit-tested in [`Tests/PetCoreTests.swift`](../Tests/PetCoreTests.swift)
(see `SpriteSheet`, `PetdexState`, `PetPackInfo` in `PetCore.swift`).

## Consume — browse & install community pets

The extension exposes a **`pet_gallery`** tool (ask Copilot in natural language,
e.g. *"show me some Petdex pets"* or *"install the boba pet"*):

| Action | What it does |
| --- | --- |
| `browse` | Search the public manifest (`query` matches name/slug/kind; `limit`, default 15). |
| `install <slug>` | Download a pet's `pet.json` + spritesheet into `~/.copilot-pet/pets/<slug>/`. |
| `use <slug>` | Switch the active pet (`activePet` in `config.json`). Use `dachshund` to restore the built-in dog. |
| `installed` | List downloaded pets and which one is active. |
| `remove <slug>` | Delete a downloaded pet (reverts to the dog if it was active). |

Under the hood:

- The gallery manifest (`petdex.dev/api/manifest`, ~4k pets) is fetched once and
  cached in the state dir with a 6-hour TTL; a stale cache is reused if the
  network is down.
- `install` writes to `~/.copilot-pet/pets/<slug>/` atomically and normalizes
  `pet.json`'s `spritesheetPath` to the downloaded file.
- `use` merge-writes only the `activePet` key, preserving your other settings.
  The Swift renderer **hot-reloads** it — the pet swaps within a couple of
  seconds, resizing the window to the pack's frame aspect. A pack that fails to
  load falls back to the dachshund.

Installed spritesheet pets react to the same Copilot signals as the dog: your
prompt makes them `run`, a failing tool plays `failed`, a milestone `jump`s, and
so on (via the mood → state mapping above). Speech bubbles still work; the
dog-only touches (three facings, cursor gaze, idle antics) don't apply — a
Petdex sheet is a fixed, forward-facing animation set.

## Contribute — submit our dachshund

The pet binary can render the flagship dachshund into a Petdex pack:

```sh
tools/export-dachshund.sh            # → assets/petdex/copilot-dachshund/
```

This compiles the pet, runs `pet --export <outdir>` (a headless Core Graphics
render — no window), and writes a canonical **1536×1872** `spritesheet.png` +
`pet.json`, validating the dimensions. Each of the eight states is rendered from
a representative mood so the sheet is as expressive as the live pet (greeting
waves, working runs side-on, failures sweat, thinking shows the thought cloud,
celebrations sparkle). The committed result lives in
[`assets/petdex/copilot-dachshund/`](../assets/petdex/copilot-dachshund/).

Submitting to the gallery is a separate, **interactive** step — Petdex uses
OAuth login, so it can't be fully automated:

```sh
npx petdex submit assets/petdex/copilot-dachshund
```

(You'll be prompted to `petdex login` in a browser the first time.)

## Where things live

| Path | Purpose |
| --- | --- |
| `~/.copilot-pet/pets/<slug>/` | Installed packs (`pet.json` + spritesheet). Read by the Swift renderer (`petsRootDir()`) and written by `pet_gallery install`. |
| `$TMPDIR/copilot-pet/petdex-manifest.json` | Cached gallery manifest (6-hour TTL). |
| `assets/petdex/copilot-dachshund/` | Our exported, submittable Petdex pet. |
| `tools/export-dachshund.sh` | Regenerates the export and prints the submit command. |
