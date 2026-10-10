# Infinity Pinball (2022): how it builds its endless tables, and its physics

**Sources:**
- `dump.cs` is `ip_out\dump\dump.cs` (Il2CppDumper). Line numbers cite the class declarations.
- "SR:line" means a line in `ip_out\cpp2il\types\Assembly-CSharp\method_dumps\SectionRandomizer_methods.txt`. Other classes use `<Class>_methods.txt:line`.
- Constants loaded from `.rodata` (`adrp`+`ldr`) were read directly from `ip_apk\lib\arm64-v8a\libil2cpp.so` at the virtual address shown (helper `scratchpad\ipm\elf.py`).
- Serialized values (spawn chances, grid sizes, prefab fields) come from the AssetRipper export `ip_export\ExportedProject\Assets\...`. That export has the real data. Its `.cs` files are empty stubs.
- **Cpp2IL caveat:** its high-level labels are often wrong. For example, it labels field 0x40 as `_sectionId`, and it labels `_currentEventNumberOnTable` as `_warpId`. Everything below was checked against the raw ARM64 code and the field offsets.

---

## 0. Summary

- **It mixes templates; it is not freeform.** Each "table" is a 20-unit-tall screen built from fixed pieces:
  - 1 background, drawn from 3.
  - A left and a right wall section, each drawn independently from 3 per theme. One side is mirrored.
  - A fixed flipper pair at fixed positions.
  - Fixed slots for the slingshots ("Spring"), lane blockers, the exit blocker, electric fences and outlane kickers. These slots come from the wall section's spawn map.
- On top of that it scatters 4–8 "objects" (bumpers, holes, spinner, event triggers and so on) onto a **12×12 grid of candidate points** in the open middle of the table. Each object is checked for overlap with `Physics2D.OverlapCircle/OverlapBox`, with up to 100 random tries.
- The only truly procedural geometry is the **rail**: an A* path on a random grid that spans 2–4 tables, rendered as a SpriteShape.
- It is "infinite" because tables are generated **lazily**: 10 at the start, then 5 more whenever the player gets within 5 tables of the last one generated. Tables are never regenerated during a run. Tables more than 5 away are only set inactive.
- **Seeding:**
  - One master seed per game: `UnityEngine.Random.Range(-80000, 80000)`.
  - One `System.Random(seed)` stream is shared by all tables, so table *N* depends on every table before it. A table is **not** seeded from its index.
  - A second stream with the same seed is used for rails.
  - Each placed object gets its own `new Random(MasterSeed)` (see §3.4).
- **Difficulty ramp:**
  - Tables 0–3 use a restricted "custom level": no warps, no rails, no spinners, no Block-Top event, no destroyable-bumper trigger.
  - Table 0 always has both outlane kickbacks and no electric fences.
  - Every 10th table (id 9, 19, 29, …) is a hand-made bonus/challenge table.
  - Otherwise the numbers stay flat. Object count and spawn chances do not grow with depth.

---

## 1. Data that drives the generator

### `TableDesignParameters` (dump.cs 319744)
All five shipped assets (`MonoBehaviour\* perams.asset`) contain **the same values**.

**Object spawn chances (%):**

| Warp | Hole (teleport pair) | LockBall (hold hole) | Rail | Spinner | Bumper | MovingBumper | ScoreBumper | Event |
|---|---|---|---|---|---|---|---|---|
| 3 | 15 | 2 | 55 | 2 | 85 | 65 | 35 | 24 |

**Table-element chances (%):**

| ElectricFenceOutlane | ElectricFenceCenter | SpringoutLane | ExtraFlipper |
|---|---|---|---|
| 25 | 50 | 100 | 45 |

**Event (reward) type chances (%):**

| SpeedLane | SlotMachine | ScoreMultiplier | BlockSideLanes | BlockBottom | BlockTop | Multiball | BombBall |
|---|---|---|---|---|---|---|---|
| 50 | 29 | 41 | 50 | 72 | 31 | 38 | 42 |

**Trigger type chances (%):**

| DestroyableBumper | BashToy | Rollover | DropTarget |
|---|---|---|---|
| 34 | 62 | 50 | 34 |

**`BonusTable`:** 9. This is **unused** by the code; bonus tables are fixed at every 10th table.

**`customLevel`:** a single entry, `LevelRange {0,3}`, with:
- `AllowBonusTable` 0.
- `RequiredEvents` empty.
- `AllowedEvents` = {SpeedLane, SlotMachine, ScoreMultiplier, BlockSideLanes, BlockBottom, MultiBall, BombBall}. BlockTop is excluded.
- `AllowedTriggers` = {BashToy, RollOver, DropTarget}. DestroyableBumper is excluded.
- `AllowedObjects` = {Hole, LockBall, Lane, Bumper, MovingBumper, ScoreBumper, Event}. Warp, Rail and Spinner are excluded.

Enums are at dump.cs 319690–319740.

### `TableData` per theme (dump.cs 319815)
For example `MonoBehaviour\Classic_0.asset`, which uses `newyork perams`:
- Prefab references for every element.
- `Backgrounds[3]`, `Flippers[2]` (L, R).
- `Sections[3]` of type `WallSectionElements` (dump.cs ~319882): `WallSection`, `Spring` (the slingshot prefab, `Classic_Bumper_Large/Small`), `LaneBlocker`, and `TableElementSpawnMap`.
- `BonusTables[1]`, `BossSection`, and `Layers`, the overlap mask (`531713`).

### `SectionRandomizer` scene values (`game.unity` ~9440) and code defaults (`.ctor`, SR:22321)

| Field | Value |
|---|---|
| `NumberOfTableForEachBatchRandom` | 10 in the scene; `InitializeParameters` also forces 10 |
| `MaxEventNumberPerTable` | 3 |
| `_minObjectNumber` / `_maxObjectNumber` | 4 / 8 |
| `_verticalPositionStep` | **20.0** (0x41A00000) |
| `LOCAL_LOW_FLIPPER_POSITION` | (2.95, −7.9) |
| `LOCAL_EXIT_BLOCKER_POSITION` | (0, −8) |
| `LOCAL_TOP_EXIT_BLOCKER_POSITION` | (0, 8.85) |
| `LOCAL_CENTER_FENCE_POSITION` | (0, −9) |

The four `LOCAL_*` vectors come from rodata 0x17FFB60 and 0x17FFB70.

