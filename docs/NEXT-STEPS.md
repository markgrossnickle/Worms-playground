# Worms Playground — Review & Next Steps

*Written 2026-07-11 by Claude Fable. Snapshot of `main` at `3458fcf` (last commit 2026-05-01).*

---

## ASSESSMENT

**What it is.** "Worm King" — a 3-team, 8-minute, round-based worms.io-style arena game on Roblox (Luau + Knit). Players steer a growing worm across a triangular desert arena; one Crown at the centroid scores +1/s for whichever team holds it. The twist that makes this game distinct: **death isn't downtime**. Dead players become ghosts who fly, shoot seven weapon types, grapple onto and ride living worms, and earn Marks to buy their way back into worm form. The endgame layers on a contracting sand-tide triangle, a respawn lockdown, and three win conditions (score / elimination / timeout). ~20,500 lines of Luau across 62 modules, bots filling lobbies with real catalog avatars.

**Current state: mechanically deep, commercially empty.** The core loop specified in GAME.md is genuinely implemented, not aspirational: Crown scoring (`CrownService`), the Marks economy with 10-Mark respawn (`MarksService.luau:158-169`), sand tide with lockdown phase transition (`RoundService/init.luau:228-230`), 2-second spawn protection (`WormConfig.luau:117`), elimination-only-during-lockdown win logic (`RoundService/init.luau:160-163`). Serious performance engineering has been done — spatial hashing for collision/food, 10 Hz replication with client interpolation, AI throttling — and the last ten commits are all game-feel work (ghost health bars, hit feedback, flocking, target leading). This is a team that has been tuning *feel*, which is the right instinct.

**Is it launch-ready? No — roughly 3–5 focused weeks out.** What's missing is everything *around* the game: there is no tutorial or control hint of any kind on `main`, the game is essentially silent (one procedurally-created hit sound in the whole codebase), coins are earned and persisted but there is **nothing to spend them on**, there are zero `MarketplaceService`/game-pass/dev-product references, several bootstrap-template systems are still unwired TODO stubs, and CI only lints — there is no build-and-publish pipeline and `Environment.luau` still has placeholder game IDs.

