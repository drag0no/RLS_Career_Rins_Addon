<template>
  <Teleport to="body">
    <Transition name="beta-cycle-fade">
      <div
        v-if="open"
        ref="dialogRoot"
        class="beta-cycle-overlay"
        :class="{ 'beta-cycle-overlay--ready': interactive }"
        role="dialog"
        aria-modal="true"
        aria-labelledby="beta-cycle-title"
        tabindex="-1"
        @click.self="onBackdrop"
        @keydown.esc.prevent="onEsc"
      >
        <div class="beta-cycle-scale" :style="{ transform: `scale(${panelScale})` }">
        <section ref="panelRoot" class="beta-cycle-panel" @click.stop>
          <header class="beta-cycle-header">
            <div>
              <p class="beta-cycle-eyebrow">{{ summary.eyebrow }}</p>
              <h1 id="beta-cycle-title">{{ summary.title }}</h1>
              <p class="beta-cycle-intro">{{ summary.intro }}</p>
            </div>
            <span class="beta-cycle-version">{{ summary.label }}</span>
          </header>

          <div class="beta-cycle-sections">
            <section
              v-for="group in changeGroups"
              :key="group.tag"
              class="beta-cycle-section"
              :aria-labelledby="`beta-cycle-section-${group.tag}`"
            >
              <h2 :id="`beta-cycle-section-${group.tag}`" class="beta-cycle-section-title">
                {{ group.label }}
                <span>{{ group.changes.length }}</span>
              </h2>
              <div class="beta-cycle-grid">
                <article
                  v-for="(change, index) in group.changes"
                  :key="`${change.title}-${index}`"
                  class="beta-cycle-change"
                >
                  <div class="beta-cycle-change-number">{{ String(index + 1).padStart(2, "0") }}</div>
                  <div class="beta-cycle-change-copy">
                    <h3>{{ change.title }}</h3>
                    <p>{{ change.body }}</p>
                  </div>
                </article>
              </div>
            </section>
          </div>

          <footer class="beta-cycle-footer">
            <p>Thanks for testing. Keep an eye out for anything that feels unclear, unbalanced or inconsistent.</p>
            <div class="beta-cycle-actions">
              <label class="beta-cycle-preference">
                <input
                  v-model="dontShowAgain"
                  type="checkbox"
                  data-focusable
                  :disabled="!interactive"
                />
                <span>Don't show this again for {{ summary.label }}</span>
              </label>
              <button
                ref="continueButton"
                type="button"
                class="beta-cycle-continue"
                data-focusable
                :disabled="!interactive"
                @click.stop="dismiss"
              >
                {{ interactive ? "Start testing" : "Loading career..." }}
              </button>
            </div>
          </footer>
        </section>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { lua, useBridge } from "@/bridge"

const STORAGE_PREFIX = "rls-career-overhaul:beta-cycle-seen:"
const EVENT_NAME = "RlsBetaCycleSplashShow"

const bridge = useBridge()
const open = ref(false)
const summary = ref({ changes: [] })
const dialogRoot = ref(null)
const panelRoot = ref(null)
const continueButton = ref(null)
const dontShowAgain = ref(true)
const interactive = ref(false)
const panelScale = ref(1)
let readyPollId = 0
let resizeObserver = null

const CHANGE_GROUPS = [
  { tag: "NEW", label: "New", order: 0 },
  { tag: "EXPANDED", label: "Expanded", order: 1 },
  { tag: "REWORKED", label: "Reworked", order: 2 },
  { tag: "UPDATED", label: "Updated", order: 3 },
  { tag: "REDESIGNED", label: "Redesigned", order: 4 },
]