Constants: `MAX_QUERY_PER_TABLE_ALLOWED_BEFORE_FORCE_EXIT` = 20 and `BONUS_TABLE_SPAWN_INTERVAL` = 10. The second one is hard-coded as `% 10` in `IsBonusTable`.

---

## 2. Generation pipeline (C#-style pseudocode reconstructed from the ARM64 code)

### 2.1 Start, seeding and batching

```csharp
void Awake() => InitializeParameters(CreateTable);                     // SR:75

void InitializeParameters(Action onFinish) {                             // SR:1289
    MasterSeed = UnityEngine.Random.Range(-80000, 80000);   // movz/movk 0xfffec780 / 0x13880
    _randCount = 0;
    _random     = new System.Random(MasterSeed);   // everything except rails
    _railRandom = new System.Random(MasterSeed);   // rails' Grid pathfinding
    _sectionId = 0;
    NumberOfTableForEachBatchRandom = 10;
    _tableParams = TableElements.TableParameters;
    _tableGridPositions = null; _railWaitingForCreation = null; _warp = null;
    _sections.Clear(); _rails.Clear(); _objectPlacementList.Clear();
    _objectNameOccurenceInTable.Clear(); _storedWarp.Clear(); _storedBonusTableIndex.Clear();
    OM.TaskManager.CleanFromThemeChange();
    _isReadyForNextBatch = true; _shouldCreateTableTillLastRailTableId = false;
    _hasSlotMachine = _hasScoreMultiplier = _isTableCenterOccupy = _hasWarp = false;
    _currentObjectNumberOnTable = 0; _isBonusTable = false;
    (_currentEventNumberOnTable, _warpId, _nextWarpSectionIndex, _nextRailTableId) = (0, 0, -1, -1); // rodata 0x17FFB50
    onFinish?.Invoke();
}
// MakeSeed() (SR:862) is the same Random.Range(-80000, 80000), stored in MasterSeed.

void CreateTable() => StartCoroutine(Randomize(() => {                  // SR:757, lambda SR:22639
    _isReadyForNextBatch = true; _shouldCreateTableTillLastRailTableId = false;
    NumberOfTableForEachBatchRandom = 5;               // every later batch is 5 tables
    if (_nextRailTableId >= _sectionId) {              // a rail ends in a table that doesn't exist yet
        _shouldCreateTableTillLastRailTableId = true;
        CreateTable();                                  // keep generating until the rail's end table exists
    }
}));
```

**Is it deterministic per table index? No.**
- `UnityEngine.Random` is seeded from the clock by Unity, so every new game (and every theme change, via `ChangeTableThemeToSelected` → `ReplaceTableWithNewTheme`) gets a new seed.
- Within one game, all tables draw from the single `_random` stream in order. Table *N*'s content therefore depends on how many draws tables 0..N−1 used, including retries.
- To make tables reproducible per index, you would seed a generator with `hash(MasterSeed, index)` per table. The game does not do that.

### 2.2 The `Randomize` coroutine

`SectionRandomizer--NestedType--_Randomize_d__55_methods.txt`, MoveNext at RVA 0x1232DC4.

```csharp
IEnumerator Randomize(Action onFinish) {
    _isReadyForNextBatch = false;
    if (_shouldCreateTableTillLastRailTableId)
        NumberOfTableForEachBatchRandom = _nextRailTableId - _sectionId + 1;
    for (int i = 0; i < NumberOfTableForEachBatchRandom; i++) {
        CreateRootTable();                               // walls, flippers, fixed elements, rail/warp/teleport, events
        if (_isBonusTable) {
            CheckForWarpValidTableIndex();               // cancel a pending warp: warps may not cross a bonus table
            _sectionId++;
            yield return null; continue;
        }
        _random.Next(_minObjectNumber, _maxObjectNumber + 1);   // result is DISCARDED (dead code; it only advances the RNG)
        var methods = GetObjectMethodsList(GetCustomLevelParamters().AllowedObjects);
        Shuffle(methods);                                // Fisher-Yates using _random
        for (int pass = 0; pass < 20; pass++) {          // MAX_QUERY_PER_TABLE_ALLOWED_BEFORE_FORCE_EXIT
            foreach (var create in methods) {
                create();                                // each one rolls its own % chance
                if (_currentObjectNumberOnTable >= _maxObjectNumber) break;  // 8
            }
        }   // note: the outer loop never exits early; once the table is full it still calls one creator per pass
        foreach (var op in _objectPlacementList) if (op) op.SetInitialColliderSize();   // drop the temporary placement margins
        _shouldForceEvaluateAllPoints = false;           // never set true anywhere: a dead feature
        _sectionId++;
        _objectPlacementList.Clear(); _objectNameOccurenceInTable.Clear();
        _currentObjectNumberOnTable = 0; _currentEventNumberOnTable = 0;
        yield return null;                               // one table per frame
    }
    _storedBonusTableIndex.Clear();
    onFinish?.Invoke();
}
```

**How many objects end up on a table:**
- The real target is `_maxObjectNumber` (8). The count includes events and rails/warps/teleports created earlier in `CreateTableElements`.
- In practice the count is bounded by:
  - the per-object % rolls,
  - `MaxObjectAllowedPerTable` on each prefab,
  - how much free grid space is left,
  - 20 passes over a list of about 6 creators.
- `_minObjectNumber` is never enforced. A table may end up nearly empty if the rolls fail.

### 2.3 Creating one table: `CreateRootTable` (SR:2966) and `IsBonusTable` (SR:3415)

```csharp
bool IsBonusTable() => _sectionId != 0 && (_sectionId + 1) % 10 == 0;   // ids 9, 19, 29, ...

void CreateRootTable() {
    _currentRoot = new GameObject(); _currentRoot.transform.parent = RootNode;
    _currentRoot.transform.position = new Vector3(0, _sectionId * _verticalPositionStep /*20*/, 0);
    if (IsBonusTable()) {
        _currentRoot.name = "BonusTable_" + _sectionId;
        _sections.Add(_sectionId, _currentRoot.AddComponent<BonusSectionController>() { SectionId = _sectionId });
        CreateBonusTableElements();
        _storedBonusTableIndex.Add(_sectionId);
        _isBonusTable = true;
    } else {
        _currentRoot.name = "Table_" + _sectionId;
        _sections.Add(_sectionId, _currentRoot.AddComponent<SectionController>() { SectionId = _sectionId });
        CreateTableElements();
        _isBonusTable = false;
    }
}

void CreateBonusTableElements() {                                         // SR:3474
    int k = _random.Next(0, TableElements.BonusTables.Length);           // Classic has 1 bonus prefab
    var go = Instantiate(TableElements.BonusTables[k], _currentRoot.transform);
    go.GetComponent<BonusElements>().CreateTableElement(k);   // places bash toy, 2 hold holes, outlane springs, fences from its own spawn map
    CreateTableFlippers();
    ValidateRailCreation();
}
```

