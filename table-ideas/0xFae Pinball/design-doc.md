# Fairy Ring Pinball — Design Doc

Working title. TIC-80. v1 scope. Written 2026-10-08.

## High concept

A multi-table fairy pinball game. No scrolling: every table is a single 240x136 screen, connected by a warp web of fairy rings. Three ball types with genuinely different physics. Dynamic bumpers as living creatures with states. (Design lineage: the manuals digest, the Amano devlog's physics-first philosophy, and the Terra Nova Lua reference.)

## Theme and tone

Whimsical night-garden fairy world. Cute Japanese anime-style fairies (chibi pixel art in the Panel de Pon lineage), preferred over Western fairy depictions. Reference board: 30+ images in workspace/user/media_library, uploaded 2026-10-08. Pastels and glow on the 16-color palette: deep indigo backgrounds, luminous greens, petal pinks, firefly gold. Music: music-box arpeggios (TIC-80 has 4 sound channels; reserve one for SFX).

## Balls (the core mechanic)

The player unlocks balls by completing table quests, then picks any unlocked ball at launch. Each ball changes how every table plays.

1. **Marble** (starter): heavy glass. Full gravity, high top speed, restitution 0.55 (thuddy). Smashes cracked targets (acorn shells, brittle ice) that other balls bounce off. Weakness: drains fast, demands confident flipper play.
2. **Gumball**: restitution 0.95, medium mass. Sticks to sticky surfaces (web strands, honey pots) for about 1 second or until nudged free. Chaotic and fun, hardest to aim precisely.
3. **Dandelion Puff**: gravity scale 0.35, high air drag, drifts with wind zones. Floaty and precise, rides updrafts to high table regions. Weakness: wind can shove it into drains, and bumpers knock it silly.

All numbers are starting points. Tuning is playtest-driven, not theory-driven.

## Tables (the warp web)

Hub: **The Fairy Ring**, a small screen with rings to each unlocked table.

1. **Mushroom Grove** (starter): classic fan layout. Teaches launch, flippers, drain. Quest: light 3 toadstool targets, ring opens to Spider's Web.
2. **Spider's Web**: sticky strands, and the Spider drops on a timer as a roaming bumper. Quest: free 5 trapped fireflies, ring opens to Storm Cloud.
3. **Storm Cloud**: wind zones (the puff's home turf), lightning bumpers on timed flash windows that score big only while lit. Quest: charge the storm by hitting cloud banks, ring opens to Thorn Thicket.
4. **Thorn Thicket**: tight lanes, bramble gates on independent open/close timers, thorn bumpers that punish mistakes. Quest: bloom the 3 night flowers, ring opens to the finale.
5. **Midsummer Finale** (v2): compact boss table. The Wisp King fights in phases; each phase reconfigures the bumpers (one table, many states, the DotM moon-phase trick). Pushed to v2 per 2026-10-08 decision; v1 ends at Thorn Thicket's quest.

Rule, stolen from the digest: every warp is earned. Never a free teleport; the gate is the game.

## Dynamic mechanisms (creatures as bumpers)

Bumpers have 2 to 4 states, and each state changes what they do and what else is live on the table:

- Bloom flowers: closed (acts as wall), open (bumper), spent (gone until relit).
- Fireflies: drift on slow orbits; catching all 5 on a table feeds the meta-goal.
- The Spider: drops in on a timer, roams the table, retreats.
- Lightning: timed flash windows, 3x points while lit.
- Bramble gates: open and closed on independent timers, gating lanes.

## Scoring

Base points multiplied by the Dewdrop Multiplier: build x2/x3/x4 via dewdrop banks (Terra Nova's constellation idea). Bumper values scale with ball speed, faster hits pay more, rewarding aggressive play. Skillshot on launch: 25,000. Extra ball every 250,000 points: a fixed, readable cadence the player can plan around.

## Meta-goal (cross-table)

**The Lantern**: each table quest frees or catches fireflies. Collect 12 across all tables to light the Lantern, triggering **Midsummer Multiball**: 3 balls, 20-second ball saver, 2x scoring. This is the reason to play every table.

## Second chances

- **Mushroom Bounce** (Kirby's Springboard, stolen with love): on drain, a timed button press. Perfect timing returns the ball to the top of the table, good timing to mid-table. Limited uses per ball.
- **Dewdrop Saver**: one outlane saver per ball, re-armed by completing the dewdrop bank.

## Nudge

DotM's system, wholesale: directional nudge on a regenerating meter. Overuse triggers TILT: no nudge until the meter fully refills, and the multiplier resets to x1. Fair, readable, no nudge spam.

## Controls (TIC-80)

- Z or Left arrow: left flipper. M or Right arrow: right flipper.
- X or Up: plunger (hold to charge, release to launch).
- A plus a direction: nudge.
- 60fps, 240x136, standard TIC-80 cart.

## Physics core (build notes)

- Ball is a circle. Table geometry is line segments, circles (bumpers), and arcs. Circle-vs-segment collision, no full rigid-body engine (devlog rule: prefer something simple and done by yourself).
- Fixed timestep: 2 physics substeps per frame at 60fps to start; raise to 3 if the fast marble tunnels.
- Per-ball parameters: gravity scale, restitution, mass (used for target-break thresholds), air drag.
- Flippers are rotating segments. On contact during a swing, impart velocity along the flipper's arc, scaled by swing speed. This is what makes flipper shots feel alive.

## Art direction

Backgrounds in layered silhouettes: dark indigo base, teal mid-layer, glow accents on top. Tables drawn as sprite art, creatures as animated sprites. Particles: pollen and spores on hits, petal bursts on jackpots. Screen shake reserved for multiball start only; restraint everywhere else.

## Sound

One music-box arpeggio motif per table, varied by key and tempo. SFX per ball personality: wooden knock for flippers, glass ting for the marble, boing for the gumball, soft whuff for the puff, chime for warps.

## Build order

- **Phase 0**: cart scaffold. Marble only, Mushroom Grove only. Launch, flippers, drain, score, game over. A playable loop first, everything else later.
- **Phase 1**: physics tuning pass, then gumball and puff with their full profiles.
- **Phase 2**: hub plus warp web plus the remaining 3 tables as basic layouts (no creatures yet). Midsummer Finale boss table is v2.
- **Phase 3**: creatures and state machines, table quests, warp gating, the Lantern meta-goal, Mushroom Bounce, nudge meter. Wind zones work mechanically in Phase 2/3; drifting spore particle visuals for wind are v2.
- **Phase 3**: creatures and state machines, table quests, warp gating, the Lantern meta-goal, Mushroom Bounce, nudge meter.
- **Phase 4**: juice (particles, shake, SFX and music), high score persistence via TIC-80's save memory, balance pass.

## Resolved decisions (2026-10-08)

- Ball select UI: pre-launch picker showing unlocked balls.
- v1 table count: 4 tables plus hub.
- Midsummer Finale (Wisp King boss table): pushed to v2.
- Wind zone visuals: drifting spore particles, also v2 (wind mechanics stay in v1 for Storm Cloud, with simpler indicators until the spore pass).