const changeGroups = computed(() => {
  const groups = CHANGE_GROUPS.map(group => ({
    ...group,
    changes: summary.value.changes.filter(change => change.tag === group.tag),
  })).filter(group => group.changes.length > 0)

  groups.sort((a, b) => b.changes.length - a.changes.length || a.order - b.order)

  const recognizedTags = new Set(CHANGE_GROUPS.map(group => group.tag))
  const otherChanges = summary.value.changes.filter(change => !recognizedTags.has(change.tag))
  if (otherChanges.length > 0) {
    groups.push({ tag: "OTHER", label: "Other changes", order: CHANGE_GROUPS.length, changes: otherChanges })
    groups.sort((a, b) => b.changes.length - a.changes.length || a.order - b.order)
  }

  return groups
})

function normalizePayload(raw) {
  if (Array.isArray(raw)) raw = raw[0]
  if (!raw || typeof raw !== "object") return null
  if (!raw.enabled || !raw.id || !Array.isArray(raw.changes) || raw.changes.length === 0) return null
  return raw
}

function storageKey(cycleId) {
  return `${STORAGE_PREFIX}${cycleId}`
}

function wasSeen(cycleId) {
  try {
    return window.localStorage.getItem(storageKey(cycleId)) === "true"
  } catch (_) {
    return false
  }
}

function rememberSeen(cycleId) {
  try {
    window.localStorage.setItem(storageKey(cycleId), "true")
  } catch (_) {
    // Storage may be unavailable in restricted UI contexts; dismissal still works.
  }
}

function forgetSeen(cycleId) {
  try {
    window.localStorage.removeItem(storageKey(cycleId))
  } catch (_) {
    // Storage may be unavailable in restricted UI contexts.
  }
}

function stopReadyPoll() {
  if (!readyPollId) return
  window.clearInterval(readyPollId)
  readyPollId = 0
}

function setInteractive(ready) {
  if (interactive.value && ready !== true) return
  const wasInteractive = interactive.value
  interactive.value = ready === true
  if (interactive.value) stopReadyPoll()
  if (interactive.value && !wasInteractive) {
    nextTick(() => {
      continueButton.value?.focus({ preventScroll: true })
    })
  }
}

async function pollUntilReady() {
  if (interactive.value) return
  try {
    const ready = await lua.career_modules_betaWelcome.isCareerUiReady()
    if (ready) setInteractive(true)
  } catch (_) {
    // Career module unavailable outside an active career.
  }
}

function startReadyPoll() {
  if (interactive.value || readyPollId) return
  pollUntilReady()
  readyPollId = window.setInterval(pollUntilReady, 250)
}

function fitPanel() {
  const overlay = dialogRoot.value
  const panel = panelRoot.value
  if (!overlay || !panel) return
  panelScale.value = 1
  nextTick(() => {
    requestAnimationFrame(() => {
      const host = dialogRoot.value
      const content = panelRoot.value
      if (!host || !content) return
      const pad = 16
      const availW = Math.max(1, host.clientWidth - pad)
      const availH = Math.max(1, host.clientHeight - pad)
      const needW = Math.max(content.scrollWidth, content.offsetWidth)
      const needH = Math.max(content.scrollHeight, content.offsetHeight)
      const scale = Math.min(1, availW / needW, availH / needH)
      panelScale.value = Math.max(0.55, Number.isFinite(scale) ? scale : 1)
    })
  })
}

function bindResizeObserver() {
  if (resizeObserver || typeof ResizeObserver === "undefined") return
  resizeObserver = new ResizeObserver(() => fitPanel())
  if (dialogRoot.value) resizeObserver.observe(dialogRoot.value)
  if (panelRoot.value) resizeObserver.observe(panelRoot.value)
}

function unbindResizeObserver() {
  if (!resizeObserver) return
  resizeObserver.disconnect()
  resizeObserver = null
}

function show(raw) {
  const data = normalizePayload(raw)
  if (!data || (!data.force && wasSeen(data.id))) return

  const ready = data.interactive === true
  if (open.value && summary.value.id === data.id) {
    summary.value = data
    setInteractive(ready)
    if (!interactive.value) startReadyPoll()
    nextTick(fitPanel)
    return
  }

  summary.value = data
  dontShowAgain.value = true
  open.value = true
  setInteractive(ready)
  nextTick(() => {
    bindResizeObserver()
    fitPanel()
    if (interactive.value) {
      continueButton.value?.focus({ preventScroll: true })
    } else {
      dialogRoot.value?.focus({ preventScroll: true })
    }
  })
  if (!interactive.value) startReadyPoll()
}