### 2.4 Fixed structure of a normal table: `CreateTableElements` (SR:3683)

```csharp
void CreateTableElements() {
    WallSectionElements[] pool;
    if (_sectionId == 0)  // first table: only wall sections whose spawn map has an OutlaneSpring point (Entity==10)
        pool = TableElements.Sections.Where(s => s.TableElementSpawnMap
                   .GetComponentsInChildren<SpawnPoint>().Any(p => p.Entity == OutlaneSpring)).ToArray();
    else pool = TableElements.Sections;
    var left  = pool[_random.Next(pool.Length)];    // left and right are chosen INDEPENDENTLY (they may be the same)
    var right = pool[_random.Next(pool.Length)];

    CreateBackground();                    // random Backgrounds[i]; its TableGridPositions becomes _tableGridPositions
    CreateWallWithSpawnMap(left, right);
    CreateTableSpring(left, right);        // slingshots
    CreateTableFlippers();
    CreateTableBlockers();
    CreateElectricFence();
    CreateOutlaneSpring();
    CreateExtraFlipper();

    var allowed = GetCustomLevelParamters().AllowedObjects;
    if (allowed == null) { CreateRail(); CreateWarp(); CreateTeleport(); }
    else {
        if (allowed.Contains(_Rail)) CreateRail();
        if (allowed.Contains(_Warp)) CreateWarp();
        if (allowed.Contains(_Hole)) CreateTeleport();
    }
    ValidateRailCreation();
    _isTableCenterOccupy = false;
    InitializeRewardsForTable();           // events/goals; these also count as objects
    // The random objects are added afterwards by Randomize() (2.2)
}
```

**Order matters: it is a priority system.**
1. Fixed elements claim space first.
2. Then rail, warp and teleport.
3. Then event triggers and reward objects.
4. Then bumpers and the rest fill the leftover grid.

**Spawn chances and the order they are rolled in.** Each `_random.Next(100) < chance` roll uses the shared stream:

| Element | Function | Rule |
|---|---|---|
| Background | `CreateBackground` (SR:4254) | `Backgrounds[_random.Next(3)]`. Its `TableGridPositions` is registered with the SectionController. |
| Walls | `CreateWallWithSpawnMap` (SR:4482) | Left wall instance gets `localScale (-1,1,0)`, i.e. it is mirrored. Each side's `TableElementSpawnMap` is instantiated. The right one gets `SpawnContainer.MirrorPosition()`, which negates the x of every SpawnPoint. Both containers are registered. |
| Slingshots | `CreateTableSpring` (SR:4832) | `section.Spring` on each side at `SpawnContainer.GetSpringLocation()`. The left one is mirrored. Each is added to the placement list, and grid points within its `ObjectPlacement.Radius` are removed. |
| Flippers | `CreateTableFlippers` (SR:5348) | Always `Flippers[0]` at (−2.95, −7.9) and `Flippers[1]` at (+2.95, −7.9). |
| Blockers | `CreateTableBlockers` (SR:5765) | `LaneBlocker` at each container's LaneBlocker point, and `ExitBlocker` at (0, −8). They start inactive; the reward events enable them. |
| Electric fences | `CreateElectricFence` (SR:6314) | None on table 0. Otherwise three independent rolls: left outlane fence 25%, right outlane fence 25%, centre fence at (0, −9) 50%. |
| Outlane kickers | `CreateOutlaneSpring` (SR:6843) | First a global roll: if `sectionId != 0` and the `SpringoutLane` roll (100%) fails, there are none. Then per side: if the spawn map has an outlane point (≠ Vector2.zero) and (`sectionId == 0` **or** `Next(100) <= 49`), place one. **Table 0 always gets both.** Later tables get each with about 50%. |
| Extra flipper | `CreateExtraFlipper` (SR:7258) | Per side, if the container has a free `ExtraFlipper` SpawnPoint and the roll passes (45%): `Flippers[side]` at the **first** free point. That point is marked `HasElement`, and grid points around it are removed. |

**Wall spawn-map slots** (left-side local coordinates; `WallSection_TableElements_1..3.prefab`):

| Map | Spring | LaneBlocker | OutlaneSpring | Fence | ExtraFlipper |
|---|---|---|---|---|---|
| 1 | (−4.0, −3.5) | (−7.57, −1.81) | (−7.69, −4.06) | (−5.26, −7.44) | (−5.94, 0.73) |
| 2 | (−5.0, −3.5) | (−8.53, −2.95) | (−8.56, −4.27) | (−5.61, −8.08) | – |
| 3 | (−4.51, −3.84) | (−7.34, −3.59) | **none**, so never used on table 0 | (−5.09, −8.03) | (−5.32, −0.66) |

### 2.5 Which creators are used: `GetCustomLevelParamters` (SR:1789) and `GetObjectMethodsList` (SR:1984)

```csharp
CustomLevel GetCustomLevelParamters() {
    foreach (var lvl in _tableParams.customLevel)
        if (_sectionId >= lvl.LevelRange.x && _sectionId <= lvl.LevelRange.y) return lvl;   // IsInRange
    return new CustomLevel { AllowBonusTable = true };   // all arrays null => "everything allowed"
}

List<Action> GetObjectMethodsList(CustomTableObjectTypes[] objects) {
    var list = new List<Action>();
    if (objects == null) {   // default list for tables >= 4
        list.Add(CreateSimpleBumper); list.Add(CreateLockHole);
        list.Add(CreateMovingBumper); list.Add(CreateMovingBumper);   // added TWICE: two shots per pass
        list.Add(CreateBumperVariableScore); list.Add(CreateSpinner);
        return list;
    }
    foreach (var t in objects) switch (t) {   // jump table at rodata 0x17FFB87
        case _LockBall:     list.Add(CreateLockHole); break;
        case _Spinner:      list.Add(CreateSpinner); break;
        case _Bumper:       list.Add(CreateSimpleBumper); break;
        case _MovingBumper: list.Add(CreateMovingBumper); break;
        case _ScoreBumper:  list.Add(CreateBumperVariableScore); break;
        // _Rail, _Lane: nothing here (rails are made in CreateTableElements; lanes only by RollOver events)
        // _Warp, _Hole, _Event: handled in CreateTableElements / InitializeRewardsForTable
    }
    return list;
}
bool HasEventObject() => allowed == null || allowed.Contains(_Event);   // SR:2706
```

