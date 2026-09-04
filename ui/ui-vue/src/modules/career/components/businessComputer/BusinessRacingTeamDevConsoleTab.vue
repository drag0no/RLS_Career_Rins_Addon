<template>
  <div class="dev-console-tab">
    <div class="tab-header">
      <h2>Dev Console</h2>
      <p>Racing team debug tools (dev key required). Changes save immediately.</p>
    </div>

    <div v-if="statusMessage" class="dev-console-status">{{ statusMessage }}</div>

    <section class="dev-console-section">
      <h3 class="dev-console-section__title">Goals</h3>
      <div class="dev-console-grid">
        <button type="button" class="btn btn-primary" data-focusable :disabled="busy" @click="run('completeCurrentGoal')">
          Complete current goal
        </button>
        <button type="button" class="btn btn-primary" data-focusable :disabled="busy" @click="run('completeAllLeagueGoals')">
          Complete all league goals
        </button>
        <button type="button" class="btn btn-secondary" data-focusable :disabled="busy" @click="run('resetCurrentLeagueGoals')">
          Reset current league
        </button>
      </div>
    </section>

    <section class="dev-console-section">
      <h3 class="dev-console-section__title">Skills &amp; races</h3>
      <div class="dev-console-grid">
        <button type="button" class="btn btn-primary" data-focusable :disabled="busy" @click="run('maxAllSkills')">
          Unlock all skills
        </button>
        <button type="button" class="btn btn-primary" data-focusable :disabled="busy" @click="run('refreshRaceOffers')">
          Refresh race offers
        </button>
        <button type="button" class="btn btn-primary" data-focusable :disabled="busy" @click="run('forceLeagueInvite')">
          Force league invite
        </button>
      </div>
    </section>

    <section class="dev-console-section">
      <h3 class="dev-console-section__title">Economy</h3>
      <div class="dev-console-grid">
        <button type="button" class="btn btn-primary" data-focusable :disabled="busy" @click="run('injectMoney')">
          Inject money (+$1,000,000)
        </button>
        <button type="button" class="btn btn-primary" data-focusable :disabled="busy" @click="run('injectXp')">
          Inject XP (+20,000)
        </button>
      </div>
    </section>

    <section class="dev-console-section">
      <h3 class="dev-console-section__title">Waiting</h3>
      <p class="dev-console-section__hint">
        Clears cooldowns, makes scheduled races ready to spectate, skips the manager booking timer (and retries auto-assign), and refreshes offer-board timing.
      </p>
      <div class="dev-console-grid">
        <button type="button" class="btn btn-secondary" data-focusable :disabled="busy" @click="run('clearCooldowns')">
          Skip waiting
        </button>
      </div>
    </section>

    <section class="dev-console-section dev-console-section--danger">
      <h3 class="dev-console-section__title">Destructive</h3>
      <p class="dev-console-section__hint">
        Soft reset keeps bank and fleet. Hard reset wipes fleet, drivers, sponsors, bank (then starting capital), goals, league, skills, and dyno peaks.
      </p>
      <div class="dev-console-grid">
        <button type="button" class="btn btn-secondary dev-console-reset" data-focusable :disabled="busy" @click="onResetBusinessSoft">
          Reset progress (soft)
        </button>
        <button type="button" class="btn btn-secondary dev-console-reset dev-console-reset--hard" data-focusable :disabled="busy" @click="onResetBusinessHard">
          Full reset (hard)
        </button>
      </div>
    </section>

    <section class="dev-console-log">
      <div class="dev-console-log__header">
        <h3 class="dev-console-section__title">Dev log</h3>
        <button type="button" class="btn btn-secondary btn-sm" data-focusable :disabled="busy" @click="onClearLog">
          Clear
        </button>
      </div>
      <pre ref="logBodyRef" class="dev-console-log__body">{{ logText }}</pre>
    </section>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, onUnmounted, nextTick } from "vue"
import { useBridge } from "@/bridge"
import { openConfirmation } from "@/services/popup"
import { ACCENTS } from "@/common/components/base"
import { useBusinessComputerStore } from "../../stores/businessComputerStore"

const { lua, events } = useBridge()
const store = useBusinessComputerStore()
const busy = ref(false)
const statusMessage = ref("")
const logLines = ref([])
const logBodyRef = ref(null)

const logText = computed(() => {
  if (!logLines.value.length) {
    return "No dev log entries yet. Warnings and scan results appear here while the dev key is active."
  }
  return logLines.value.join("\n")
})

const LUA_ACTIONS = {
  completeCurrentGoal: "devConsoleRacingTeamCompleteCurrentGoal",
  completeAllLeagueGoals: "devConsoleRacingTeamCompleteAllLeagueGoals",
  resetCurrentLeagueGoals: "devConsoleRacingTeamResetCurrentLeagueGoals",
  maxAllSkills: "devConsoleRacingTeamMaxAllSkills",
  refreshRaceOffers: "devConsoleRacingTeamRefreshRaceOffers",
  forceLeagueInvite: "devConsoleRacingTeamForceLeagueInvite",
  clearCooldowns: "devConsoleRacingTeamClearCooldowns",
  resetBusinessSoft: "devConsoleRacingTeamResetBusinessSoft",
  resetBusinessHard: "devConsoleRacingTeamResetBusinessHard",
  injectXp: "devConsoleRacingTeamInjectXp",
  injectMoney: "devConsoleRacingTeamInjectMoney",
}

function parseLuaResult(result) {
  if (result && typeof result === "object" && !Array.isArray(result) && "ok" in result) {
    return { ok: result.ok === true, extra: result.error ?? null }
  }
  if (Array.isArray(result)) {
    return { ok: result[0] === true, extra: result[1] }
  }
  if (result === true || result?.success === true) {
    return { ok: true, extra: result?.error }
  }
  return { ok: false, extra: result?.error ?? result }
}