function dismiss() {
  if (!interactive.value) return
  stopReadyPoll()
  unbindResizeObserver()
  if (summary.value.id) {
    if (dontShowAgain.value) {
      rememberSeen(summary.value.id)
    } else {
      forgetSeen(summary.value.id)
    }
  }
  open.value = false
  panelScale.value = 1
}

function onEsc() {
  dismiss()
}

function onBackdrop() {
  dismiss()
}

async function requestCurrentCycle() {
  try {
    const data = await lua.career_modules_betaWelcome.requestSplash(false)
    show(data)
  } catch (_) {
    // The career module is intentionally unavailable outside an active career.
  }
}

onMounted(() => {
  bridge.events.on(EVENT_NAME, show)
  if (window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.on(EVENT_NAME, show)
  }
  requestCurrentCycle()
})

onBeforeUnmount(() => {
  stopReadyPoll()
  unbindResizeObserver()
  bridge.events.off(EVENT_NAME, show)
  if (window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.off(EVENT_NAME, show)
  }
})

watch(interactive, () => nextTick(fitPanel))
watch(changeGroups, () => nextTick(fitPanel))
</script>

<style scoped lang="scss">
.beta-cycle-overlay {
  position: fixed;
  inset: 0;
  z-index: 13900;
  display: grid;
  place-items: center;
  overflow: hidden;
  padding: 0.75rem;
  color: #f7f7f7;
  font-family: "Overpass", "Noto Sans", sans-serif;
  pointer-events: auto;
  background:
    radial-gradient(circle at 12% 10%, rgba(255, 105, 32, 0.2), transparent 35%),
    rgba(8, 10, 13, 0.92);

  &:focus {
    outline: none;
  }
}

.beta-cycle-overlay--ready {
  z-index: 14500;
}

.beta-cycle-scale {
  width: min(96rem, 100%);
  transform-origin: center center;
}

.beta-cycle-panel {
  display: flex;
  flex-direction: column;
  width: 100%;
  overflow: hidden;
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-top: 0.28rem solid #ff6b20;
  border-radius: 0.75rem;
  background: linear-gradient(145deg, rgba(32, 36, 42, 0.98), rgba(17, 20, 24, 0.98));
  box-shadow: 0 1.5rem 5rem rgba(0, 0, 0, 0.55);
}

.beta-cycle-header {
  display: flex;
  flex: 0 0 auto;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1.25rem;
  padding: 1rem 1.25rem 0.85rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);

  h1 {
    margin: 0.1rem 0 0.3rem;
    font-size: clamp(1.45rem, 2.6vw, 2.2rem);
    line-height: 1;
    letter-spacing: -0.04em;
  }
}

.beta-cycle-eyebrow {
  margin: 0;
  color: #ff8b4c;
  font-size: 0.7rem;
  font-weight: 800;
  letter-spacing: 0.16em;
}

.beta-cycle-intro {
  max-width: 46rem;
  margin: 0;
  color: rgba(255, 255, 255, 0.68);
  font-size: 0.92rem;
}

.beta-cycle-version {
  flex: 0 0 auto;
  padding: 0.4rem 0.7rem;
  border: 1px solid rgba(255, 139, 76, 0.42);
  border-radius: 999px;
  color: #ffc5a5;
  background: rgba(255, 107, 32, 0.11);
  font-weight: 700;
  white-space: nowrap;
}

.beta-cycle-sections {
  display: grid;
  gap: 0.7rem;
  padding: 0.85rem 1.25rem;
}

.beta-cycle-section {
  min-width: 0;
}

