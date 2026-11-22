<h1 align="center">Guy with a Kid on His Back</h1>

<p align="center">
  <b>PRAGMATA (Nintendo Switch 2) as a native iPhone app</b><br>
  built on <a href="https://github.com/seedds/nxnative">nxnative</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-work%20in%20progress-e65100" alt="Work in progress">
  <img src="https://img.shields.io/badge/iOS-27%2B-000000?logo=apple" alt="iOS 27 or later">
  <img src="https://img.shields.io/badge/graphics-Metal%204-1565c0" alt="Metal 4">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-c9a227" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#latest-v23">Latest</a> ·
  <a href="#where-it-stands">Where it stands</a> ·
  <a href="#features">Features</a> ·
  <a href="#requirements">Requirements</a> ·
  <a href="#build">Build</a> ·
  <a href="#install-and-play">Install and play</a> ·
  <a href="#best-settings">Best settings</a> ·
  <a href="#known-issues">Known issues</a> ·
  <a href="#credits">Credits</a>
</p>

> [!NOTE]
> **Not an emulator.** The game's own code runs directly on the Apple chip, with its graphics rebuilt on Metal. Nothing from the game is in this repository: you build the app yourself from your own copy of PRAGMATA. This project is not affiliated with the game's creators or with Nintendo.