### 2.6 A typical object creator

`CreateSimpleBumper` (SR:8304). `CreateMovingBumper`, `CreateBumperVariableScore`, `CreateLockHole` and `CreateSpinner` are the same apart from the noted extras.

```csharp
void CreateSimpleBumper() {
    if (_random.Next(100) >= _tableParams.Bumper) return;            // IsPercentageOverRandomValue, inlined
    var prefab = TableElements.SimpleBumpers[_random.Next(SimpleBumpers.Length)];
    var op = prefab.GetComponent<ObjectPlacement>();
    if (!IsAllowedToSpawn(prefab, op)) return;                        // per-table cap
    var go = Instantiate(prefab, _currentRoot.transform);
    if (!GetPositionOnTable(go)) return;                              // Destroy(go) is done inside on failure
    go.GetComponent<Bumper>().Init();
    _currentObjectNumberOnTable++;
    if (op.MaxObjectAllowedPerTable != 0) _objectNameOccurenceInTable.Add(prefab.name);
}
bool IsPercentageOverRandomValue(int p) => _random.Next(100) < p;      // SR:21087
bool IsAllowedToSpawn(GameObject prefab, ObjectPlacement op) =>       // SR:22104
    op.MaxObjectAllowedPerTable == 0 /*unlimited*/ ||
    _objectNameOccurenceInTable.Count(n => n == prefab.name) < op.MaxObjectAllowedPerTable;
```

Extras:
- **Moving bumper** also calls `Bumper.SetDirectionPath()`.
- **Score bumper** calls `SetScore()` with a random entry from `BumperScoreRange.ScoreRangeCollection`.
- **LockHole** uses `TableData.Hole`.
- **Spinner** uses `TableData.Spinner`.

### 2.7 Positions: the grid plus overlap test

**The grid** is `TableGridPositions` on the background prefab (`TableGridPositions_methods.txt`).
- `Awake` → `CreateTablePoint` builds `Width × Height = 12 × 12` points at the **cell centres** of the GameObject's `BoxCollider2D` bounds.
- Every theme's `*_BG_*.prefab` uses size 18×12 with offset (0, 2), measured from the table centre. That gives:
  - x ∈ {−8.25, −6.75, …, +8.25}, spacing 1.5;
  - y ∈ {−3.5, …, +7.5}, spacing 1.0.
- **Nothing is ever placed in the bottom 6.5 units (the flipper and inlane area) or the top 1.5 units by the random scatter.**

```csharp
bool GetPositionOnTable(GameObject inst) {                             // SR:21619
    var op = inst.GetComponent<ObjectPlacement>();
    bool ok = _shouldForceEvaluateAllPoints ? op.EvaluateAllPointOnGrid(_tableGridPositions)   // exhaustive scan (never used)
                                            : op.FindPosition(_tableGridPositions, _random);
    if (!ok) { Destroy(inst); return false; }
    inst.transform.position = op.FoundPosition;   // (x, y, 0); OffsetPosition is used only for the overlap probe
    _objectPlacementList.Add(op);
    return true;
}

// ObjectPlacement.FindPosition(grid, rand) -- ObjectPlacement_methods.txt:607 (RVA 0x1453104)
bool FindPosition(TableGridPositions grid, Random ignored) {
    if (m_Rand == null) m_Rand = new System.Random(OM.SectionRandomizer.MasterSeed);   // SetRandomWithSeed
    if (CreateCollider) KeepColliderValueAsGizmoValue = false;
    if (ForceCenteredOnTable) {   // ForceToTableCenter
        FoundPosition = new Vector2(0, grid.transform.parent.position.y + 2f);
        SetCollider(); return true;
    }
    for (int q = 100; q > 0; q--) {   // MaxQueryNumber = 100
        var p = grid.Points[m_Rand.Next(grid.Points.Count)].Position;
        float x = CenterOnXAxis ? 0 : p.x;
        if (x > -1 && x < 1 && DoNotPlaceInCenterX) x += (x > 0 ? 1.5f : -1.5f);   // push off the centre line
        var probe = new Vector2(x + OffsetPosition.x, p.y + OffsetPosition.y);
        bool free = UseBox ? Physics2D.OverlapBox(probe, Size, 0, Layers) == null
                           : Physics2D.OverlapCircle(probe, Radius, Layers) == null;
        if (free) {
            FoundPosition = new Vector2(x, p.y);
            SetCollider();   // enable the (margin-sized) placement collider so later probes see it
            if (!UseBox) grid.RemovePointInsideCircleMargin(this, FoundPosition);   // delete grid points within Radius
            return true;
        }
    }
    return false;
}
```

**Quirk in the per-object RNG.** The `Random` passed in is ignored. Each freshly instantiated object makes its own `new Random(MasterSeed)`, so every object starts the same index sequence.
- Variety comes only from the grid shrinking as points are removed, and from collisions.
- If you copy this, use the shared stream instead.

**Spacing comes from three things:**
- Each prefab's `ObjectPlacement.Radius` or `Size`. These are inflated "margin" colliders while the table is being placed, then `SetInitialColliderSize()` shrinks them back to the real collider at the end of the table.
- Physics overlap against everything already placed: walls, slingshots, flippers, earlier objects, and "strip" blockers. `Layers` comes from `TableData.Layers`.
- Removal of grid points within the radius.

#### Distance-checked variant
`GetPositionOnTableWithDistanceCheck(inst, fromPosition, verticalOffset, minDistance)` is at SR:21867. It calls `ObjectPlacement.FindPosition(grid, rand, source, offsetX, wantedDistance)` (ObjectPlacement_methods.txt:1055):

```csharp
for (q = 100; q > 0; q--) {
    p = grid.Points[m_Rand.Next(count)].Position;
    if (Vector2.Distance(p, source) < wantedDistance) continue;          // minimum distance
    x = p.x; if (|x| < 1 && DoNotPlaceInCenterX) x ± 1.5;
    if (x > source.x - Radius && x < source.x + Radius) continue;       // ShouldOffsetFromSourcePosition (inlined):
                                                                         // must not share the source's column (±Radius)
    overlap test as above → FoundPosition, SetCollider, remove grid points
}
```

