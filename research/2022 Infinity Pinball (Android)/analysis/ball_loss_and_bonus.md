# Infinity Pinball: ball loss, the level-10 bonus, and difficulty

These findings come from the decompiled v1.12 code and data. Method dumps are cited as `<Class>_methods.txt` with the line of the method header. **[C]** = confirmed from code or data, **[I]** = inferred.

## 1. Ball loss

### Hearts
- [C] `PlayerManager.StartHealth` is 2 in the scene. Game over comes on the **3rd** loss (2 → 1 → 0 → −1), so you have 2 spare hearts plus the ball in play. An Extra Ball reward gives +1 heart.

### Electric fences are the "ball loss targets"
- [C] **Which drains have them:** never on table 0. On tables 1 and up, each outlane fence rolls 25% and the centre fence at (0, −9) rolls 50%.
- [C] **When they trigger:** only on a ball moving down, and **never during multiball**. A bomb ball is ignored.
- [C] **What happens on touch:**
  1. the ball is frozen ("shocked") for 0.5 s;
  2. it is pushed back out at the entry velocity × (k, 0.1);
  3. **you lose a heart** (`PlayerManager.UpdateHealth(true)`);
  4. the fence switches off for 5 s.
- [C] **The ball is not drained:** it keeps playing on the same table.

### A drain with no fence
- [C] **Tables 1 and up:** the ball **drops into the table below at no cost**, with velocity × (0.5, 0.1) plus a random sideways push. The table below raises its centre exit blocker for 5 s on arrival.
- [C] **Table 0:** a drain costs a heart, and the ball is relaunched from the bottom of table 0 ("Ready… Go").
- [C] **Multiball:** an extra ball that falls out is simply removed, at no cost.

### Ball saver
- [C] There is no timed ball saver. The save-like mechanics are:
  - the 5 s gate when you fall into a table;
  - kickbacks always lit on table 0;
  - blocker rewards from goals (3–5 s);
  - the checkpoint, below.

### Checkpoint ("BlockedLevel")
- [C] **When it's set:** on returning from the bonus challenge, whether you won or not. It is set to that bonus table's id (9, 19, …).
- [C] **What it blocks:** tables at or below it get **permanent** centre and outlane blockers, so you can't fall back past the checkpoint. Fences still work there.
- [C] **How long it lasts:** a new game resets it. It is kept through a continue (up to 3 continues, which resume at the best table reached).

## 2. Every-10th-table bonus

`<Theme>_Bonus_Challenge` (every theme has exactly one) uses normal flippers and the usual fence and kickback rolls. Its layout:
- **Bash toy:** at (0, 4), with 5 visual stages. In Classic they spell D, DI, DIN, DINR, DINRE.
- **Hold holes:** two kick-out holes at (±8.99, 1.43). These are the "side targets". Each holds the ball for 1 s, then releases it diagonally up toward the toy at about 18.75 u/s.

How the challenge plays out [C]:
1. **Hitting the toy:** it kicks the ball and spawns a **minion**, a moving obstacle that orbits the toy. It does *not* advance the toy.
2. **Advancing the toy:** each capture in a side hole advances it one stage. **4 captures, in any order or hole,** reach the final stage, and a gate opens at the toy's base.
3. **Entering the boss table:** hit the open gate to teleport to `Challenge_<Theme>`, a separate boss mini-table.
4. **The boss:** it patrols ±6 units. It takes 5 hits (each hit kicks the ball at 15), then dies and scatters **15 coins** to collect.
5. **Leaving:** there's no timer. Draining out of the boss table returns you to the bonus table **with no penalty**. That sets the checkpoint and resets the toy to stage 0, so the challenge is repeatable.

[I] Stage progress is shared across all bonus tables, since there's only one challenge id.

## 3. Difficulty

There is **no numeric difficulty curve**: no speed, gravity, strength, fence-chance or event-count scaling by table index. What does vary by index is:
- **Table 0:** no fences, both kickbacks lit, short blocker rewards. It's the only table where a drain costs a heart.
- **Tables 0–3:** a reduced toy list.
- **Every 10th table:** the bonus challenge.
- **The checkpoint:** makes everything below it *safer*. It eases the game as you climb rather than ramping difficulty up.

[I] Difficulty therefore comes from the fence rolls (25 / 25 / 50% on every table from 1 up), the random layouts, and the 3-heart budget.
