<template>
  <Teleport to="body">
    <Transition name="wn-fade">
      <div
        v-if="visible"
        ref="dialogRoot"
        class="wn-overlay"
        :class="{ 'wn-overlay--ready': interactive }"
        role="dialog"
        aria-modal="true"
        :aria-label="summary.label ? `What's new in ${summary.label}` : `What's new`"
        tabindex="-1"
        @keydown.esc.prevent="onEsc"
        @keydown.left.prevent="go(index - 1)"
        @keydown.right.prevent="go(index + 1)"
      >
        <div ref="card" class="wn-card" :style="{ fontSize: `${unit}px` }" @click.stop>
          <section
            v-for="(slide, i) in slides"
            :key="i"
            class="wn-slide"
            :class="[`wn-slide--${slide.kind || 'photo'}`, { 'is-active': i === index }]"
            :aria-hidden="i !== index"
          >
            <div class="wn-slide__photo" :style="photoStyle(slide)"></div>

            <template v-if="slide.kind === 'intro'">
              <div class="wn-vignette"></div>
              <div class="wn-scrim-left"></div>
              <div class="wn-txt wn-txt--tl wn-txt--intro">
                <div class="wn-kicker wn-kicker--log">
                  <span class="wn-log-glyph" aria-hidden="true"><i></i><i></i><i></i></span>
                  {{ slide.eyebrow || "Update log" }}
                </div>
                <h2>{{ slide.title }}</h2>
                <p v-if="slide.subtitle" class="wn-intro-subtitle">{{ slide.subtitle }}</p>
                <p v-if="slide.summary">{{ slide.summary }}</p>
                <div v-if="slide.contents !== false && contents.length" class="wn-toc">
                  <div class="wn-toc__label">{{ slide.contentsLabel || "In this update" }}</div>
                  <ol>
                    <li v-for="(entry, k) in contents" :key="k">
                      <button
                        type="button"
                        class="wn-toc__link"
                        data-focusable
                        :disabled="!interactive"
                        @click.stop="go(entry.index)"
                      >
                        <span class="wn-toc__num">{{ String(k + 1).padStart(2, "0") }}</span>
                        <span class="wn-toc__title">{{ entry.title }}</span>
                      </button>
                    </li>
                  </ol>
                </div>
              </div>
            </template>

            <template v-else-if="slide.kind === 'list'">
              <div class="wn-vignette"></div>
              <div class="wn-scrim-full"></div>
              <div class="wn-grid" :style="{ gridTemplateColumns: `repeat(${(slide.columns || []).length || 1}, 1fr)` }">
                <h2>{{ slide.title }}</h2>
                <p v-if="slide.lead" class="wn-grid__lead">{{ slide.lead }}</p>
                <div v-for="(col, c) in slide.columns || []" :key="c" class="wn-col">
                  <h3>{{ col.heading }}</h3>
                  <ul>
                    <li v-for="(item, k) in col.items || []" :key="k">{{ item }}</li>
                  </ul>
                </div>
              </div>
            </template>

            <template v-else>
              <div class="wn-vignette"></div>
              <div v-if="side(slide) === 'bottom-left'" class="wn-scrim-bottom"></div>
              <div v-else class="wn-scrim-left"></div>
              <div class="wn-txt" :class="side(slide) === 'bottom-left' ? 'wn-txt--bl' : 'wn-txt--tl'">
                <div class="wn-kicker">{{ photoKicker(slide, i) }}</div>
                <h2>{{ slide.title }}</h2>
                <p v-if="slide.summary">{{ slide.summary }}</p>
                <ul v-if="slide.facts && slide.facts.length" class="wn-facts">
                  <li v-for="(fact, k) in slide.facts" :key="k">{{ fact }}</li>
                </ul>
              </div>
            </template>
          </section>

          <div class="wn-bar"></div>
          <div class="wn-version">{{ summary.label }}</div>

          <div class="wn-nav" v-if="slides.length > 1">
            <button type="button" class="wn-ghost" data-focusable :disabled="!interactive" @click.stop="go(index - 1)">Prev</button>
            <div class="wn-dots">
              <button
                v-for="(slide, i) in slides"
                :key="i"
                type="button"
                :class="{ 'is-active': i === index }"
                :aria-label="`Slide ${i + 1}`"
                :disabled="!interactive"
                @click.stop="go(i)"
              ></button>
            </div>
            <button type="button" class="wn-ghost" data-focusable :disabled="!interactive" @click.stop="go(index + 1)">
              {{ index === slides.length - 1 ? "Back to start" : "Next" }}
            </button>
          </div>

          <div class="wn-ctrl">
            <label class="wn-check">
              <input v-model="dontShowAgain" type="checkbox" data-focusable :disabled="!interactive" />
              <span>{{ summary.dontShowLabel || "Don't show again" }}</span>
            </label>
            <button
              ref="continueButton"
              type="button"
              class="wn-continue"
              data-focusable
              :disabled="!interactive"
              @click.stop="dismiss"
            >
              {{ interactive ? (summary.continueLabel || "Continue") : (summary.loadingLabel || "Loading career...") }}
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { lua, useBridge } from "@/bridge"
import { loadingScreen } from "@/services/screenCover"

