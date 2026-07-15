# CodeMap: Worms-playground

_90 files | 22,794 LOC | source: git ls-files_

## Stats

| Language | Files | LOC |
|---|---:|---:|
| Luau | 62 | 20,526 |
| JSON | 10 | 58 |
| other | 5 | 85 |
| Markdown | 5 | 1,133 |
| TOML | 5 | 67 |
| YAML | 2 | 56 |
| Python | 1 | 869 |

## Entry points

- `src/ReplicatedStorage/Client/ClientEntry.server.luau` — roblox server script
- `src/ServerScriptService/Server/Main.server.luau` — roblox server script

## Tree

```
scripts/  (1 files, 869 LOC)
src/  (71 files, 20,555 LOC)
  ReplicatedStorage/  (38 files, 8,918 LOC)
    Client/  (15 files, 7,497 LOC)
    Shared/  (23 files, 1,421 LOC)
  ServerScriptService/  (33 files, 11,637 LOC)
    Server/  (33 files, 11,637 LOC)
... +2 asset-only directories (no code)
```

## Key files (40 of 90, ranked)

- `src/ServerScriptService/Server/Services/WormService/init.luau` (2838 L) **[<-7 knit]**
  - WormService, :DamageWorm(), :ExplodeWorm(), :RebuildFoodGrid(), :RebuildCollisionGrid(), :RegisterBot(), :UnregisterBot(), :UpdateBotSegments(), :ConsumeFood(), :DropFoodAtPosition(), :DropFoodFromModel(), :FireBotDeath(), +55 more
- `src/ServerScriptService/Server/Services/BotService/init.luau` (2288 L) **[<-6 knit]**
  - BotService, :DamageBotGhost(), :KillBotGhostByModel(), :DamageBot(), :ExplodeBot(), :SetRoundActive(), :GetAliveCount(), :GetAliveBotNames(), :GetBotHeadPosition(), :KillAllBots(), :ClearRoundStats(), :SpawnBotsToFill(), +36 more
- `src/ReplicatedStorage/Client/Controllers/WormController.luau` (1544 L) **[knit]**
  - WormController, :SpectateTarget(), :CycleSpectate(), :ToggleFreeCam(), :ToggleGhostMode(), :GetSegments(), :IsAlive(), :IsInGhostMode(), :IsFreeCamActive(), :FireGrapple(), :GetAliveCount(), :GetSpectateTarget(), +40 more
- `src/ReplicatedStorage/Client/Controllers/WormUIController.luau` (2666 L) **[knit]**
  - WormUIController, :ShowGhostRespawnCountdown(), :HideGhostRespawnCountdown(), :KnitInit(), :KnitStart(), :_buildUI(), :_buildGhostRespawnBanner(), :_buildMatchTimerHUD(), :_buildLockdownBanner(), :_updateMatchTimer(), :_hideMatchTimer(), :_buildGhostHud(), +41 more
- `src/ServerScriptService/Server/Services/WeaponService/init.luau` (1404 L) **[<-1 knit]**
  - WeaponService, :AssignRandomWeapon(), :AssignWeapon(), :ClearWeapon(), :GetWeaponData(), :ClearAllPickups(), :KnitInit(), :KnitStart(), :_isReloading(), :_startReload(), :_validateShoot(), :_onShoot(), +22 more
- `src/ServerScriptService/Server/Services/LeaderboardService/init.luau` (1336 L) **[<-1 knit]**
  - LeaderboardService, :SubmitScore(), :SubmitScoreAllPeriods(), :GetTopPlayers(), :GetPlayerRank(), :GetPlayerStats(), :GetAllPlayerStats(), :GetLeaderboardData(), :ForceRefreshCache(), :KnitInit(), :KnitStart(), :_initializePropertyCacheOrder(), +21 more
- `src/ReplicatedStorage/Client/Controllers/EffectsController.luau` (1105 L) **[knit]**
  - EffectsController, :Shake(), :KnitInit(), :KnitStart(), :_buildUI(), :_onSegmentsChanged(), :_spawnEatParticles(), :_pulseHeadScale(), :_spawnFloatingText(), :_startBoostEffects(), :_stopBoostEffects(), :_addBoostTrail(), +21 more
- `scripts/codemap.py` (869 L)
  - demotion, is_git_repo, repo_name_for, list_files_git, _in_skip_dir, list_files_walk, enumerate_files, strip_comments, strip_lua_comments, luau_require_name, extract_lua_symbols, looks_like_component, +19 more