**The most important strategic fact:** four open PRs from March (#5 AudioController with 36 chosen asset IDs, #6 tutorial/onboarding, #8 daily quests, #9 cosmetic skins + shop UI) cover *exactly* these gaps — but all four are 33 commits behind `main` and predate the entire Worm King pivot. ~3,400 lines of relevant, mostly-done work is sitting stale. Rebasing/rewriting these is far cheaper than starting over, and triaging them is the single highest-leverage move available.

**Biggest strengths**
- The ghost afterlife is a real differentiator. Most .io-likes lose players at death; here the dead stay in the match with agency (shoot, ride, sabotage, earn a comeback). That's a retention mechanic disguised as a game mechanic.
- Networking discipline is well above hobby-project norm ("server brain, client body" is documented *and* actually followed), which means the game has a real shot at feeling good on mobile data.
- Bots are good enough (2,288 lines: flocking, target leading, crown pursuit, ghost bots with avatars and animations) that matches always look alive — critical for the cold-start problem on Roblox.
- GAME.md/CLAUDE.md are unusually complete; any contributor (human or AI) can onboard fast.

**Biggest weaknesses / risks**
- **First-session comprehension.** Worm King is a complicated pitch — steer, boost, crown, three win conditions, die→ghost→weapons→Marks→respawn, sand tide, lockdown — and a new player is shown none of it. This is the #1 churn risk, ahead of any bug.
- **Dead-end economy.** Coins in, nothing out. Placement rewards and daily-login streaks are paying into a wallet with no store attached, so the reward loop teaches players that rewards don't matter.
- **Never playtested at scale with humans.** Recent history is all bot-lobby tuning; 8–16 real players with real latency, real team imbalance, and real Marks-economy pacing is unvalidated (is 10 Marks reachable for an average ghost? is `ScoreThreshold = 100` ever hit in 8 minutes?).
- **Repo has been idle ~10 weeks** with the four gap-closing PRs unmerged — momentum risk as much as code risk.

---

## FEEDBACK

Specific issues, roughly ordered by impact.

### Gameplay / core-loop gaps
1. **Coins have no sink.** `CoinService/init.luau` implements `AwardCoins` / `GetCoins` / daily-login streaks (persisted via `PlayerDataService`) but no `SpendCoins`, and no shop exists anywhere on `main`. PR #9 (skin system + `ShopController`, 12 skins) is the intended sink but is stale and its skin-vs-team-color interaction ("team color overrides skin") needs rethinking now that team mode is *always on* — a skin that's invisible in the only game mode is not a product. Consider skins expressing through trails, death effects, ghost tint, and head accessories instead of body color.
2. **Marks economy is untuned.** Values in `WormConfig.luau:104` (RespawnCost 10, assists +1/+2, kills +3/+5) were spec'd, not derived from play. If an average ghost can't realistically bank 10 Marks in a mid-match window, the comeback loop — the game's signature — silently fails. Needs instrumentation (see MTAnalyticsService note below) and a playtest.
3. **No killer bounty / no anti-turtle pressure on the Crown** is a deliberate design call per GAME.md, but worth revisiting after playtest: +1/s to the holder's team with no bonus for contesting may make mid-game feel flat for the two losing teams.

### First-session / UX
4. **Zero onboarding on `main`.** No tutorial, no how-to-play, no contextual control hints (`grep -rn Tutorial src/ReplicatedStorage/Client` → nothing). PR #6 has a `TutorialService` + contextual tips + controls overlay, but it teaches the pre-Worm-King FFA game — merging it as-is would actively mislead. The death→ghost moment especially needs a one-time explainer ("You're a ghost — shoot worms to earn Marks, 10 Marks = respawn").
5. **The game is silent.** The only sound in the codebase is a single procedural click (`EffectsController.luau:706-712`). No music, no eat/boost/death/explosion/crown audio. PR #5 (AudioController, 752 lines, all 36 asset IDs filled in) fixes this and is the easiest of the four stale PRs to rebase since it's almost purely additive.
6. **No settings menu, no loading screen, no README.md.** Minor individually; together they read as "prototype" to a player and to collaborators.

### Retention / monetization
7. **Zero monetization surface.** No game passes, dev products, or `MarketplaceService` usage anywhere. GAME.md's cosmetic-only policy is right for this game — but it currently monetizes nothing at all. The dependency chain is: skins/shop (sink) → coin bundles + exclusive cosmetics (Robux) → done. Don't ship Robux products before the free sink exists.
8. **Daily quests (PR #8, 9 quest types) are the strongest retention piece** and pair with the shop: quests make coins flow, the shop makes coins matter. Stale, needs rebase onto Worm King (quest types referencing FFA placement need rework).
9. **Template systems half-wired:** `MilestoneService/init.luau:10-12` is an unwired TODO stub (no game events connected, no badges awarded); `LeaderboardConfig.luau:27` still ships placeholder `Score1`/`Score2` boards alongside the real `GhostKills`/`RideTime` ones (which *are* submitted — `WormService/init.luau:2302,2432,2461`). Either wire milestones to real events (first crown pickup, first ghost kill, first Marks respawn) or delete the stub before launch.

### Technical debt / bugs
10. **God files:** `WormService/init.luau` 2,838 lines, `WormUIController.luau` 2,666, `BotService/init.luau` 2,288, `WeaponService/init.luau` 1,404. Not urgent, but WormService (arena + food + movement + collision + ghosts + riders + game loop) is where every future feature will merge-conflict. Extracting Ghost/rider logic into its own service is the highest-value split.
11. **Legacy dual systems retained:** `ShrinkZoneService` is cleanly disabled (`ShrinkZoneService/init.luau:20` — `DISABLED = WormConfig.TeamModeEnabled`), FFA round logic still lives in RoundService. Acceptable while Worm King bakes, but it doubles the surface for the recurring grapple-style regressions CLAUDE.md warns about. Schedule deletion, don't let it fossilize.
12. **`Environment.luau:12` game IDs are placeholders** — every non-Studio server currently resolves to `Production`, which affects Cmdr admin gating (rank ≥ 252 checks in prod) and any future env-specific behavior. Must be filled before a Review/Staging place exists.
13. **Publish pipeline absent:** `.github/workflows/analyze.yml` runs selene + StyLua only. No `rojo build` artifact, no place upload (rbxcloud/mantle), no version bump automation (`GameVersion.txt` hand-edited at 1.0.0).
14. **Analytics exist but aren't answering design questions.** `MTAnalyticsService` is a rate-limited wrapper; nothing appears to emit funnel events for the questions that matter (ghost→respawn conversion, crown-hold durations, match win-condition distribution). Cheap to add, pays off at first playtest.

---

## NEXT STEPS

Prioritized. Effort: S ≈ ≤1 day, M ≈ 2–5 days, L ≈ 1–2+ weeks.

| # | Action | Effort | Why |
|---|--------|--------|-----|
| 1 | **Triage the 4 stale PRs** (#5 audio, #6 tutorial, #8 quests, #9 skins): rebase-or-rewrite decision on each, close what's dead. Audio first (mostly additive). | **S** | ~3,400 lines of gap-closing work already exists; every week it sits, the rebase gets worse. Unblocks items 2, 3, 5, 7. |
| 2 | **Ship audio** — rebase PR #5's AudioController onto Worm King main; add crown-pickup/lockdown/sand-tide stingers it predates. | **S–M** | A silent game reads as broken. Cheapest perceived-quality win available; asset IDs already chosen. |
| 3 | **Worm King onboarding** — rewrite PR #6's tutorial content for the actual game: steer/boost on first spawn; one-time ghost explainer on first death (Marks → 10 → respawn button); crown callout on first sighting. Contextual tips, not a walkthrough. | **M** | The loop is the game's strength and its comprehension risk. First-session clarity is the top churn lever; everything else assumes players survive session one. |
| 4 | **First real playtest (8–16 humans) + analytics events** — add funnel events (ghost→respawn conversion, crown-hold time, win-condition distribution, match length), run 5+ matches, tune `WormConfig.WormKing` numbers (Marks rates, ScoreThreshold=100, tide timings). | **M** | The netcode and the Marks/crown economy have only ever been validated against bots. Every tuning decision downstream depends on this data. |
| 5 | **Coin sink: cosmetics shop** — rebase PR #9; redesign skins to read in always-on team mode (trails, death effects, ghost tint, head accessories rather than body color); add `SpendCoins` with server-side validation. | **M** | Completes the earn→spend loop that placement rewards and daily streaks currently pay into a void. Prerequisite for monetization. |
| 6 | **Publish pipeline + environments** — GitHub Actions job: `rojo build` → upload to a Review place via `rbxcloud` on PR, Production on main tag; fill `Environment.luau` game IDs; auto-bump `GameVersion.txt`. | **S–M** | Removes Studio-manual-publish as the release process; makes playtests (item 4) one-click; env detection is currently broken-by-default outside Studio. |
| 7 | **Monetization v1 (cosmetic-only)** — coin-bundle dev products + 2–3 exclusive Robux cosmetics + a "Supporter" pass, per GAME.md's no-pay-for-power policy. | **M** | Zero revenue surface today. Only sensible *after* item 5 exists; doing it earlier monetizes nothing. |
| 8 | **Retention layer: daily quests** — rebase PR #8 onto Worm King, rework FFA-era quest types to Worm King verbs (hold crown 60s, 3 ghost kills, 1 Marks respawn). | **M** | Strongest session-2+ driver; multiplies the value of the shop (5) and daily-login streaks already in `CoinService`. |
| 9 | **Debt pass** — extract ghost/rider logic from `WormService` into a `GhostService`; delete or wire `MilestoneService` stub and `Score1`/`Score2` placeholder boards; delete `ShrinkZoneService` + FFA paths once Worm King is validated; add a README. | **M** | Keeps velocity from decaying; 2,800-line WormService is where every future PR will conflict. Do incrementally alongside 2–8, not as a stop-the-world. |
| 10 | **Content horizon (post-launch)** — second arena/biome (TerrainHeight is already parameterized), limited-time modifiers (double-crown weekends), ghost weapon variety passes. | **L** | Single-mode single-map is fine to *launch*, but is the ceiling on long-term retention. Don't start before 1–8 are done. |

**Suggested sequencing:** 1 → (2 ∥ 6) → 3 → 4 → tune → 5 → 8 → 7 → 9 throughout → launch → 10.

The one-line takeaway: **the game underneath is real and differentiated — the work remaining is not game design, it's wrapping (onboarding, sound, economy sink, pipeline), and most of it is already written in stale PRs waiting to be rebased.**