> [!WARNING]
> **Work in progress.** PRAGMATA runs on an iPhone 18 Pro through the opening and into play, but it is not stable for long sessions yet, and it does not run on 8 GB devices yet. See [Where it stands](#where-it-stands).

## Latest: V23

- **New touch stick:** a plain translucent knob in a faint ring, drawn the way the [Ocarina of Time port](https://github.com/cheemu21/kid-with-sword-remake) draws its stick.
- **Bigger D-pad:** about 30 % larger, with solid arrowheads and no circle around it, moved clear of the home bar and the ZL key.
- Everything from V22: the fix for the black screen that could take the whole phone down, shader-code memory kept out of the GPU's memory, smaller clears and idle upload memory given back.

## Where it stands

Measured on an **iPhone 18 Pro** (A20 Pro), iOS 27.2:

- **Title screen and menus:** 60 fps.
- **Gameplay:** 30 fps with frame generation on, so 60 fps on screen; frame times steady at 33 ms.
- **Longest runs:** 6–7 minutes of play with no GPU error (V20, V22), each ended by the player leaving the app.
- **GPU memory in play:** 5.7–6.6 GB resident, inside the 18 Pro's 8 GB budget.
- **GPU time:** about 25 ms a frame in play plus 3.5 ms for frame generation, of a 33 ms budget.

**8 GB devices** (iPhone 15 Pro class) are the next goal: their GPU budget is about 5.4 GB, so memory needs another 1.5 GB or so cut, and their GPU is slower.

## Features

**Memory** (the main blocker on iPhone)

- Large memory pools are wired only as far as the game reads them, and their old copies are released once the GPU is done with them.
- A lookup of unknown length near the end of a growing pool takes a small buffer to the pool's end instead of a copy of the whole pool (the opening's crashes, V14–V17).
- Shared render targets nothing has used for 60 seconds are released (up to 860 MB in play).
- Shader-code pools stay out of the GPU's memory (the GPU never reads them).
- Idle upload staging is given back (`DM_NVN_UPLOAD_IDLE_MS`).
- A memory census in the log every 1,800 frames: what holds the GPU's memory, by kind.

**Stability**

- Guest-file pages are wired before the residency commit, so the GPU driver never pages the game's memory files in itself; that froze the game and once panicked the phone.
- The residency commit runs off the GPU completion queue, so one slow commit cannot hold up every finished frame.

**Performance and presentation**

- Frame generation: the game draws 30 frames a second and MetalFX's frame interpolator makes the one between each two (about 3.5 ms each).
- One-pass layered texture clears (a 3D texture was cleared in 128 passes every frame), reused sparse-texture gather buffers.

**Touch controls ("Orbit")**

- ZL locks on with a tap and is held with a long press; a large second fire key appears at the top left while aiming.
- Near-white highlights, the stick in the Ocarina of Time port's style, a large D-pad with arrowheads.

## Requirements

- **Your own copy of PRAGMATA:** a `.nup` holding update v196608 (no base game or DLC needed).
- **A Mac with Apple silicon**, Xcode 27.2 or later, and Python 3.14 or later (reading a `.nup` needs `compression.zstd`). The first build compiles every shader and needs a lot of disk space (about 43 GB beyond the dump, about 2 hours on an M5).
- **An iPhone with 12 GB of memory or more for now** (tested: iPhone 18 Pro), iOS 27 or later, and a way to run an unsigned IPA (tested with LiveContainer / Strata).

## Build

```sh
git clone https://github.com/cheemu21/guy-with-a-kid-on-his-back.git
cd guy-with-a-kid-on-his-back
python3 scripts/build_ipa_from_nsp.py "/path/to/your dump.nup" --platform ios --romfs separate
```

The build writes an unsigned IPA. The game files are not inside it: copy them to the phone once, with the app installed, using the command the build prints at the end:

```sh
scripts/push_romfs.sh <device UDID> org.nxnative.0400c76024710000 "<build folder>/extract/v196608/RomFS.img"
```

Later builds reuse the extracted game files and the compiled shaders, and take about 3 minutes.

## Install and play

1. Install the IPA in LiveContainer (tested with Strata: Apps → **+** → Install IPA File). When asked about an existing app with the same bundle ID, replace it to keep your saves.
2. The game needs a large address space. Put this in the app's `Documents/env.txt`:

   ```
   DM_ALIAS_SIZE=0xC00000000
   ```

3. Start PRAGMATA from the launcher.

## Best settings

- **Frame rate 30 with Frame generation on:** 60 fps on screen. Native 60 fps in play is out of reach on the GPU's budget.
- **Handheld console mode:** the game renders its 3D at a lower resolution.
- **Performance HUD** (launcher): frame rate, GPU time and memory over the game.
- **Diagnostics** (`Documents/env.txt`): `DM_MEMSTAT=memstat.tsv` writes memory by region once a second; `DM_NVN_GPUPROF=every:1800` times every GPU pass in one frame a minute.

## Known issues

- **GPU memory** is above the budget of 8 GB devices; long sessions on the 18 Pro may still run out.
- **After a GPU hang** the game can go on at about one frame a second instead of recovering.
- **A GPU address fault at the title movie** happens now and then; the game recovers from it.
- **Some tessellated draws are not replayed**, so a few pieces of geometry may be missing.
- **Heavy streaming** on the way into play can stutter (frames of 50–67 ms).

## Credits

- **[huzaifahshahid71-ops](https://github.com/huzaifahshahid71-ops)** — the [PRAGMATA iOS investigation](https://github.com/huzaifahshahid71-ops/pragmata-ios-investigation) this port started from: the pinned nxnative changes, diagnostic tools and investigation notes it was handed over as.
- **[seedds/nxnative](https://github.com/seedds/nxnative)** and its contributors — the native runtime, the Metal 4 graphics and upstream's PRAGMATA support this is built on. Upstream fixes ported here include work by [stan69b](https://github.com/stan69b) (guest-file wiring, shader-code pools, render-target heap slack, from PRs #1971 and #2566), [oliverames](https://github.com/oliverames) and kencalx's [NX18](https://github.com/kencalx/NX18) (the residency commit worker, PR #2868), [eibrunocorrea](https://github.com/eibrunocorrea) (indirect-draw masks, PR #2945) and [aksmith-git](https://github.com/aksmith-git) (idle upload staging, PR #1491).
- **[Kid with Sword Remake](https://github.com/cheemu21/kid-with-sword-remake)** (the Ocarina of Time port) — frame generation and the touch stick's design.

Upstream source and its modifications keep the upstream MIT notice in [LICENSE](LICENSE). nxnative's own documentation (other games, the Mac app, developer notes) is in [docs](docs) and [dm/games](dm/games/README.md).