// The typed `lua` proxy only knows the extensions baked into the game build, so
// fall back to the engine call for this mod module.
function callLua(code, cb) {
  try {
    if (window.bngApi && typeof window.bngApi.engineLua === "function") {
      window.bngApi.engineLua(code, cb)
      return true
    }
  } catch (_) {}
  return false
}

// Content comes from /ui/modules/whatsnew/<folder>/slides.json via
// career_modules_betaWelcome. This component only renders it.

const STORAGE_PREFIX = "rls-career-overhaul:beta-cycle-seen:"
const EVENT_NAME = "RlsBetaCycleSplashShow"

const bridge = useBridge()
const open = ref(false)
const summary = ref({ slides: [] })
const index = ref(0)
const dialogRoot = ref(null)
const card = ref(null)
const continueButton = ref(null)
const dontShowAgain = ref(false)
const interactive = ref(false)
// `shown` stays true through the loading screen's fade-out.
const visible = computed(() => open.value && interactive.value && !loadingScreen.active && !loadingScreen.shown)
const unit = ref(12)
let readyPollId = 0
let resizeObserver = null

const slides = computed(() => (Array.isArray(summary.value.slides) ? summary.value.slides : []))
const photoSlides = computed(() => slides.value.filter(s => !s.kind || s.kind === "photo"))
// Table of contents for the intro: every non-intro slide title, in order.
const contents = computed(() =>
  slides.value
    .map((s, i) => ({ title: s.title, index: i }))
    .filter(e => slides.value[e.index].kind !== "intro" && e.title)
)

function side(slide) {
  return slide.textSide === "bottom-left" ? "bottom-left" : "top-left"
}

function photoKicker(slide, i) {
  const n = photoSlides.value.indexOf(slides.value[i]) + 1
  const total = photoSlides.value.length
  const label = slide.kicker ? ` · ${slide.kicker}` : ""
  return total > 1 ? `${n} of ${total}${label}` : slide.kicker || ""
}