- `src/ReplicatedStorage/Client/Controllers/DeathCamController.luau` (792 L) **[knit]**
  - DeathCamController, :KnitInit(), :KnitStart(), :_buildUI(), :_buildDeathCamOverlay(), :_buildKillPopup(), :_buildSpectateHud(), :_buildRoundEndOverlay(), :_startDeathCam(), :_endDeathCam(), :_showKillPopup(), :_doCameraShake(), +6 more
- `src/ServerScriptService/Server/Services/CrownService/init.luau` (578 L) **[<-3 knit]**
  - CrownService, :GetScoreSnapshot(), :ResetAndSpawn(), :Despawn(), :OnCarrierDeath(), :GetState(), :IsCarriedBy(), :KnitInit(), :KnitStart(), :_createCrownModel(), :_destroyCrownModel(), :_positionCrownModel(), +13 more
- `src/ReplicatedStorage/Client/Controllers/WeaponController.luau` (746 L) **[knit]**
  - WeaponController, :TryReload(), :TryShoot(), :TryThrowGrenade(), :TryThrowCluster(), :TryDeployMine(), :StartPowerShotCharge(), :ReleasePowerShot(), :GetChargeAlpha(), :GetWeaponType(), :GetAmmo(), :IsReloading(), +12 more
- `src/ServerScriptService/Server/Services/TeamService/init.luau` (246 L) **[<-7 knit]**
  - TeamService, :IsEnabled(), :GetTeamForMember(), :GetTeamColor(), :AreTeammates(), :AssignToTeam(), :RemoveFromTeam(), :GetTeamScores(), :ClearAllMembers(), :GetTeams(), :GetAliveTeams(), :KnitInit(), +4 more
- `src/ServerScriptService/Server/Services/PowerUpService/init.luau` (494 L) **[<-3 knit]**
  - PowerUpService, :GetSlowFactor(), :CollectPowerUp(), :HasActivePowerUp(), :ConsumeShield(), :GetSpeedMultiplier(), :HasFreeBoost(), :GetMagnetRange(), :IsGhost(), :GetNearestPowerUp(), :ClearActivePowerUp(), :Reset(), +14 more
- `src/ServerScriptService/Server/Services/RoundService/init.luau` (461 L) **[<-2 knit]**
  - RoundService, :IsRoundActive(), :GetRoundElapsed(), :GetMatchPhase(), :KnitInit(), :KnitStart(), :_startRound(), :_getAllAliveNames(), :_startPollWinCondition(), :_computeTimeoutWinner(), :_startMatchTimer(), :_endRound(), +3 more
- `src/ReplicatedStorage/Shared/WormConfig.luau` (147 L) **[<-15]**
- `src/ReplicatedStorage/Client/ClientEntry.server.luau` (4 L) **[ENTRY]**
- `src/ServerScriptService/Server/Main.server.luau` (4 L) **[ENTRY]**
- `src/ServerScriptService/Server/Services/SandTideService.luau` (299 L) **[<-3 knit]**
  - SandTideService, :GetScale(), :Reset(), :KnitInit(), :KnitStart(), :_createEdges(), :_updateEdgeVisual(), :_applyDamageTick(), :_update(), local computeScale(), local inAnyScaledSafeZone()
- `src/ReplicatedStorage/Shared/TeamBase.luau` (183 L) **[<-4]**
  - TeamBase, :getBasePositionXZ(), :getBasePosition(), :isInsideSafeZone(), :getSpawnPosition(), :getCentroid(), :getScaledBasePositionXZ(), :isInsideScaledSafeZone(), :getScaledSpawnPosition(), :getScaledVertices(), :isInsideTriangle(), :distanceToTriangle()
- `src/ServerScriptService/Server/Services/PlayerDataService/init.luau` (323 L) **[knit]**
  - PlayerDataService, :WaitForProfile(), :ResetAndKick(), :RegisterService(), :ServiceFinished(), :KnitStart(), :KnitInit(), :Read(), :Write(), :_loadProfile(), :_loadPlayerProfiles(), type TableKeys, +8 more
- `src/ServerScriptService/Server/Services/MarksService.luau` (226 L) **[<-1 knit]**
  - MarksService, :GetMarks(), :AwardMarks(), :SpendMarks(), :ResetAll(), :KnitInit(), :KnitStart(), :_setMarks(), :_victimWasCarrier(), :_awardForKill(), :_canRespawn(), :_doRespawn(), +1 more
- `src/ServerScriptService/Server/Services/ShrinkZoneService/init.luau` (186 L) **[<-3 knit]**
  - ShrinkZoneService, :GetCurrentRadius(), :GetElapsedTime(), :IsOutsideZone(), :Reset(), :KnitInit(), :KnitStart(), :_createRing(), :_updateRingVisual(), :_update()