.beta-cycle-section-title {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  margin: 0 0 0.45rem;
  color: #ff9b65;
  font-size: 0.7rem;
  font-weight: 800;
  letter-spacing: 0.14em;
  text-transform: uppercase;

  &::after {
    flex: 1;
    height: 1px;
    content: "";
    background: rgba(255, 255, 255, 0.12);
  }

  span {
    display: grid;
    place-items: center;
    width: 1.2rem;
    height: 1.2rem;
    border-radius: 999px;
    color: #17191c;
    background: #ff9b65;
    font-size: 0.65rem;
    letter-spacing: 0;
  }
}

.beta-cycle-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.5rem;
}

.beta-cycle-change {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 0.65rem;
  min-width: 0;
  padding: 0.7rem 0.8rem;
  border: 1px solid rgba(255, 255, 255, 0.09);
  border-radius: 0.45rem;
  background: rgba(255, 255, 255, 0.035);
}

.beta-cycle-change-number {
  display: grid;
  place-items: center;
  width: 1.9rem;
  height: 1.9rem;
  border-radius: 0.35rem;
  color: #16191d;
  background: #ff792f;
  font-size: 0.72rem;
  font-weight: 900;
}

.beta-cycle-change-copy {
  min-width: 0;

  h3 {
    margin: 0 0 0.18rem;
    font-size: 0.95rem;
    line-height: 1.2;
  }

  p {
    margin: 0;
    color: rgba(255, 255, 255, 0.67);
    font-size: 0.8rem;
    line-height: 1.35;
  }
}

.beta-cycle-footer {
  display: flex;
  flex: 0 0 auto;
  align-items: center;
  justify-content: space-between;
  gap: 1.25rem;
  padding: 0.85rem 1.25rem 1rem;
  border-top: 1px solid rgba(255, 255, 255, 0.1);

  p {
    margin: 0;
    color: rgba(255, 255, 255, 0.58);
    font-size: 0.8rem;
  }
}

.beta-cycle-actions {
  display: flex;
  flex: 0 0 auto;
  align-items: flex-end;
  flex-direction: column;
  gap: 0.65rem;
}

.beta-cycle-preference {
  display: flex;
  align-items: center;
  gap: 0.55rem;
  color: rgba(255, 255, 255, 0.75);
  font-size: 0.82rem;
  cursor: pointer;
  user-select: none;

  input {
    width: 1rem;
    height: 1rem;
    margin: 0;
    accent-color: #ff792f;
    cursor: pointer;
  }

  input:focus-visible {
    outline: 0.15rem solid rgba(255, 150, 93, 0.7);
    outline-offset: 0.15rem;
  }
}

.beta-cycle-continue {
  flex: 0 0 auto;
  min-width: 9.5rem;
  padding: 0.78rem 1.25rem;
  border: 0;
  border-radius: 0.45rem;
  color: #17191c;
  background: #ff792f;
  font: inherit;
  font-weight: 800;
  cursor: pointer;
  transition: transform 120ms ease, background 120ms ease, box-shadow 120ms ease;

  &:hover:not(:disabled),
  &:focus-visible:not(:disabled) {
    outline: none;
    background: #ff965d;
    box-shadow: 0 0 0 0.18rem rgba(255, 150, 93, 0.35);
    transform: translateY(-1px);
  }

  &:disabled {
    cursor: wait;
    color: rgba(23, 25, 28, 0.7);
    background: #c88963;
    box-shadow: none;
    transform: none;
  }
}

.beta-cycle-fade-enter-active,
.beta-cycle-fade-leave-active {
  transition: opacity 280ms ease;
}

.beta-cycle-fade-enter-from,
.beta-cycle-fade-leave-to {
  opacity: 0;
}

@media (max-width: 760px) {
  .beta-cycle-header,
  .beta-cycle-footer {
    align-items: stretch;
    flex-direction: column;
  }

  .beta-cycle-version {
    align-self: flex-start;
  }

  .beta-cycle-grid {
    grid-template-columns: 1fr;
  }

  .beta-cycle-continue {
    width: 100%;
  }

  .beta-cycle-actions {
    align-items: stretch;
    width: 100%;
  }
}
</style>