function imageUrl(slide) {
  if (!slide || !slide.image) return ""
  if (/^(https?:)?\/\//.test(slide.image) || slide.image.startsWith("/")) return slide.image
  return `${summary.value.imageBase || ""}${slide.image}`
}

function photoStyle(slide) {
  const url = imageUrl(slide)
  const style = url ? { backgroundImage: `url("${url}")` } : {}
  if (slide.imagePosition) style.backgroundPosition = slide.imagePosition
  // imageScale > 1 zooms the photo (anchored at imagePosition) to crop out an edge
  let scale = slide.imageScale && slide.imageScale !== 1 ? slide.imageScale : 1
  // imageBlur (px at 1080p, scaled with the card) softens a busy photo behind dense text
  if (slide.imageBlur) {
    style.filter = `blur(${(slide.imageBlur * unit.value) / 10}px)`
    scale = Math.max(scale, 1.06) // hide the blurred edge
  }
  if (scale !== 1) {
    style.transform = `scale(${scale})`
    style.transformOrigin = slide.imagePosition || "center"
  }
  return style
}

function preloadImages() {
  slides.value.forEach(slide => {
    const url = imageUrl(slide)
    if (!url) return
    const img = new Image()
    img.src = url
  })
}

function go(n) {
  const count = slides.value.length
  if (!count) return
  index.value = ((n % count) + count) % count
}

function normalizePayload(raw) {
  if (Array.isArray(raw)) raw = raw[0]
  if (!raw || typeof raw !== "object") return null
  if (!raw.enabled || !raw.id || !Array.isArray(raw.slides) || raw.slides.length === 0) return null
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
  interactive.value = ready === true
  if (interactive.value) stopReadyPoll()
}

async function pollUntilReady() {
  if (interactive.value) return
  try {
    const mod = lua && lua.career_modules_betaWelcome
    if (mod && typeof mod.isCareerUiReady === "function") {
      const ready = await mod.isCareerUiReady()
      if (ready) setInteractive(true)
      return
    }
  } catch (_) {
    // fall through to the engine call
  }
  callLua("return career_modules_betaWelcome and career_modules_betaWelcome.isCareerUiReady()", ready => {
    if (ready === true) setInteractive(true)
  })
}

function startReadyPoll() {
  if (interactive.value || readyPollId) return
  pollUntilReady()
  readyPollId = window.setInterval(pollUntilReady, 250)
}

// 1em inside the card = card width / 116 (never below 9px), so every size in the SCSS is
// proportional to the card and 720p / 1440p look identical. Raise the divisor
// to make everything smaller.
function fitUnit() {
  const el = card.value
  if (!el) return
  const w = el.clientWidth || window.innerWidth
  unit.value = Math.max(9, Math.round(w / 116))
  snapToPixels(el)
}

// Centering can leave the card on a half pixel, which blurs text in CEF.
function snapToPixels(el) {
  el.style.transform = ""
  const r = el.getBoundingClientRect()
  const dx = Math.round(r.left) - r.left
  const dy = Math.round(r.top) - r.top
  if (dx || dy) el.style.transform = `translate(${dx}px, ${dy}px)`
}

function bindResizeObserver() {
  if (resizeObserver || typeof ResizeObserver === "undefined") return
  resizeObserver = new ResizeObserver(() => fitUnit())
  if (card.value) resizeObserver.observe(card.value)
}

function unbindResizeObserver() {
  if (!resizeObserver) return
  resizeObserver.disconnect()
  resizeObserver = null
}

function show(raw) {
  const data = normalizePayload(raw)
  if (!data) return
  if (!data.force && !data.preview && wasSeen(data.id)) return

  const ready = data.interactive === true
  if (open.value && summary.value.id === data.id && !data.preview) {
    summary.value = data
    setInteractive(ready)
    if (!interactive.value) startReadyPoll()
    nextTick(fitUnit)
    return
  }

  summary.value = data
  index.value = 0
  dontShowAgain.value = false
  open.value = true
  interactive.value = false
  setInteractive(ready)
  preloadImages()
  if (!interactive.value) startReadyPoll()
}

function dismiss() {
  if (!interactive.value) return
  stopReadyPoll()
  unbindResizeObserver()
  if (summary.value.id && !summary.value.preview) {
    if (dontShowAgain.value) {
      rememberSeen(summary.value.id)
    } else {
      forgetSeen(summary.value.id)
    }
  }
  open.value = false
}

function onEsc() {
  dismiss()
}

// Ask Lua whether a splash is due. requestSplash() also fires the
// RlsBetaCycleSplashShow hook, so the answer arrives through the event bus.
function requestCurrentCycle() {
  try {
    const mod = lua && lua.career_modules_betaWelcome
    if (mod && typeof mod.requestSplash === "function") {
      mod.requestSplash(false).then(show).catch(() => {})
      return
    }
  } catch (_) {
    // fall through to the engine call
  }
  callLua("if career_modules_betaWelcome then career_modules_betaWelcome.requestSplash(false) end")
}

onMounted(() => {
  bridge.events.on(EVENT_NAME, show)
  if (window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.on(EVENT_NAME, show)
  }
  window.addEventListener("resize", fitUnit)
  requestCurrentCycle()
})

onBeforeUnmount(() => {
  stopReadyPoll()
  unbindResizeObserver()
  window.removeEventListener("resize", fitUnit)
  bridge.events.off(EVENT_NAME, show)
  if (window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.off(EVENT_NAME, show)
  }
})

watch(visible, async shown => {
  if (!shown) {
    unbindResizeObserver()
    return
  }
  await nextTick()
  if (!visible.value) return
  bindResizeObserver()
  fitUnit()
  continueButton.value?.focus({ preventScroll: true })
})
</script>

<style scoped lang="scss">
$orange: #ff792f;

.wn-overlay {
  position: fixed;
  inset: 0;
  z-index: 13900;
  display: grid;
  place-items: center;
  overflow: hidden;
  padding: 1.5rem;
  color: #fff;
  font-family: "Overpass", "Noto Sans", sans-serif;
  pointer-events: auto;
  background: rgba(6, 8, 10, 0.86);

  &:focus {
    outline: none;
  }
}

.wn-overlay--ready {
  z-index: 14500;
}

// The card keeps a 16:9 frame and fits whichever viewport side is tighter.
.wn-card {
  position: relative;
  width: min(calc(100vw - 6rem), calc((100vh - 6rem) * 16 / 9), 88rem);
  aspect-ratio: 16 / 9;
  overflow: hidden;
  border-radius: 0.75rem;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background: #000;
  box-shadow: 0 1.5rem 5rem rgba(0, 0, 0, 0.6);
  line-height: 1.3;
  text-rendering: optimizeLegibility;
  -webkit-font-smoothing: antialiased;
}

.wn-slide {
  position: absolute;
  inset: 0;
  opacity: 0;
  transition: opacity 350ms ease;
  pointer-events: none;

  &.is-active {
    opacity: 1;
    pointer-events: auto;
  }
}

.wn-slide__photo {
  position: absolute;
  inset: 0;
  background-size: cover;
  background-position: center;
}

// Darkening layers: long multi-stop fades, never a hard edge.
.wn-vignette {
  position: absolute;
  inset: 0;
  background: radial-gradient(ellipse at 55% 45%, rgba(0, 0, 0, 0) 35%, rgba(0, 0, 0, 0.18) 65%, rgba(0, 0, 0, 0.5) 100%);
}

.wn-scrim-left {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  width: 78%;
  background: linear-gradient(to right, rgba(0, 0, 0, 0.66) 0%, rgba(0, 0, 0, 0.52) 22%, rgba(0, 0, 0, 0.32) 48%, rgba(0, 0, 0, 0.12) 76%, rgba(0, 0, 0, 0) 100%);
}

.wn-scrim-bottom {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  height: 80%;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.78) 0%, rgba(0, 0, 0, 0.58) 22%, rgba(0, 0, 0, 0.32) 50%, rgba(0, 0, 0, 0.1) 78%, rgba(0, 0, 0, 0) 100%);
}