- In the code that shipped, the `offsetX` argument is **not read**. The column-exclusion width is the object's own `Radius`.
- There is no `CenterOnXAxis` handling in this variant.
- The only caller is the teleporter pair, which passes `verticalOffset = 2.5` (unused) and `minDistance = 0`.

### 2.8 Rails, warps and teleporters (links between tables)

#### Rail (`CreateRail` SR:12052, `ValidateRailCreation` SR:6053, `Grid` dump.cs 319161)

```csharp
void CreateRail() {
    if (_sectionId <= _nextRailTableId) return;            // only one rail in flight at a time
    if (_random.Next(100) >= _tableParams.Rail) return;   // 55% (from table 4 on; tables 0-3 disallow rails)
    double d = _random.NextDouble();
    bool down = d <= 0.30000001;                          // rodata 0x17FFAC8
    int span = _random.Next(2, down ? 2 : 5);             // 30%: span 2 (and reversed); 70%: span 2..4 tables
    _nextRailTableId = _sectionId + span - 1;
    var rail = Instantiate(TableElements.Rail);           // world-space, not parented
    rail.GetComponent<Grid>().CreatePath(_railRandom, _sectionId, span, reverse: down);
    _railWaitingForCreation = rail.GetComponent<Rail>();
    _currentObjectNumberOnTable++; _rails.Add(rail);
}
```

`Grid.CreatePath` (Grid_methods.txt:3) and the prefab `Classic_SampleRail_Random`:
- The grid has `Width 8` columns across `BoundWidth 22`, and `HeightRowDivisionFactor 7` × span rows. `kVerticalSectionSpacing` = 20.
- `GenerateGrid` makes each node walkable with probability `m_WalkableNodePercentage` = **80%**.
- **Start node:** a random column in the left half (`Next(0, W/2+1)`), row `Next(4, 6)`. The cells around it are forced walkable.
- **End node:** a mirrored column on the right (`W−1−Next(1, W/2+1)`), row `Height − Next(2, 4)`.
- `reverse` swaps start and end, making a downhill rail. `Rail.StartSection` and `EndSection` are set.
- `SolvePath` runs A* (`Pathfind`, `GetNeighborNodes`, `ReconstructPath`). The path goes to `RandomShape.CreateRail(path, …)`, which builds a SpriteShape ramp with entry and exit ramps.
- If no path is found, the rail object is destroyed.
- `RailPatternData` (a hand-authored L/R/U/D pattern list, dump.cs ~319441) exists but is **never used** at runtime.

```csharp
void ValidateRailCreation() {   // runs after every table's fixed elements
    if (_railWaitingForCreation == null || _nextRailTableId != _sectionId) return;   // wait until the end table exists
    for (int t = Math.Min(rail.StartSection, rail.EndSection); t < _nextRailTableId; t++)
        if (_storedBonusTableIndex.Contains(t)) { Destroy(rail.gameObject); return; }   // rails can't cross bonus tables
    if (!rail.GetComponent<Grid>().CheckForOverlap(includeRamp: true))   // = !RandomShape.IsRampOverlap():
        Destroy(rail.gameObject);   // every ramp end's ObjectPlacement must fit (OverlapCircle == null)
}
```

`Rail` runtime behaviour (dump.cs 314804; `RequiredVelocity 0.1`, `Speed 10`): when the ball enters faster than 0.1, it becomes kinematic and follows the path at 10 u/s (`FollowPath`). Otherwise it rolls back out (`RollOut`).

#### Warp (`CreateWarp` SR:10932, `CheckForWarpValidTableIndex` SR:11749, `Warp` dump.cs 315594)

```csharp
void CreateWarp() {
    bool isExit = _nextWarpSectionIndex == _sectionId;
    if (!isExit && _random.Next(100) >= _tableParams.Warp) return;    // 3% (tables >= 4)
    var prefab = isExit ? TableElements.WarpDown : TableElements.Warp;
    if (!IsAllowedToSpawn(prefab, op)) return;
    var go = Instantiate(prefab, _currentRoot.transform);
    if (!GetPositionOnTable(go)) {
        if (isExit) {   // couldn't fit the exit: delete the matching entrance
            foreach (var w in _storedWarp) if (w && w.Id == _warpId) { w.DeregisterFromSectionController(); Destroy(w.gameObject); _nextWarpSectionIndex = -1; }
        }
        return;
    }
    var warp = go.GetComponent<Warp>(); warp.Id = _warpId; _hasWarp = true;
    if (_nextWarpSectionIndex < 0) {   // new entrance
        _warpId = _sectionId + 100;
        _nextWarpSectionIndex = _sectionId + _random.Next(1, 4);     // exit 1-3 tables higher
        _warp = warp; warp.Id = _warpId; warp.ExitTableIndex = _nextWarpSectionIndex; _storedWarp.Add(warp);
    } else if (isExit) { _nextWarpSectionIndex = -1; warp.Init(); }
    CreateStripOverlap(go, new Vector2(1.2f, 20f), name);   // rodata 0x17FFB04 = 1.2: reserve a 1.2-wide, full-height column
    _currentObjectNumberOnTable++;
    if (op.MaxObjectAllowedPerTable != 0) _objectNameOccurenceInTable.Add(prefab.name);
}
// CheckForWarpValidTableIndex (bonus tables only): if a warp exit is pending (_nextWarpSectionIndex >= 1),
// destroy the entrance with _warpId and reset to -1. Warps never span a bonus table.
```

`CreateStripOverlap(instance, size, name)` (SR:12622):
- Creates an empty object at `(instance.localPosition.x, 0)` under the table root.
- Adds an `ObjectPlacement.CreateBox(size)` on the table layer mask.
- The result is an invisible 1.2 × 20 column that **later objects cannot overlap**, keeping the vertical travel line above and below the warp or hole clear.

#### Teleporter pair (`CreateTeleport` SR:9706; "Hole" in the parameters, prefab `Classic_HoleDoor`)