async function scrollLogToEnd() {
  await nextTick()
  const el = logBodyRef.value
  if (el) {
    el.scrollTop = el.scrollHeight
  }
}

function applyLogLines(lines) {
  logLines.value = Array.isArray(lines) ? lines.filter((l) => typeof l === "string") : []
  scrollLogToEnd()
}

function onDevLogEvent(data) {
  if (!data || typeof data !== "object") return
  if (data.clear === true) {
    logLines.value = []
    return
  }
  if (typeof data.text === "string" && data.text.length) {
    logLines.value = [...logLines.value, data.text]
    scrollLogToEnd()
  }
}

async function loadDevLog() {
  const bid = store.businessId
  if (!bid) return
  try {
    const result = await lua.career_modules_business_businessComputer.devConsoleRacingTeamGetDevLog(bid)
    if (result?.ok === true && Array.isArray(result.lines)) {
      applyLogLines(result.lines)
    }
  } catch (e) {
    console.error("[DevConsole] loadDevLog", e)
  }
}

async function onClearLog() {
  busy.value = true
  try {
    await lua.career_modules_business_businessComputer.devConsoleRacingTeamClearDevLog()
    logLines.value = []
  } catch (e) {
    console.error("[DevConsole] clearDevLog", e)
  } finally {
    busy.value = false
  }
}

async function reload() {
  const bid = store.businessId
  const btype = store.businessType
  if (!bid || !btype) return
  await store.loadBusinessData(btype, bid)
}

async function run(actionKey) {
  const bid = store.businessId
  if (!bid) return
  const fnName = LUA_ACTIONS[actionKey]
  if (!fnName) return
  busy.value = true
  statusMessage.value = ""
  try {
    const result = await lua.career_modules_business_businessComputer[fnName](bid)
    const { ok, extra } = parseLuaResult(result)
    if (!ok) {
      const err = typeof extra === "string" ? extra : null
      statusMessage.value = err ? `Failed: ${err}` : "Action failed."
    } else {
      statusMessage.value = "Done."
    }
    await reload()
  } catch (e) {
    console.error("[DevConsole]", actionKey, e)
    statusMessage.value = "Error — see log."
  } finally {
    busy.value = false
  }
}

async function onResetBusinessSoft() {
  const confirmed = await openConfirmation(
    "Reset progress (soft)?",
    "Clears goal progress, returns league to league 1, and wipes skill tree upgrades. Bank balance and fleet vehicles are kept.",
    [
      { label: "Reset", value: true, extras: { default: true } },
      { label: "Cancel", value: false, extras: { accent: ACCENTS.secondary, isCancel: true } },
    ]
  )
  if (!confirmed) return
  await run("resetBusinessSoft")
}

async function onResetBusinessHard() {
  const confirmed = await openConfirmation(
    "Full reset (hard)?",
    "Wipes fleet, parts, drivers, sponsors, goals, league progress, skill tree, skill XP, dyno peaks, and race state. Bank is cleared then set to starting capital. The business stays owned.",
    [
      { label: "Full reset", value: true, extras: { default: true } },
      { label: "Cancel", value: false, extras: { accent: ACCENTS.secondary, isCancel: true } },
    ]
  )
  if (!confirmed) return
  await run("resetBusinessHard")
}

onMounted(() => {
  events.on("racingTeam:devLog", onDevLogEvent)
  loadDevLog()
})

onUnmounted(() => {
  events.off("racingTeam:devLog", onDevLogEvent)
})
</script>

<style scoped lang="scss">
.dev-console-tab {
  padding: 1.5rem;
  color: #fff;
  max-width: 42rem;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.tab-header {
  margin-bottom: 1.25rem;

  h2 {
    margin: 0 0 0.35rem;
    font-size: 1.5rem;
    font-weight: 600;
  }

  p {
    margin: 0;
    opacity: 0.75;
    font-size: 0.9rem;
  }
}

.dev-console-status {
  margin-bottom: 1rem;
  padding: 0.5rem 0.75rem;
  border-radius: 4px;
  background: rgba(255, 255, 255, 0.08);
  font-size: 0.85rem;
}

.dev-console-section {
  margin-bottom: 1.5rem;
  padding-bottom: 1.25rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);

  &--danger {
    border-bottom: none;
    margin-bottom: 0.75rem;
    padding-bottom: 0;
  }

  &__title {
    margin: 0 0 0.75rem;
    font-size: 0.75rem;
    font-weight: 600;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    opacity: 0.7;
  }

  &__hint {
    margin: 0 0 0.75rem;
    font-size: 0.85rem;
    opacity: 0.75;
    line-height: 1.4;
  }
}

.dev-console-grid {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
}

.dev-console-reset {
  border-color: rgba(220, 80, 80, 0.6);

  &--hard {
    border-color: rgba(220, 50, 50, 0.85);
    color: #ffb4b4;
  }
}

.dev-console-log {
  margin-top: 0.5rem;
  padding-top: 1rem;
  border-top: 1px solid rgba(255, 255, 255, 0.15);
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;

  &__header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
    margin-bottom: 0.5rem;

    .dev-console-section__title {
      margin: 0;
    }
  }

  &__body {
    margin: 0;
    padding: 0.75rem;
    border-radius: 4px;
    background: rgba(0, 0, 0, 0.35);
    font-family: ui-monospace, Consolas, monospace;
    font-size: 0.78rem;
    line-height: 1.45;
    white-space: pre-wrap;
    word-break: break-word;
    flex: 1;
    min-height: 8rem;
    max-height: 14rem;
    overflow-y: auto;
  }
}

.btn-sm {
  padding: 0.25rem 0.6rem;
  font-size: 0.8rem;
}
</style>