- `src/ReplicatedStorage/Client/Controllers/AnimationController.luau` (166 L) **[knit]**
  - AnimationController, :LoadAnimations(), :LoadAnimation(), :PlayAnimation(), :PlayAnimationTrack(), :StopPlayingAnimations(), :StopAnimationTrack(), :GetAnimator(), :KnitStart(), :KnitInit(), type AnimationOptions, type BulkAnimationLoadOptions, +3 more
- `src/ReplicatedStorage/Shared/TerrainHeight.luau` (67 L) **[<-7]**
  - local getHeight(), local getSurfaceY(), local getSmoothSurfaceY()
- `src/ReplicatedStorage/Client/Controllers/BotInterpController.luau` (300 L) **[knit]**
  - BotInterpController, :KnitInit(), :KnitStart(), :_shouldSmoothModel(), :_registerPart(), :_unregisterPart(), :_registerModel(), :_unregisterModel(), type PartState
- `src/ReplicatedStorage/Shared/GrappleStyles.luau` (198 L) **[<-3]**
  - GrappleStyles, :names(), :get(), :getCurrent(), :setCurrent(), type GrappleStyle
- `src/ReplicatedStorage/Shared/Easings.luau` (69 L) **[<-1]**
  - Easings, :linear(), :quadIn(), :quadOut(), :cubicIn(), :cubicOut(), :cubicInOut(), :quartIn(), :quartOut(), :sineOut(), :backIn(), :backOut()
- `src/ServerScriptService/Server/Services/BadgeService.luau` (180 L) **[knit]**
  - BadgeService, :KnitStart(), :KnitInit(), :LoadBadgeData(), :GetBadgeData(), :AwardBadge(), :UserHasBadge(), :UserHasBadgeBulk(), type BadgeData
- `src/ServerScriptService/Server/Services/MTAnalyticsService.luau` (172 L) **[knit]**
  - MTAnalyticsService, :LogCustomEvent(), :LogEconomyEvent(), :LogFunnelStepEvent(), :LogOnboardingFunnelStepEvent(), :KnitInit(), type AnalyticsEconomyFlowType, type AnalyticsProgressionType, type Dictionary
- `src/ReplicatedStorage/Shared/WeaponConfig.luau` (185 L) **[<-3]**
  - WeaponConfig, type WeaponType, type WeaponDef
- `src/ReplicatedStorage/Shared/SpatialIndex.luau` (109 L) **[<-1]**
  - SpatialIndex, :new(), :Clear(), :Insert(), :ForEachNeighbor(), type Entry, local cellKey()
- `src/ServerScriptService/Server/Services/CoinService/init.luau` (130 L) **[<-1 knit]**
  - CoinService, :AwardCoins(), :GetCoins(), :KnitInit(), :KnitStart(), :_checkDailyLogin()
- `src/ReplicatedStorage/Shared/GhostHealthBar.luau` (123 L) **[<-2]**
  - GhostHealthBar, :Attach(), :Update(), local pickFillColor()
- `src/ServerScriptService/Server/Services/MilestoneService/init.luau` (179 L) **[knit]**
  - MilestoneService, :HasMilestone(), :AwardMilestone(), :GetAllMilestones(), :KnitInit(), :KnitStart()
- `src/ReplicatedStorage/Shared/PlatformUtil.luau` (34 L) **[<-3]**
  - PlatformUtil, :ActionLabel(), :MinTouchSize()
- `src/ReplicatedStorage/Client/Controllers/InputController.luau` (69 L) **[knit]**
  - InputController, :JumpRequest(), :RegisterInput(), :UnregisterInput(), :KnitInit(), :KnitStart(), :_onRegisteredInputChanged()
- `src/ReplicatedStorage/Shared/Enums/init.luau` (16 L) **[<-3]**
  - Enums, type Environment, type WormState
- `src/ReplicatedStorage/Client/init.luau` (55 L) **[<-1]**
  - Client, :Main(), :WaitForServerStarted(), :Start(), :_loadComponentsIn()
- `src/ReplicatedStorage/Shared/CmdrHelper.luau` (52 L) **[<-2]**
  - CmdrHelper, :HasCmdrPermissions(), :RegisterCmdrContent()
- `src/ReplicatedStorage/Shared/Types/Controllers/AnimationControllerTypes.luau` (70 L) **[<-1]**
  - type Promise, type AnimationOptions, type BulkAnimationLoadOptions, type AnimationController