```csharp
int roll = _random.Next(100);
if (_hasWarp) { _hasWarp = false; return; }   // never a teleporter on a table that has a warp
if (roll >= _tableParams.Hole) return;        // 15%
if (!IsAllowedToSpawn(prefab)) return;
var a = Instantiate(Teleport); a.Teleporter.Id = _sectionId; bool okA = GetPositionOnTable(a);
var b = Instantiate(Teleport); b.Teleporter.Id = _sectionId;
bool okB = GetPositionOnTableWithDistanceCheck(b, a.position, 2.5f, 0f);   // different column from a
if (okA && okB) { foreach (go in {a, b}) CreateStripOverlap(go, (1.2, 20), name); _currentObjectNumberOnTable++; ... }
else foreach (go in placed) Destroy(go);      // all-or-nothing
```

### 2.9 Events, rewards and goals: what gives a table its objectives

**Model.** An event pairs a trigger object with a `TaskReward` (enum at dump.cs 318921).
- Triggers: BashToy, DestroyableBumper, RollOver lane group, or DropTarget group.
- Completing the trigger fires the reward through `TaskEvent.listener`, and the reward is registered with `SectionController.RegisterTableEvent`.
- Some rewards also spawn a physical reward object.

**Event type → TaskReward** (`GetTaskRewardFromEventType` SR:19185, table at rodata 0x17FFC10):

| Event type | TaskReward |
|---|---|
| SpeedLane | SpeedLane (15) |
| SlotMachine | SpinTumbler (9) |
| ScoreMultiplier | ScoreMultiplier (8) |
| BlockSideLanes | OutlaneBlocker (2) |
| BlockBottom | ExitBlocker (1) |
| BlockTop | CloseTopExit (7) |
| MultiBall | Multiball (4) |
| BombBall | BombBall (14) |

**Trigger type → creator** (`GetTriggerEventMethods` SR:19232):
- DestroyableBumper → `CreateDestroyableBumper`
- BashToy → `CreateBashToy`
- RollOver → `CreateRollOverTarget`
- DropTarget → `CreateHorizontalDropTarget`

```csharp
void InitializeRewardsForTable() {                                   // SR:17910
    _maxEventAllowed = _random.Next(MaxEventNumberPerTable /*3*/) + 1;   // 1..3 events max
    var rewards = GetRewardFromAllowedEventsAndChancePercentage();   // each allowed event type rolled independently
    if (rewards.Count == 0) return;
    var center = new List<TaskReward>();
    for (int i = 0; i < rewards.Count; i++)
        if (rewards[i] is ScoreMultiplier or SpinTumbler or SpeedLane) { center.Add(rewards[i]); rewards.RemoveAt(i); }  // (i++ after RemoveAt skips the next item: a bug)
    CreateRequiredEvent();                                           // CustomLevel.RequiredEvents, forced (none shipped)
    if (HasEventObject() && _random.Next(100) < _tableParams.Event /*24*/) {
        CreateEvent(center);   // centre-occupying rewards get first pick
        CreateEvent(rewards);
    }
}
List<TaskReward> GetRewardFromAllowedEventsAndChancePercentage() {   // SR:18253
    var types = GetCustomLevelParamters().AllowedEvents ?? AllEightTypes;
    return types.Where(t => _random.Next(100) < chance[t]).Select(GetTaskRewardFromEventType).ToList();
}
void CreateEvent(List<TaskReward> rewards) { foreach (var r in rewards) SetRewardForEventTriggerObjects(r); }
void SetRewardForEventTriggerObjects(TaskReward r) {                 // SR:20256
    var triggers = GetCustomLevelParamters().AllowedTriggers ?? {DestroyableBumper, BashToy, RollOver, DropTarget};
    foreach (var t in triggers) GetTriggerEventMethods(t)(r, forceCreate: false);   // each trigger tries in turn
}
// Typical trigger creator, CreateBashToy (SR:13480); the other three follow the same pattern:
void CreateBashToy(TaskReward reward, bool forceCreate) {
    if (_currentEventNumberOnTable >= _maxEventAllowed) return;
    if (!forceCreate) {
        if (_random.Next(100) >= _tableParams.BashToy) return;      // 62%
        if (sectionController.IsEventAssigned(reward)) return;      // one trigger per reward type per table
    }
    if (!IsCenterRewardObjectAllowed(reward)) return;   // inlined: ScoreMult/SpinTumbler/SpeedLane need a free centre
    if (!IsAllowedToSpawn(prefab)) return;
    CreateRewardObjectFromSelectedEvent(reward, out GameObject[] rewardObjs);
    var go = Instantiate(BashToy); if (!GetPositionOnTable(go)) { foreach (o in rewardObjs) Destroy(o); return; }
    SetEventToEntity(go, reward);   // TaskEvent.listener = reward; SectionController.RegisterTableEvent(reward)
    _currentObjectNumberOnTable++; _currentEventNumberOnTable++;
}
```

**Trigger shapes:**
- **RollOver:** `n = _random.Next(0, 4)` lanes. `CreateLane` builds a "LaneGroup" box `ObjectPlacement` on layer "wall" that spans n × lane width plus `GroupSpacing`. It is placed on the grid, then the lanes and rollover targets are laid out inside it, and `SetEventToGroupEntity` is called.
- **DropTarget:** `count = _random.Next(1, 4)`.
  - 1 gives a single target.
  - 2–3 gives a "DropTargetGroup" box with targets spaced by `GroupSpacing`, registered as a drop-target group.
- **DestroyableBumper:** a breakable bumper plus `Bumper.Init`.

**Reward objects** (`CreateRewardObjectFromSelectedEvent` SR:19612, jump table at rodata 0x17FFB8E):

| Reward | Object created |
|---|---|
| Multiball | `Multiball` container at local (0, 9), above the playfield top |
| CloseTopExit | `TopExitBlocker` at (0, 8.85) |
| ScoreMultiplier | `CreateScoreMultiplier()` |
| SpinTumbler | `CreateRoulette()`, the slot machine |
| SpeedLane | `CreateSpeedLane()` |
| BombBall | `BombBall` container at (0, 9) plus `FlipperLock` at a static default position (likely Vector2.zero) |
| ExitBlocker, OutlaneBlocker | No object; they toggle the blockers created in `CreateTableBlockers` |

**Centre-occupancy rule** (`IsCenterRewardObjectAllowed` SR:22267, mask 0x8300):
- ScoreMultiplier, SpinTumbler (slot machine) and SpeedLane are "centre" objects. Their `ObjectPlacement` is centred.
- `CreateRoulette`, `CreateScoreMultiplier` and `CreateSpeedLane` refuse to spawn if `_isTableCenterOccupy` is set, and set it after spawning.
- Result: **at most one centre feature per table.**
- `CreateTableElements` resets the flag per table, and centre rewards are processed first.