.wn-scrim-full {
  position: absolute;
  inset: 0;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.72) 0%, rgba(0, 0, 0, 0.6) 30%, rgba(0, 0, 0, 0.42) 60%, rgba(0, 0, 0, 0.28) 100%);
}

.wn-txt {
  position: absolute;
  z-index: 0;
  width: 46em;
  max-width: 60%;

  // soft halo behind the text; closest-side sizing guarantees it reaches
  // transparent before the box edge, so no seam
  &::before {
    content: "";
    position: absolute;
    inset: -9em -22em -9em -14em;
    z-index: -1;
    background: radial-gradient(closest-side at 40% 50%, rgba(0, 0, 0, 0.5) 0%, rgba(0, 0, 0, 0.38) 28%, rgba(0, 0, 0, 0.2) 58%, rgba(0, 0, 0, 0.06) 84%, rgba(0, 0, 0, 0) 100%);
  }

  h2 {
    margin: 0;
    font-size: 3.4em;
    font-weight: 700;
    line-height: 1.02;
    letter-spacing: -0.02em;
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.55);
  }

  p {
    margin: 0.55em 0 0;
    font-size: 1.45em;
    font-weight: 400;
    line-height: 1.35;
    color: rgba(255, 255, 255, 0.9);
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
  }
}

