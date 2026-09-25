import { computed, ref, onMounted, onUnmounted } from "vue"

export function useScheduledRaces(store) {
  const scheduleUiSecondTick = ref(0)
  let scheduleUiTimer = null

  onMounted(() => {
    scheduleUiTimer = setInterval(() => {
      scheduleUiSecondTick.value++
    }, 1000)
  })

  onUnmounted(() => {
    if (scheduleUiTimer) {
      clearInterval(scheduleUiTimer)
      scheduleUiTimer = null
    }
  })

  const formatWaitText = (seconds, useWallClock) => {
    if (!useWallClock && (store.racingTeamCareerSimTime === null || store.racingTeamCareerSimTime === undefined)) {
      if (Number.isFinite(seconds) && seconds > 0) {
        const s = Math.max(0, Math.floor(seconds))
        const minutes = Math.floor(s / 60)
        const secs = s % 60
        return minutes > 0 ? `Ready in ~${minutes}m ${secs}s (syncing…)` : `Ready in ~${secs}s (syncing…)`
      }
      return "Syncing countdown…"
    }
    if (!Number.isFinite(seconds) || seconds <= 0) return "Not ready yet"
    const s = Math.max(0, Math.floor(seconds))
    const minutes = Math.floor(s / 60)
    const secs = s % 60
    return minutes > 0 ? `Ready in ${minutes}m ${secs}s` : `Ready in ${secs}s`
  }

  const remainingSecondsForScheduledDriver = (t) => {
    const pr = t?.pendingRaceOffer
    const wallDue = Number(pr?.scheduledRaceReadyWallEpoch ?? t?.scheduledRaceReadyWallEpoch)
    void scheduleUiSecondTick.value
    if (Number.isFinite(wallDue)) {
      return Math.max(0, wallDue - Math.floor(Date.now() / 1000))
    }
    const due = Number(t.scheduledRaceSimTime)
    const now = Number(store.racingTeamCareerSimTime)
    if (Number.isFinite(due) && Number.isFinite(now)) {
      return Math.max(0, Math.floor(due - now))
    }
    const fallback = Number(t.secondsUntilScheduledRace)
    if (Number.isFinite(fallback)) {
      return Math.max(0, Math.floor(fallback))
    }
    return null
  }

  const scheduledRows = computed(() => {
    void store.racingTeamCareerSimTime
    void scheduleUiSecondTick.value
    const list = store.techs
    const managerLevel = Number(store.businessData?.racingTeamManagerSkillLevel ?? 0)
    const hasManager1 = managerLevel >= 1
    const simActive = !!store.businessData?.activeBackgroundRace
    const rows = []

    const playerOffer = store.playerScheduledOffer || store.businessData?.playerScheduledOffer
    if (playerOffer) {
      rows.push({
        key: `player-${playerOffer.id ?? "pending"}`,
        driverId: "player",
        driverName: "You (Owner)",
        isPlayer: true,
        raceTitle: playerOffer.raceLabel || playerOffer.raceName || "Race",
        offer: playerOffer,
        scheduledRaceReady: true,
        secondsUntilScheduledRace: 0,
        useWallClock: false,
        isInSim: false,
        simPhase: "",
        simBadge: "",
        simProgress: 0,
        canSpectate: true,
        primaryDisabled: false,
        primaryLabel: "Drive to Track",
        hidePrimary: false,
        hideSecondary: false,
        showSendWithManager: false,
        sendWithManagerDisabled: true,
        sendWithManagerTooltip: "",
        statusText: "",
        metaText: "Ready to race",
        metaReady: true,
      })
    }

    if (Array.isArray(list)) {
      for (const t of list) {
        if (!t || t.fired || !t.pendingRaceOffer) continue
        const pr = t.pendingRaceOffer
        const useWallClock = Number.isFinite(Number(pr.scheduledRaceReadyWallEpoch ?? t.scheduledRaceReadyWallEpoch))
        const remaining = remainingSecondsForScheduledDriver(t)
        const ready = remaining !== null ? remaining <= 0 : t.scheduledRaceReady === true
        const inSim = t.isInSim === true
        const canSpectate = t.canSpectate !== false

        const statusText = (inSim || ready) ? "" : formatWaitText(remaining ?? 0, useWallClock)

        let managerTooltip = ""
        if (!hasManager1) managerTooltip = "Requires Manager Lv 1"
        else if (simActive) managerTooltip = "Manager is already supervising a race"
        else if (!ready) managerTooltip = "Race is not ready yet"
        else managerTooltip = "Send driver to race in the background with team manager"

        rows.push({
          key: `sched-${t.id}-${pr.id ?? ""}`,
          driverId: t.id,
          driverName: t.name || `Driver #${t.id}`,
          isPlayer: false,
          raceTitle: pr.raceLabel || pr.raceName || "Race",
          offer: pr,
          scheduledRaceReady: ready,
          secondsUntilScheduledRace: remaining ?? 0,
          useWallClock,
          isInSim: inSim,
          simPhase: t.simPhase || "",
          simBadge: t.simBadge || "",
          simProgress: Number(t.simProgress ?? 0),
          canSpectate,
          primaryDisabled: !ready || !canSpectate,
          primaryLabel: "Manage myself",
          hidePrimary: inSim && !canSpectate,
          hideSecondary: inSim && !canSpectate,
          showSendWithManager: !inSim,
          sendWithManagerDisabled: !ready || !hasManager1 || simActive,
          sendWithManagerTooltip: managerTooltip,
          statusText,
          metaText: inSim ? (t.simBadge || "Simulating") : (ready ? "Ready to spectate" : formatWaitText(remaining ?? 0, useWallClock)),
          metaReady: ready,
        })
      }
    }

    return rows
  })

  return {
    scheduledRows,
    scheduleUiSecondTick,
  }
}