**What gives a table goals:**
- The baseline goal is always "get the ball off the top" (section 2.10).
- In shipped data, about 24% of tables (after the `Event` roll, and only where triggers were placed) also get 1–3 trigger→reward objectives.
- Rewards change the table: blockers that save the ball, multiball, score multiplier, slot machine, speed lane, bomb ball, top-exit blocker.

### 2.10 Moving up and down: lazy generation, culling and no regeneration

**Table change** is detected by the ball (`Ball.TrackBallPosition`, see the physics section): y > 20·id + 10 means up, y < 20·id − 10 means down. `TaskManager.TableChange(bool isUp)` then fires, and `GameEventManager._currentTableSectionId` updates.

```csharp
void SectionRandomizer.OnTableChange(bool isUp) {                    // SR:2794
    if (isUp && _sectionId - GameEventManager._currentTableSectionId <= 5 && _isReadyForNextBatch)
        StartCoroutine(Randomize(() => _isReadyForNextBatch = true));   // +5 tables, one per frame
}
```

**`SectionController.OnTableChange(isUp)`** (SectionController_methods.txt:3939):
- `m_IsActive = (SectionId == current)`.
- The newly active table runs `ResetAllEntitiesInSection` and `ResetAllTableStateEntityInSection`. Bumpers, targets and events reset whenever you return to a table. Inactive tables run `DeactivateAllEntitiesInSection`.
- **Falling down** into a table (`!isUp`) activates its `ExitBlockerRewardEvent.ActivateBlocker(5.0f)`: a 5-second centre-drain save gate.
- If `SectionId <= GameEventManager.BlockedLevel` (a persisted "blockedlevel" checkpoint), its exit and outlane blockers are activated permanently.

**Culling** (`BaseSectionController`, `m_TableVisibilityRange = 5`, set in `.ctor`):
- `CullTable` and `ResetTableVisibility` keep a table's GameObject active only while |SectionId − current| ≤ 5.
- `CheckForInBetweenDeactivatedTable` re-enables any tables in range that were skipped, e.g. after a warp.
- Tables are **never destroyed or regenerated** during a run. Going down revisits the exact same layout.
- Everything is destroyed only on a theme change (`ReplaceTableWithNewTheme`) or a new game.

**Bonus and boss tables:**
- `BonusSectionController` (dump.cs ~320880) runs ids 9, 19, …
- `BonusElements.CreateTableElement` (BonusElements_methods.txt:3) places a `BonusBashtoy`, two `BonusHoldHole`s (one mirrored), outlane springs and fences from the bonus prefab's own spawn map.
- The bonus table hosts a "challenge". `BossSectionController` (dump.cs 313069) uses `OnBossEvent`, `StartChallenge`, the `Teleport` and `MoveBackToTable` coroutines and a `Timer`. It teleports the ball to a separate boss/mini-game area (`TableData.BossSection`: Wall, Background, Boss, SpawnMap) and back.
- I traced this part only at the call level, not in full.

---

## 3. Supporting classes

| Class | dump.cs | What it does |
|---|---|---|
| `SectionController : BaseSectionController` | 320901 / 321030 | One per table, holding `SectionId`, entity lists, spawn containers, grid, drop-target groups, held balls, balls and `m_TableEvents`. `IsEventAssigned(reward)` stops two triggers for the same reward on one table. `RandomizeCoins` and `CoinRandomizer` scatter coins when the table becomes active. `OnGameStateChanged` handles new game / continue (reset held balls, coins). |
| `SpawnContainer` / `SpawnPoint` | 320711 / 320773 | Hand-placed slots on each wall section's `TableElementSpawnMap`. `EntityType` values: Multiple, LaneBlocker, ExitBlocker, Flipper, Spring, Bumper, Teleport, DropTarget, ExtraFlipper, Fence, OutlaneSpring, Bashtoy. `GetSpawnLocationForType` returns the first matching point's local position and marks it `HasElement`, or Vector2.zero if none. `GetFreeSpawnListForEntityType` returns points of that type with `IsFree`. `MirrorPosition` negates x on every point (SpawnPoint.ChangePosition). |
| `TableGridPositions` | ~320817 | 12×12 candidate grid from a BoxCollider2D. `RemovePointInsideCircleMargin(op, centre)` marks points within `op.Radius` and `DeletePoints` compacts the list. `RemovePointInsideRectangleMargin` does the same using `op.Bound`. |
| `ObjectPlacement` | 314590 | Per-prefab placement rules: `Radius`, `Size`, `OffsetPosition`, `CenterOnXAxis`, `ForceCenteredOnTable` (centre at y+2), `DoNotPlaceInCenterX` (±1.5 push), `UseBox`, `MaxObjectAllowedPerTable` (0 = unlimited), `Layers`, `KeepColliderValueAsGizmoValue` / `CreateCollider` (temporary margin collider), `GroupSpacing`. Up to 100 tries per placement (`MaxQueryNumber`). `SetInitialColliderSize` restores the real collider. |
| `Rail`, `Grid`, `RandomShape` | 314804 / 319161 / 320085 | Procedural ramp: A* path, then SpriteShape. Validated when the end table is built. |
| `Warp` | 315594 | `Id` (= sectionId + 100), `ExitTableIndex`. The entrance on table s links to a `WarpDown` exit on table s + 1..3. On teleport the ball keeps its entry velocity. |
| `Teleporter` | 315330 | In-table hole pair sharing `Id = sectionId`. |
| `TaskReward` / `TaskRewardListener` | 318921 / 317181 | Reward enum and listeners: ExitBlocker, OutlaneBlocker, SpeedLane, SpinTumbler, CoinShower, Multiball and so on (`*RewardEvent` classes). |

---

## 4. Physics (summary of the subagent analysis; details are in its report)

Everything runs on **stock Unity 2D physics (Box2D)**.
- Gravity is (0, −9.81). The ball's `gravityScale` is 3.5, so it falls at **34.3 u/s²**.
- Physics runs at **50 Hz** (fixed step 0.02), with 8 velocity / 3 position iterations.
- **No PhysicsMaterial2D** is set on anything solid, so collisions use Unity's defaults: friction 0.4, **bounciness 0**. Walls absorb all normal velocity.
- There is no speed clamp, no spin code and no tilt or nudge.