.wn-txt--tl {
  left: 5em;
  top: 5em;
}

.wn-txt--bl {
  left: 5em;
  bottom: 9.5em;
}

.wn-txt--intro {
  width: 50em;

  h2 {
    font-size: 2.7em;
  }
}

.wn-kicker--log {
  display: flex;
  align-items: center;
  gap: 0.6em;
}

.wn-log-glyph {
  display: inline-grid;
  gap: 0.18em;
  width: 1.1em;

  i {
    display: block;
    height: 0.16em;
    border-radius: 0.08em;
    background: $orange;

    &:nth-child(2) {
      width: 70%;
    }

    &:nth-child(3) {
      width: 85%;
    }
  }
}

.wn-intro-subtitle {
  margin-top: 0.35em !important;
  font-size: 1.15em !important;
  font-weight: 600 !important;
  color: rgba(255, 255, 255, 0.72) !important;
}

.wn-toc {
  margin-top: 1.4em;

  ol {
    margin: 0;
    padding: 0;
    list-style: none;
    display: grid;
    gap: 0.45em;
  }

  li {
    font-size: 1.05em;
  }
}

.wn-toc__link {
  display: flex;
  align-items: baseline;
  gap: 0.8em;
  width: 100%;
  margin: 0 -0.5em;
  padding: 0.15em 0.5em;
  border: 0;
  border-radius: 0.3em;
  background: transparent;
  color: rgba(255, 255, 255, 0.86);
  font: inherit;
  text-align: left;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
  cursor: pointer;

  &:hover:not(:disabled),
  &:focus-visible:not(:disabled) {
    outline: none;
    background: rgba(255, 255, 255, 0.1);
    color: #fff;
  }

  &:hover:not(:disabled) .wn-toc__title,
  &:focus-visible:not(:disabled) .wn-toc__title {
    text-decoration: underline;
    text-underline-offset: 0.15em;
    text-decoration-color: rgba(255, 121, 47, 0.8);
  }

  &:disabled {
    cursor: default;
  }
}

.wn-toc__label {
  margin-bottom: 0.6em;
  padding-bottom: 0.5em;
  border-bottom: 1px solid rgba(255, 255, 255, 0.18);
  font-size: 0.8em;
  font-weight: 700;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.6);
}

.wn-toc__num {
  flex: 0 0 1.6em;
  font-weight: 700;
  color: $orange;
}

.wn-kicker {
  margin-bottom: 0.5em;
  font-size: 0.9em;
  font-weight: 700;
  letter-spacing: 0.16em;
  text-transform: uppercase;
  color: $orange;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
}

.wn-facts {
  margin: 1em 0 0;
  padding: 0;
  list-style: none;
  display: grid;
  gap: 0.5em;

  li {
    display: flex;
    align-items: flex-start;
    gap: 0.7em;
    font-size: 1.2em;
    line-height: 1.3;
    color: rgba(255, 255, 255, 0.82);
    text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);

    &::before {
      content: "";
      flex: 0 0 auto;
      width: 0.2em;
      height: 1em;
      margin-top: 0.15em;
      border-radius: 0.1em;
      background: $orange;
    }
  }
}

// "Everything else" page
.wn-grid {
  position: absolute;
  z-index: 0;
  left: 5em;
  right: 5em;
  top: 5em;
  bottom: 9.5em;
  display: grid;
  gap: 3em;
  align-content: start;

  &::before {
    content: "";
    position: absolute;
    inset: -8em -10em;
    z-index: -1;
    background: radial-gradient(closest-side at 50% 45%, rgba(0, 0, 0, 0.45) 0%, rgba(0, 0, 0, 0.28) 55%, rgba(0, 0, 0, 0.08) 85%, rgba(0, 0, 0, 0) 100%);
  }

  h2 {
    grid-column: 1 / -1;
    margin: 0;
    font-size: 3.2em;
    font-weight: 700;
    line-height: 1.02;
    letter-spacing: -0.02em;
  }
}