**Ball** (`Ball`, dump.cs 313406; `Ball_Classic.prefab`):
- Body: mass 0.8, radius 0.6, Continuous collision detection.
- **Launch** (no plunger): an impulse (±0.05–0.15 × 20, 20) gives Δv ≈ (±1.25…3.75, 25) u/s straight up. Flippers are non-solid (layer-ignore) until the ball's vy ≤ 0.01.
- **Stuck ball:** if |v| < 0.01 for 5 s, it respawns.
- **Falling into the table below:** v = (0.5·vx, 0.1·vy) plus a random sideways impulse of ±2. Falling below table 0 means a drain.

**Flippers** (`flipper`, dump.cs 314277):
- Each flipper is a kinematic root with a `HingeJoint2D` driving a dynamic 3-kg capsule body (2.86 × 0.78).
- Motor speed ±**850°/s**, max motor torque 10000, limits ±22.5° (a 45° stroke). The return uses the same speed.
- When held at the top, the body's rotation is frozen so it acts like a wall.
- **No flipper boost:** shot speed comes purely from contact with the moving body (restitution 0). Estimated tip speed ≈ 7–36 u/s.

**Kickers** (pop bumper `Bumper`/`BumperBase`, slingshot / outlane `Spring`, `BumperVariableScore`, bash toy, minion):

```
ball.velocity = 0; ball.AddForce(-contact.normal * Strength * (1 ± 0.05·rand), Impulse)
```

The exit speed is fixed and does not depend on the incoming speed:

| Kicker | Strength | Exit speed |
|---|---|---|
| Bumper | 15 | 18.75 u/s |
| Slingshot (kicking edge only) | 10 | 12.5 u/s |
| Outlane kickback | 20 | 25 u/s |
| Minion | 5 | 6.25 u/s |

There is no cooldown.

**Other ball handlers:**
- **ElectricFence:** locks the ball 0.5 s, then releases it at (0.5·vx, 0.1·vy) of its entry velocity, costing one health.
- **HoldHole:** pops the ball out gently, Δv ≈ (±0.9–2.5, 2.5).
- **Teleporter / Warp:** keep the entry velocity.
- **Rail:** carries the ball at 10 u/s and releases it at v = 0 (inferred).
- **SpinnerPole:** orbits the ball up to 700°/s, then ejects it at 0.06 × that (≤ 42 u/s).
- **SpeedLane:** adds +50 u/s upward.

**Geometry discrepancy to check.** The physics report puts the walls at x ≈ ±5.5 (about 11 u wide). The generator's slots, however, sit at x ≈ −7.6…−8.6 (outlane kicker and lane blocker), and the placement grid spans x ±9. So the playfield is probably about 18–20 u wide; the ±5.5 figure may describe only the inner lanes. Verify against the `Classic_WallSection_*` polygons before copying the dimensions.

---

## 5. Answers

### Is it truly procedural or infinite?
It is **infinite, but assembled from templates**, with one genuinely procedural element (rails).
- The playfield shell (walls, slingshots, flippers, outlanes, blockers, fences) comes from 3 wall-section prefabs per side, mixed left/right independently: 3×3 = 9 shells per theme, times 3 backgrounds.
- The middle is a constrained random scatter of prefab objects onto a fixed 12×12 grid, with physics overlap checks.
- Generation is lazy: 10 tables, then batches of 5 when within 5 of the end, at one table per frame.
- There is no handcrafted level list, and no seed that reproduces a table from its index.

### Design rules that keep tables playable and fun

**Protected zones:**
- The random scatter grid never covers the bottom 6.5 units (flippers and inlanes) or the very top.
- The fixed shell guarantees two flippers, slingshots and outlanes on every table.

**Guaranteed safety on early tables:**
- Table 0 only uses wall sections that have outlane-kicker slots, always places both kickbacks, and has no electric fences (fences zap the ball and cost health).
- Tables 0–3 exclude warps, rails, spinners, the Block-Top event and destroyable bumpers. The first screens are simpler and harder to lose on.

**Ball-loss softening:**
- Falling back into a lower table scales velocity to (0.5, 0.1) and adds a 5-second centre-drain blocker.
- A stuck ball respawns after 5 s.
- Launches go straight up the middle with flippers non-solid.

**Spacing:**
- Every object reserves a margin radius or box. Grid points inside it are deleted, and later objects are overlap-tested (100 tries) against all earlier ones.
- Warps and teleporters reserve a clear 1.2-wide full-height column.
- Teleport pairs must be in different columns, and the pair is all-or-nothing.
- `DoNotPlaceInCenterX` pushes chosen objects off the centre line by 1.5, keeping the centre drain lane and launch line clear.

**Caps and density:**
- At most 8 counted objects per table (minimum 4 nominally, but not enforced).
- Per-prefab `MaxObjectAllowedPerTable`.
- 1–3 events per table; one trigger per reward type.
- At most one centre feature (slot machine, score multiplier or speed lane), and centre rewards are chosen first.
- Moving bumpers are listed twice in the default creator list, so they effectively get a higher spawn weight.

**Linking rules:**
- Only one rail and one warp can be "in flight" at a time.
- A rail's end table is force-generated before the batch ends.
- Rails and warps never cross a bonus table.
- A rail is deleted if either ramp end overlaps anything.
- A warp entrance is deleted if its exit can't be placed.
- No teleporter appears on a table that has a warp.

**Retries and failure handling:**
- 100 grid tries per object.
- 20 passes over the shuffled creator list per table.
- Any failed placement destroys the instance and its reward objects. The table simply ends up with fewer objects; nothing blocks generation.

**Pacing and difficulty ramp:**
- A hand-made bonus/challenge table every 10th screen.
- Apart from tables 0–3 and the bonus cadence, the parameters are flat. Difficulty comes from accumulated table variety and losing health, not from rising numbers.

### Notable bugs and quirks (worth not copying)
- The object-count roll in `Randomize` is discarded.
- `_shouldForceEvaluateAllPoints` is never set, so it is dead.
- Each `ObjectPlacement` reseeds with the MasterSeed, so every object follows the same index sequence.
- `InitializeRewardsForTable` removes items from a list while iterating it forward, so it skips an item.
- `offsetX` in the distance-checked search is ignored.
- The `BonusTable` % and `AllowBonusTable` are unused.
- `RailPatternData` is unused.
- An entrance warp can spawn while another exit is still pending; it gets the same id.