.wn-grid__lead {
  grid-column: 1 / -1;
  margin: -1.5em 0 0;
  font-size: 1.4em;
  color: rgba(255, 255, 255, 0.8);
}

.wn-col {
  h3 {
    margin: 0 0 0.8em;
    padding-bottom: 0.6em;
    border-bottom: 0.1em solid rgba(255, 255, 255, 0.18);
    font-size: 1.05em;
    font-weight: 700;
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: $orange;
  }

  ul {
    margin: 0;
    padding: 0;
    list-style: none;
    display: grid;
    gap: 0.55em;
  }

  li {
    display: flex;
    gap: 0.7em;
    font-size: 1.2em;
    line-height: 1.3;
    color: rgba(255, 255, 255, 0.88);

    &::before {
      content: "";
      flex: 0 0 auto;
      width: 0.2em;
      height: 1em;
      margin-top: 0.15em;
      border-radius: 0.1em;
      background: $orange;
    }
  }
}

// Chrome
.wn-bar {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  height: 12em;
  pointer-events: none;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.85) 0%, rgba(0, 0, 0, 0.6) 30%, rgba(0, 0, 0, 0.28) 62%, rgba(0, 0, 0, 0.06) 88%, rgba(0, 0, 0, 0) 100%);
}

.wn-version {
  position: absolute;
  left: 3em;
  bottom: 3em;
  font-size: 0.8em;
  font-weight: 700;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.6);
}

.wn-nav {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 2.4em;
  width: max-content;
  margin: 0 auto;
  display: flex;
  align-items: center;
  gap: 1.2em;
}

.wn-ghost {
  padding: 0.5em 1.1em;
  border: 1px solid rgba(255, 255, 255, 0.55);
  border-radius: 0.4em;
  background: rgba(0, 0, 0, 0.35);
  color: #fff;
  font: inherit;
  font-size: 0.9em;
  font-weight: 700;
  cursor: pointer;

  &:hover:not(:disabled),
  &:focus-visible:not(:disabled) {
    outline: none;
    border-color: #fff;
    background: rgba(255, 255, 255, 0.12);
  }

  &:disabled {
    opacity: 0.45;
    cursor: default;
  }
}

.wn-dots {
  display: flex;
  gap: 0.7em;

  button {
    width: 0.6em;
    height: 0.6em;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.45);
    cursor: pointer;

    &.is-active {
      background: $orange;
      box-shadow: 0 0 0 0.22em rgba(255, 121, 47, 0.28);
    }
  }
}

.wn-ctrl {
  position: absolute;
  right: 3em;
  bottom: 2.4em;
  display: flex;
  align-items: center;
  gap: 1.5em;
}

.wn-check {
  display: flex;
  align-items: center;
  gap: 0.5em;
  font-size: 0.9em;
  font-weight: 500;
  color: rgba(255, 255, 255, 0.88);
  cursor: pointer;
  user-select: none;
  text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);

  input {
    width: 1.2em;
    height: 1.2em;
    margin: 0;
    accent-color: $orange;
    cursor: pointer;
  }

  input:focus-visible {
    outline: 0.15em solid rgba(255, 150, 93, 0.7);
    outline-offset: 0.15em;
  }
}

.wn-continue {
  padding: 0.6em 1.5em;
  border: 0;
  border-radius: 0.4em;
  background: $orange;
  color: #17191c;
  font: inherit;
  font-size: 0.95em;
  font-weight: 700;
  cursor: pointer;
  box-shadow: 0 0.5em 1.5em rgba(0, 0, 0, 0.5);
  transition: transform 120ms ease, background 120ms ease, box-shadow 120ms ease;

  &:hover:not(:disabled),
  &:focus-visible:not(:disabled) {
    outline: none;
    background: #ff965d;
    box-shadow: 0 0 0 0.18em rgba(255, 150, 93, 0.35), 0 0.5em 1.5em rgba(0, 0, 0, 0.5);
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

.wn-fade-enter-active,
.wn-fade-leave-active {
  transition: opacity 280ms ease;
}

.wn-fade-enter-from,
.wn-fade-leave-to {
  opacity: 0;
}
</style>
