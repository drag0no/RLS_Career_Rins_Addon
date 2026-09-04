<template>
  <div v-bng-scoped-nav="{ activateOnMount: true }" class="profiles-container" @wheel="onWheel" @deactivate="onDeactivate">
    <BngScreenHeading class="profiles-title" :preheadings="[$ctx_t('ui.playmodes.career')]">{{ $ctx_t("ui.career.savedProgress") }} </BngScreenHeading>
    <BackAside v-bng-on-ui-nav:back,menu="navigateToMainMenu" class="profiles-back" @click="navigateToMainMenu" />

    <div class="profiles-panel">
      <!-- Search, sort and filter over nothing are three dead controls between a
           first-time player and the only button that matters. -->
      <div v-if="showToolbar" class="profiles-toolbar">
        <div class="pt-search">
          <input
            v-model="searchQuery"
            class="pt-input"
            placeholder="Search profiles..."
            :disabled="createCardActive"
            @focus="onSearchFocus"
            @blur="onSearchBlur" />
        </div>

        <div class="pt-controls">
          <div ref="sortDropdownRef" class="pt-dropdown">
            <button type="button" class="pt-trigger" @click.stop="toggleSort" @mousedown.stop>
              <span>{{ selectedSortLabel }}</span>
              <span class="pt-chevron">&#x25BE;</span>
            </button>
            <teleport to="body">
              <div v-if="sortOpen" class="pt-menu" :style="sortStyle" @click.stop @mousedown.stop>
                <div
                  v-for="opt in sortOptions"
                  :key="opt.value"
                  class="pt-option"
                  :class="{ 'pt-option--active': opt.value === sortMode }"
                  @click.stop="selectSort(opt.value)"
                  @mousedown.stop>
                  {{ opt.label }}
                </div>
              </div>
            </teleport>
          </div>

          <div ref="filterDropdownRef" class="pt-dropdown">
            <button type="button" class="pt-trigger" @click.stop="toggleFilter" @mousedown.stop>
              <span>Filter{{ activeFilterCount > 0 ? ` (${activeFilterCount})` : '' }}</span>
              <span class="pt-chevron">&#x25BE;</span>
            </button>
            <teleport to="body">
              <div v-if="filterOpen" class="pt-menu pt-menu--filter" :style="filterStyle" @click.stop @mousedown.stop>
                <div class="pt-filter-group">
                  <div class="pt-filter-heading">Path</div>
                  <label v-for="p in pathFilterOptions" :key="p" class="pt-check">
                    <input type="checkbox" :checked="activePaths.has(p)" @change="togglePathFilter(p)" />
                    <span>{{ p }}</span>
                  </label>
                </div>
                <div class="pt-filter-sep" />
                <div class="pt-filter-group">
                  <div class="pt-filter-heading">Difficulty</div>
                  <label v-for="d in difficultyFilterOptions" :key="d" class="pt-check">
                    <input type="checkbox" :checked="activeDifficulties.has(d)" @change="toggleDifficultyFilter(d)" />
                    <span>{{ d }}</span>
                  </label>
                </div>
                <div v-if="challengeFilterOptions.length" class="pt-filter-sep" />
                <div v-if="challengeFilterOptions.length" class="pt-filter-group">
                  <div class="pt-filter-heading">Story</div>
                  <label v-for="c in challengeFilterOptions" :key="c" class="pt-check">
                    <input type="checkbox" :checked="activeChallenges.has(c)" @change="toggleChallengeFilter(c)" />
                    <span>{{ c }}</span>
                  </label>
                </div>
                <div v-if="activeFilterCount > 0" class="pt-filter-sep" />
                <button v-if="activeFilterCount > 0" class="pt-clear-btn" @click.stop="clearFilters" @mousedown.stop>Clear All</button>
              </div>
            </teleport>
          </div>
        </div>
      </div>

      <div class="profiles-strip-shell">
        <!-- Keyed off having saves at all, not off the featured card: a search
             that momentarily matches nothing must not slide the strip sideways. -->
        <!--
          The strip does not scroll — it is a window, and the track inside it is
          moved with a transform.

          It used to be a scroll container, and something outside this component
          kept yanking its scrollLeft back to the start between steps: focusing an
          element inside a scrollable box makes the browser reveal it, and the
          leftmost card would win. Each step then animated from that hijacked
          position, which is the jump to the far left. With nothing to scroll,
          there is nothing to hijack.
        -->
        <div ref="stripRef" class="profiles-strip">
          <div ref="trackRef" :class="['profiles-track', { 'profiles-track--hero': hasAnyProfile }]">
          <!-- Carries the selected card's width rules but never animates and never
               renders, so centring has something truthful to measure. Reading the
               real card instead meant catching it mid-growth and computing targets
               from a width it only held for an instant. -->
          <div ref="probeHero" class="profile-card profile-card--hero pc-probe" aria-hidden="true" />
          <div ref="probeSmall" class="profile-card pc-probe" aria-hidden="true" />
          <ProfileCreateCard
            v-model:profileName="newProfileName"
            v-model:active="createCardActive"
            :autoExpand="!hasAnyProfile"
            :hero="expandedIndex === -1"
            :selected="focusedIndex === -1 && expandedIndex !== -1"
            class="profile-card"
            @click="focusCard(-1, { immediate: true })"
            @card:activate="value => onCardActivated(value, -1)"
            @load="onCreateSave" />
          <!-- One list. Whichever card the strip is focused on is the one that
               opens up, and it is the one held in the middle of the screen. -->
          <ProfileCard
            v-for="(profile, index) of filteredProfiles"
            v-bng-popover="profile.incompatibleVersion ? 'tooltip-outdated-message' : null"
            v-bind="profile"
            v-bng-disabled="(isManage && selectedCard !== null && selectedCard !== index) || (isBackup && backupCardIndex !== null && backupCardIndex !== index)"
            :key="profile.id"
            :active="activeProfileId === profile.id"
            :forceCloseManage="selectedCard === -1"
            :hero="index === expandedIndex"
            :mapLabel="index === expandedIndex ? mapLabelFor(profile) : ''"
            :recentMoney="index === expandedIndex ? focusedRecentMoney : EMPTY_LIST"
            :assetValue="index === expandedIndex ? focusedHighlights.assetValue : null"
            :highlightsPending="index === expandedIndex && highlightsPending"
            :sliding="sliding"
            :selected="index === focusedIndex && index !== expandedIndex"
            class="profile-card"
            @click="focusCard(index, { immediate: true })"
            @card:activate="value => onCardActivated(value, index)"
            @manage:change="value => onManageChange(value, index)"
            @backup:change="active => onBackupChange(active, index)"
            @load="onLoad"
            @saves:load="onLoadSave" />

          <div v-if="hasNoMatches" class="profiles-empty">
            <span class="profiles-empty-title">No saves match</span>
            <button type="button" class="profiles-empty-btn" @click="clearAllFilters">Clear search and filters</button>
          </div>
          </div>
        </div>
      </div>
    </div>
  </div>
  <BngPopoverContent name="tooltip-outdated-message">
    <template #default>
      <div class="tooltip-outdated-message">This profile was saved with an old version of the game. It can no longer be loaded.</div>
    </template>
  </BngPopoverContent>
  <LegacyMigrationModal
    v-if="migrationReport"
    :report="migrationReport"
    :busy="migrationBusy"
    :error="migrationError"
    @cancel="cancelMigration"
    @migrate="runMigration" />
</template>

<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, provide, ref, reactive, watch } from "vue"
import { lua, useBridge } from "@/bridge"
import { $translate } from "@/services"
import { vBngDisabled, vBngPopover, vBngScopedNav, vBngOnUiNav } from "@/common/directives"
import { BngPopoverContent, BngScreenHeading } from "@/common/components/base"
import BackAside from "../../../mainmenu/components/BackAside.vue"
import ProfileCard from "../components/ProfileCard.vue"
import ProfileCreateCard from "../components/ProfileCreateCard.vue"
import LegacyMigrationModal from "../components/LegacyMigrationModal.vue"
import {
  DIFFICULTY_FILTER_OPTIONS,
  PATH_FILTER_OPTIONS,
  getProfileDifficultyLabel,
  getProfilePathLabel,
} from "../components/start/careerStartModes.js"
import { useProfilesStore, PROFILE_NAME_MAX_LENGTH } from "../../stores/profilesStore"

const store = useProfilesStore()
const { events } = useBridge()

const profiles = ref(null)
const activeProfileId = ref(null)

const selectedCard = ref(null)
const isManage = ref(false)
const isBackup = ref(false)
const backupCardIndex = ref(null)
const newProfileName = ref(null)
const createCardActive = ref(false)

let isLoading = false
const migrationReport = ref(null)
const migrationBusy = ref(false)
const migrationError = ref("")

const stripRef = ref(null)
const trackRef = ref(null)

const searchQuery = ref("")
const sortMode = ref("lastPlayed")
const activePaths = reactive(new Set())
const activeDifficulties = reactive(new Set())
const activeChallenges = reactive(new Set())

const sortOptions = [
  { value: "lastPlayed", label: "Last Played" },
  { value: "moneyDesc", label: "Money (High to Low)" },
  { value: "moneyAsc", label: "Money (Low to High)" },
  { value: "skillDesc", label: "Top Skill (High to Low)" },
  { value: "skillAsc", label: "Top Skill (Low to High)" },
]
const selectedSortLabel = computed(() => sortOptions.find(o => o.value === sortMode.value)?.label || "Last Played")

const sortDropdownRef = ref(null)
const sortOpen = ref(false)
const sortStyle = ref("")

const filterDropdownRef = ref(null)
const filterOpen = ref(false)
const filterStyle = ref("")

const pathFilterOptions = PATH_FILTER_OPTIONS
const difficultyFilterOptions = DIFFICULTY_FILTER_OPTIONS

const challengeFilterOptions = computed(() => {
  if (!profiles.value) return []
  const names = new Set()
  for (const p of profiles.value) {
    const ch = p.activeChallenge
    if (!ch) continue
    const name = typeof ch === "string" ? ch : ch.name
    if (name) names.add(name)
  }
  return [...names].sort()
})

const activeFilterCount = computed(() => activePaths.size + activeDifficulties.size + activeChallenges.size)

function getProfileChallengeName(p) {
  if (!p.activeChallenge) return null
  return typeof p.activeChallenge === "string" ? p.activeChallenge : p.activeChallenge.name || null
}

function getTopSkillLevel(p) {
  if (!p.freSkills || !p.freSkills.length) return 0
  return Math.max(...p.freSkills.map(s => Number(s.level) || 0))
}

const filteredProfiles = computed(() => {
  if (!profiles.value) return []
  let list = [...profiles.value]

  const q = searchQuery.value.trim().toLowerCase()
  if (q) list = list.filter(p => p.id.toLowerCase().includes(q))

  if (activePaths.size > 0) {
    list = list.filter(p => activePaths.has(getProfilePathLabel(p)))
  }

  // A profile whose payload carries no difficulty is unknown, not Standard — it
  // stays out of the results rather than being filed under a guess.
  if (activeDifficulties.size > 0) {
    list = list.filter(p => activeDifficulties.has(getProfileDifficultyLabel(p)))
  }

  if (activeChallenges.size > 0) {
    list = list.filter(p => {
      const name = getProfileChallengeName(p)
      return name && activeChallenges.has(name)
    })
  }

  const activeId = activeProfileId.value
  const active = activeId ? list.find(p => p.id === activeId) : null
  let rest = active ? list.filter(p => p.id !== activeId) : list

  switch (sortMode.value) {
    case "moneyDesc":
      rest.sort((a, b) => (b.money?.value || 0) - (a.money?.value || 0))
      break
    case "moneyAsc":
      rest.sort((a, b) => (a.money?.value || 0) - (b.money?.value || 0))
      break
    case "skillDesc":
      rest.sort((a, b) => getTopSkillLevel(b) - getTopSkillLevel(a))
      break
    case "skillAsc":
      rest.sort((a, b) => getTopSkillLevel(a) - getTopSkillLevel(b))
      break
    default:
      rest.sort((a, b) => new Date(b.date) - new Date(a.date))
  }

  return active ? [active, ...rest] : rest
})

/**
 * Which card the strip is parked on. -1 is the create card, which sits ahead of
 * the saves and centres like the rest but never expands. Starts on the first
 * save — the one played last, under the default sort.
 */
const focusedIndex = ref(0)

/**
 * Which card is actually drawn large, as opposed to merely selected.
 *
 * While you are still scrolling nothing expands — every card stays its normal
 * size and the selection is just highlighted, so the strip does not heave about
 * under a moving cursor. It only opens once you have stopped on one. Null means
 * nothing is expanded yet.
 */
const expandedIndex = ref(0)

/** How long the selection has to sit still before the card opens. */
const EXPAND_DELAY_MS = 1500

let expandTimer = null

/** The one whose panel is actually on screen. */
const expandedProfile = computed(() =>
  expandedIndex.value == null ? null : filteredProfiles.value[expandedIndex.value] || null
)

/**
 * Strip geometry, measured once and cached. Per-step remeasurement was a
 * querySelectorAll over every card plus several getComputedStyle calls, and
 * none of these numbers change outside a resize.
 *
 * The probes exist because the real cards animate: a width read mid-growth is
 * neither the old size nor the new one. The probes carry the same CSS and
 * never animate, so they are always truthful.
 */
const probeHero = ref(null)
const probeSmall = ref(null)
const geom = { small: 0, hero: 0, gap: 0, padLeft: 0, stripWidth: 0 }

function measureStrip() {
  if (!trackRef.value || !stripRef.value) return
  const style = getComputedStyle(trackRef.value)
  geom.gap = parseFloat(style.columnGap || style.gap) || 0
  geom.padLeft = parseFloat(style.paddingLeft) || 0
  geom.small = probeSmall.value?.offsetWidth || 0
  geom.hero = probeHero.value?.offsetWidth || geom.small
  geom.stripWidth = stripRef.value.clientWidth
}

/**
 * How far the track has to be pulled left for the given card to sit in the
 * middle of the window. Keyed on what is expanded, not what is selected —
 * while browsing every card is the same width and the centring has to agree.
 */
function offsetForCard(index) {
  if (!geom.small) measureStrip()
  const { small, hero, gap, padLeft, stripWidth } = geom
  if (!small) return 0

  // DOM position p holds profile p - 1, so position 0 is the create card at
  // index -1 — which expands like any other card when it is the selection.
  const heroPos = expandedIndex.value == null ? -1 : expandedIndex.value + 1
  const pos = index + 1
  let left = padLeft + pos * (small + gap)
  if (heroPos >= 0 && heroPos < pos) left += hero - small

  const width = pos === heroPos ? hero : small
  return left + width / 2 - stripWidth / 2
}

/** A move that ends with a card opening; paced to feel like one gesture. */
const SLIDE_MS = 460

/** A browse step: long enough to watch the strip travel, no longer. */
const BROWSE_SLIDE_MS = 260

/** Gathers pace and settles — right for a card opening at the end of it. */
const easeInOut = t => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2)

/** Leaves immediately and eases in — right for a step that just has to be there. */
const easeOut = t => 1 - Math.pow(1 - t, 3)

/** Ceiling on how long any one move may take, however far it goes. */
const MAX_SLIDE_MS = 720

/**
 * How much ground a move is allowed to show.
 *
 * Jumping forty cards is ~15,000px; covering that in any watchable time means
 * thousands of pixels a frame, which is not motion the eye can follow — it is a
 * smear. Past this the strip cuts the excess and plays only the final stretch,
 * so a long jump arrives the same readable way a short one does.
 */
const MAX_TRAVEL_CARDS = 5

/** One card plus the gap after it — the strip's natural unit of distance. */
function cardStep() {
  return geom.small ? geom.small + geom.gap : 0
}

/** Longer for longer moves, but sub-linear so a big jump is not a slow crawl. */
function slideDuration(from, to, base) {
  const step = cardStep()
  if (!step) return base
  const cards = Math.abs(to - from) / step
  return Math.min(MAX_SLIDE_MS, Math.round(base * Math.sqrt(Math.max(1, cards))))
}

/**
 * True while the strip is moving. Cards slide under a stationary pointer, which
 * fires mouseover on whatever passes beneath it — so hover is ignored until this
 * clears, otherwise a card lights up mid-slide purely because it went past the
 * cursor.
 */
const sliding = ref(false)

let scrollFrame = 0

/** Bumped per animation; a loop whose token is stale stops writing. */
let scrollGeneration = 0

/** Authoritative: what we last wrote, never re-read from the DOM. */
let trackOffset = 0

function applyOffset(value) {
  trackOffset = value
  if (trackRef.value) trackRef.value.style.transform = `translate3d(${-value}px, 0, 0)`
}

/**
 * Hand-rolled rather than a native smooth scroll, whose duration is fixed by the
 * browser and slower than this wants to feel. Composited, so it does not fight
 * the card growth happening alongside it.
 */
function animateTo(target, duration = SLIDE_MS, ease = easeInOut) {
  // cancelAnimationFrame alone was not enough: a loop that had already been
  // handed the frame would reschedule itself *after* the new animation stored
  // its id, so the cancel killed the new one and left the old running. Two
  // loops then wrote competing positions on alternate frames, which is the
  // lurching seen while stepping quickly.
  const generation = ++scrollGeneration
  cancelAnimationFrame(scrollFrame)

  let start = trackOffset
  const to = Math.max(0, target)

  // Skip the part of a long move that would only ever be a blur.
  const maxTravel = MAX_TRAVEL_CARDS * cardStep()
  if (duration && maxTravel && Math.abs(to - start) > maxTravel) {
    start = to - Math.sign(to - start) * maxTravel
    applyOffset(start)
  }

  if (!duration || Math.abs(to - start) < 1) {
    applyOffset(to)
    sliding.value = false
    return
  }

  sliding.value = true

  // Timed off the frame clock alone. requestAnimationFrame's timestamp and
  // performance.now() do not share a time origin in this browser — mixing them
  // gave elapsed times of minus several seconds, so the easing curve ran far
  // outside 0..1 and threw the track hundreds of thousands of pixels away
  // before snapping back. That was the flash.
  let startedAt = null
  const step = now => {
    if (generation !== scrollGeneration) return
    if (startedAt === null) startedAt = now

    const t = Math.min(1, Math.max(0, (now - startedAt) / duration))
    applyOffset(start + (to - start) * ease(t))

    if (t < 1) {
      scrollFrame = requestAnimationFrame(step)
    } else {
      applyOffset(to)
      sliding.value = false
    }
  }
  scrollFrame = requestAnimationFrame(step)
}

/** Re-centres on the expanded layout once a card has opened. */
function scheduleExpand() {
  clearTimeout(expandTimer)
  expandTimer = setTimeout(() => {
    expandedIndex.value = focusedIndex.value
    nextTick(() => {
      const target = offsetForCard(focusedIndex.value)
      animateTo(target, slideDuration(trackOffset, target, SLIDE_MS))
    })
  }, EXPAND_DELAY_MS)
}

/**
 * `immediate` opens the card straight away — clicking one is a decision, so it
 * should not be made to wait out the settle delay that scrolling needs.
 */
function focusCard(index, { animate = true, immediate = false } = {}) {
  const max = filteredProfiles.value.length - 1
  const next = Math.max(-1, Math.min(max, index))
  focusedIndex.value = next

  if (immediate) {
    clearTimeout(expandTimer)
    expandedIndex.value = next
  } else {
    expandedIndex.value = null
    scheduleExpand()
  }

  nextTick(() => {
    if (!animate) return animateTo(offsetForCard(next), 0)
    // Browsing wants to be there now; opening wants to feel like a movement.
    const target = offsetForCard(next)
    const base = immediate ? SLIDE_MS : BROWSE_SLIDE_MS
    const ease = immediate ? easeInOut : easeOut
    animateTo(target, slideDuration(trackOffset, target, base), ease)
  })
}

/**
 * One notch moves one card. A trackpad or a free-spinning wheel fires many
 * events per gesture, so a step has to settle before the next one is taken —
 * without this a single flick runs the length of the list.
 */
let wheelAccum = 0
let lastWheelTs = 0
let wheelDir = 0

/** One wheel notch — CEF reports exactly 120 per detent. Anything lower makes
    detent remainders add up to phantom extra steps on a fast spin. */
const WHEEL_NOTCH = 120

/**
 * One card per notch, at any speed.
 *
 * The old rule was one card per *gesture*, with the gesture ending after 140ms
 * of quiet — so a fast continuous spin kept resetting the timer and moved one
 * card total, while slow deliberate notches moved one each. Faster input went
 * slower. Accumulating delta instead means three notches are three cards
 * whether they arrive in 90ms or 3 seconds; the slide simply re-targets, so a
 * quick spin reads as the strip flowing card by card.
 */
function onWheel(evt) {
  const delta = evt.deltaY || evt.deltaX
  if (!delta) return
  // Lists that genuinely scroll keep their wheel; everywhere else browses.
  // (Only these two live inside the container — the menus and the migration
  // modal teleport to body, and the setup screens stop wheel at their root.)
  if (evt.target.closest?.(".pc-saves-list, .sandbox-advanced-body")) return
  evt.preventDefault()

  // A pause or a direction change starts a fresh gesture; leftovers and debt
  // from the old one must not leak into it.
  const fresh = evt.timeStamp - lastWheelTs > 250 || Math.sign(delta) !== wheelDir
  lastWheelTs = evt.timeStamp
  if (fresh) {
    wheelAccum = 0
    wheelDir = Math.sign(delta)
  }
  wheelAccum += delta

  let steps = Math.trunc(wheelAccum / WHEEL_NOTCH)
  // Deliberate movement always answers: a gesture's first event steps even when
  // its delta is under a notch (gentle trackpads, high-resolution wheels). The
  // shortfall stays in the accumulator as debt, so total travel still matches
  // total input and a real 120-per-detent wheel keeps exact notch parity.
  if (fresh && !steps) steps = wheelDir
  if (!steps) return
  wheelAccum -= steps * WHEEL_NOTCH
  focusCard(focusedIndex.value + steps)
}

/** A changed result set renumbers everything, so go back to the front of it. */
watch(filteredProfiles, (list, old) => {
  nextTick(measureStrip)
  // Toggling police or renaming re-sends the whole list; the player's place in
  // it must survive that. Only fall back to the front when their card is gone.
  const prevId = old?.[focusedIndex.value]?.id
  const kept = prevId ? list.findIndex(profile => profile.id === prevId) : -1
  focusCard(kept >= 0 ? kept : list.length ? 0 : -1, { animate: false, immediate: true })
})

/**
 * Money history, asset value and the last vehicle all need files the strip must
 * not touch once per profile — attributeLog.json and every vehicle record. They
 * are fetched for the featured save alone.
 */
const focusedHighlights = ref({})

const focusedRecentMoney = computed(() => {
  const rows = focusedHighlights.value?.recentMoney
  if (!rows) return []
  return Array.isArray(rows) ? rows : Object.values(rows)
})

/** One shared identity for "no rows": a fresh [] per card would defeat
    per-card prop equality and re-render every card on each parent render. */
const EMPTY_LIST = Object.freeze([])

const highlightsPending = ref(false)
let highlightsTimer = null

/**
 * Deliberately late.
 *
 * The Lua behind this reads the attribute log and every vehicle record for the
 * profile, which blocks while it does. Firing it on each card as you pass is
 * what made stepping feel heavy, so it waits for the selection to settle first.
 * The card is drawn immediately either way — these numbers fill in after.
 */
/**
 * Keyed on the expanded card, not the selected one. Scrolling past twenty cards
 * used to queue twenty of these, each reading the attribute log and every
 * vehicle record for a card that was never opened.
 */
watch(
  () => expandedProfile.value?.id,
  id => {
    focusedHighlights.value = {}
    clearTimeout(highlightsTimer)
    if (!id) {
      highlightsPending.value = false
      return
    }

    highlightsPending.value = true
    highlightsTimer = setTimeout(async () => {
      try {
        const data = await lua.career_career.getProfileHighlights(id, 5)
        // A reply for a card that has since been closed must not land.
        if (expandedProfile.value?.id !== id) return
        focusedHighlights.value = data || {}
      } catch (_) {
      } finally {
        if (expandedProfile.value?.id === id) highlightsPending.value = false
      }
    }, 120)
  },
  { immediate: true }
)

/** {id: label} from overhaul_maps — a level id on its own is not a label. */
const mapLabels = ref({})

function mapLabelFor(profile) {
  const level = profile?.level
  if (!level) return ""
  return mapLabels.value?.[level] || ""
}

async function loadMapLabels() {
  try {
    const maps = await lua.overhaul_maps.getCompatibleMaps()
    if (maps && typeof maps === "object") mapLabels.value = maps
  } catch (_) {}
}

function toggleSort() {
  sortOpen.value = !sortOpen.value
  filterOpen.value = false
  if (sortOpen.value) nextTick(positionSort)
}

function positionSort() {
  if (!sortDropdownRef.value) return
  const trigger = sortDropdownRef.value.querySelector(".pt-trigger")
  if (!trigger) return
  const r = trigger.getBoundingClientRect()
  sortStyle.value = `position:fixed;z-index:2000;top:${r.bottom + 6}px;left:${r.left}px;min-width:${r.width}px;`
}

function selectSort(val) {
  sortMode.value = val
  sortOpen.value = false
}

function toggleFilter() {
  filterOpen.value = !filterOpen.value
  sortOpen.value = false
  if (filterOpen.value) nextTick(positionFilter)
}

function positionFilter() {
  if (!filterDropdownRef.value) return
  const trigger = filterDropdownRef.value.querySelector(".pt-trigger")
  if (!trigger) return
  const r = trigger.getBoundingClientRect()
  filterStyle.value = `position:fixed;z-index:2000;top:${r.bottom + 6}px;left:${r.left}px;min-width:${r.width}px;`
}

function togglePathFilter(p) {
  if (activePaths.has(p)) activePaths.delete(p)
  else activePaths.add(p)
}

function toggleDifficultyFilter(d) {
  if (activeDifficulties.has(d)) activeDifficulties.delete(d)
  else activeDifficulties.add(d)
}

function toggleChallengeFilter(c) {
  if (activeChallenges.has(c)) activeChallenges.delete(c)
  else activeChallenges.add(c)
}

function clearFilters() {
  activePaths.clear()
  activeDifficulties.clear()
  activeChallenges.clear()
}

const hasAnyProfile = computed(() => !!profiles.value && profiles.value.length > 0)

/** Nothing to search, sort or filter until there is more than one save. */
const showToolbar = computed(() => !!profiles.value && profiles.value.length > 1)

/** Only an empty *result* — a profile list that is genuinely empty is not a dead end. */
const hasNoMatches = computed(() => {
  if (!hasAnyProfile.value) return false
  return filteredProfiles.value.length === 0
})

function clearAllFilters() {
  searchQuery.value = ""
  clearFilters()
  sortOpen.value = false
  filterOpen.value = false
}

function onDropdownDocClick(e) {
  if (sortOpen.value) {
    const menu = document.querySelector(".pt-menu:not(.pt-menu--filter)")
    const trigger = sortDropdownRef.value?.querySelector(".pt-trigger")
    if (menu && menu.contains(e.target)) return
    if (trigger && trigger.contains(e.target)) return
    sortOpen.value = false
  }
  if (filterOpen.value) {
    const menu = document.querySelector(".pt-menu--filter")
    const trigger = filterDropdownRef.value?.querySelector(".pt-trigger")
    if (menu && menu.contains(e.target)) return
    if (trigger && trigger.contains(e.target)) return
    filterOpen.value = false
  }
}

function onSearchFocus() {
  try { lua.setCEFTyping(true) } catch (_) {}
}
function onSearchBlur() {
  try { lua.setCEFTyping(false) } catch (_) {}
}

const onLoad = async id => {
  migrationError.value = ""
  const report = await lua.career_career.getLegacySavePreflight(id, null)
  if (report?.requiresMigration) {
    migrationReport.value = report
    isLoading = false
    return
  }
  isLoading = true
  await store.loadProfile(id)
}

function cancelMigration() {
  if (migrationBusy.value) return
  migrationReport.value = null
  migrationError.value = ""
  isLoading = false
}

async function runMigration(options) {
  if (!migrationReport.value || migrationBusy.value) return
  const source = migrationReport.value
  migrationBusy.value = true
  migrationError.value = ""

  // Loading starts the moment the button is pressed: the screen goes up first and the copy
  // is written behind it. The modal is only dropped once the screen covers it, so the fade
  // is not a gap where the profile list flashes back. It returns if migration never starts.
  isLoading = true
  await store.startMigrationLoadingScreen()
  migrationReport.value = null

  try {
    const result = await lua.career_career.prepareLegacySaveMigration(source.profile, source.saveFolder, options)
    if (!result?.ok) {
      await failMigration(result?.error || "Migration could not be prepared.",
        result?.report && result.report.canMigrate === false ? result.report : source)
      return
    }

    await lua.career_career.sendAllCareerProfilesData()
    const loaded = await store.loadPreparedMigration(result.targetProfile, result.targetSaveFolder)
    if (!loaded) await failMigration("The migrated copy was created, but Career did not start.", source)
  } catch (error) {
    await failMigration(error?.message || "Migration failed unexpectedly.", source)
  } finally {
    migrationBusy.value = false
  }
}

/** Dropping the loading screen can bounce the UI to the main menu, so the toast carries the reason too. */
async function failMigration(message, report) {
  isLoading = false
  await store.stopMigrationLoadingScreen()
  migrationError.value = message
  migrationReport.value = report
  store.showMigrationError(message)
}

/** Picking a save now happens inside the card, so this just loads the chosen one. */
const onLoadSave = async (profileId, saveFolderName) => {
  if (!profileId || !saveFolderName) return
  isLoading = true
  await store.loadProfileSave(profileId, saveFolderName)
}

const onCreateSave = async (profileName, tutorialChecked, difficultyMode, challengeId, cheatsMode, startingMap, experimentalMaintenanceEnabled, startingGarageMode, startingGarageId, policeEnabled, xpMultiplier, economyMultiplier, startingCash, careerStartMode, sandboxEconomyProfile, sandboxXpProfile) => {
  isLoading = true
  await store.loadProfile(profileName, tutorialChecked, true, difficultyMode, challengeId, cheatsMode, startingMap, experimentalMaintenanceEnabled, startingGarageMode, startingGarageId, policeEnabled, xpMultiplier, economyMultiplier, startingCash, careerStartMode, sandboxEconomyProfile, sandboxXpProfile)
}

function onCardActivated(active, index) {
  if (active) {
    selectedCard.value = index
    if (index === -1) {
      // Setting up happens on the card, so make sure it is the selected one and
      // therefore at full size — otherwise the form opens in a 22em column.
      if (focusedIndex.value !== -1) focusCard(-1, { immediate: true })
      newProfileName.value = getNewName()
    } else {
      createCardActive.value = false
    }
  } else {
    selectedCard.value = null
  }
}

function onManageChange(active, index) {
  isManage.value = active
}

function onBackupChange(active, index) {
  isBackup.value = active
  backupCardIndex.value = active ? index : null
}

onMounted(() => {
  events.on("allCareerProfiles", onProfilesReceived)
  lua.career_career.sendAllCareerProfilesData()
  loadMapLabels()
  try { lua.extensions.load("career_challengeModes") } catch (_) {}
  document.addEventListener("mousedown", onDropdownDocClick)
  window.addEventListener("resize", positionSort)
  window.addEventListener("resize", positionFilter)
  window.addEventListener("resize", onStripResize)
})

/** Card sizes are in ui-rem, which the breakpoints change — re-measure and re-centre. */
function onStripResize() {
  measureStrip()
  animateTo(offsetForCard(focusedIndex.value), 0)
}

onBeforeUnmount(() => {
  events.off("allCareerProfiles", onProfilesReceived)
  document.removeEventListener("mousedown", onDropdownDocClick)
  window.removeEventListener("resize", positionSort)
  window.removeEventListener("resize", positionFilter)
  window.removeEventListener("resize", onStripResize)
  cancelAnimationFrame(scrollFrame)
  clearTimeout(highlightsTimer)
  clearTimeout(expandTimer)
})

provide("validateName", validateName)

/**
 * Anything with its own escape semantics. `.css-start-screen` is no longer an
 * overlay — it is the create card's inline form — but Back there must close the
 * form rather than leave the screen, so it still belongs on this list.
 */
function isAnyModalOpen() {
  const selectors = ['.ccm-overlay', '.cdm-overlay', '.lmm-backdrop', '.css-start-screen', '.css-start-dropdown-menu', '.css-sandbox-advanced-overlay', '.pt-menu']
  for (const sel of selectors) {
    const el = document.querySelector(sel)
    if (!el) continue
    const style = window.getComputedStyle(el)
    if (style.display !== 'none' && style.visibility !== 'hidden') return true
  }
  return false
}

const navigateToMainMenu = () => {
  if (isAnyModalOpen()) return
  if (activeProfileId.value) {
    window.bngVue.gotoAngularState("menu.careerPause")
  } else {
    window.bngVue.gotoGameState("menu.mainmenu")
  }
}

const onDeactivate = (event) => {
  if (event?.detail?.force) return
  if (createCardActive.value) return
  if (isBackup.value) return
  if (isAnyModalOpen()) return

  // Load in progress (or just finished underneath us): leave to play, don't
  // swallow ESC into a stuck selector and don't route to careerPause.
  if (isLoading) {
    isLoading = false
    try { lua.extensions.ui_router.navigate("play") } catch (_) {}
    return
  }
  navigateToMainMenu()
}

async function onProfilesReceived(data) {
  selectedCard.value = null
  activeProfileId.value = null
  profiles.value = data && data.length > 0 ? await updateActiveProfile(data) : null
}

async function updateActiveProfile(data) {
  const currentSave = await lua.career_career.sendCurrentProfileData()
  data.sort((a, b) => new Date(b.date) - new Date(a.date))

  if (currentSave) {
    activeProfileId.value = currentSave.id
    let current = data.find(x => x.id === currentSave.id)
    if (!current) current = currentSave
    data = data.filter(x => x.id !== currentSave.id)
    data.splice(0, 0, current)
  }

  return data
}

function sanitizeProfileFolderName(name) {
  const sanitized = String(name || "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "")
  return sanitized || "profile"
}

function isProfileNameTaken(name) {
  if (!profiles.value || !name) return false
  const trimmed = String(name).trim()
  const lower = trimmed.toLowerCase()
  const sanitized = sanitizeProfileFolderName(trimmed)

  return profiles.value.some(profile => {
    const id = profile?.id != null ? String(profile.id) : ""
    const displayName = profile?.displayName != null ? String(profile.displayName) : ""
    if (id && id.toLowerCase() === lower) return true
    if (displayName && displayName.toLowerCase() === lower) return true
    // .39 saveSystem strips non-alphanumeric for the on-disk folder id
    if (id && sanitizeProfileFolderName(id) === sanitized) return true
    if (displayName && sanitizeProfileFolderName(displayName) === sanitized) return true
    return false
  })
}

function validateName(newName) {
  if (!newName) return "Save name cannot be empty"
  if (newName.length > PROFILE_NAME_MAX_LENGTH) return "Save name cannot be longer than 100 characters"
  const invalidChars = /[<>:"/\\|?*]/
  if (invalidChars.test(newName)) return "Save name cannot contain invalid characters"
  if (isProfileNameTaken(newName)) return "Save name already exists"
  return null
}

function getNewName() {
  const prefix = $translate.contextTranslate("ui.career.profile")
  for (let i = 1; i < 1e3; i++) {
    const id = `${prefix} ${i}`
    if (!isProfileNameTaken(id)) return id
  }
  return `${prefix} 1`
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.profiles-container {
  font-size: calc-ui-rem();
  margin: 0;
  display: flex;
  flex-direction: column;
  justify-content: center;
  height: 100%;
  width: 100%;

  .profiles-title {
    font-size: calc-ui-rem() !important;
    :deep(.header) {
      padding: calc-ui-rem(0.5) calc-ui-rem(0.75) calc-ui-rem(0.5) calc-ui-rem(0.5) !important;
    }
  }
}

.profiles-title {
  position: absolute;
  top: calc-ui-rem(-6);
  left: calc-ui-rem(2);
}

.profiles-back {
  top: calc-ui-rem() !important;
  bottom: calc-ui-rem() !important;
}

.profiles-panel {
  display: flex;
  flex-direction: column;
  position: relative;
  isolation: isolate;
  width: 100%;
  padding: 2.75em 0;
}

/* Sits over the featured card rather than off in the corner. Centred on the
   screen, which is where that card is. */
.profiles-toolbar {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0.75em;
  padding: 0 1.5em 0.6em;
  flex-shrink: 0;
  position: relative;
  z-index: 2;
}

/* Full-bleed: the strip's own 50% has to be the middle of the screen for the
   featured card to land there. */
.profiles-strip-shell {
  position: relative;
  z-index: 1;

  &::before {
    content: "";
    position: absolute;
    top: -6em;
    right: 0;
    bottom: -6em;
    left: 0;
    background: linear-gradient(
      180deg,
      rgba(11, 15, 25, 0) 0%,
      rgba(11, 15, 25, 0.05) 2%,
      rgba(11, 15, 25, 0.2) 6%,
      rgba(11, 15, 25, 0.5) 18%,
      rgba(11, 15, 25, 0.5) 82%,
      rgba(11, 15, 25, 0.2) 94%,
      rgba(11, 15, 25, 0.05) 98%,
      rgba(11, 15, 25, 0) 100%
    );
    pointer-events: none;
    z-index: 0;
  }
}

/* Fixed rather than fluid: it is one item in a centred group now, and growing
   to fill the row would push the dropdowns back out to the edge. */
.pt-search {
  flex: 0 0 auto;
  width: 20em;
}

.pt-input {
  width: 100%;
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.35em 0.7em;
  color: #fff;
  font-size: 0.82em;
  font-family: inherit;
  outline: none;

  &::placeholder { color: rgba(255, 255, 255, 0.35); }
  &:focus { border-color: rgba(148, 163, 184, 0.5); }
}

.pt-controls {
  display: flex;
  gap: 0.5em;
  flex-shrink: 0;
}

.pt-dropdown { position: relative; }

.pt-trigger {
  display: flex;
  align-items: center;
  gap: 0.5em;
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.35em 0.7em;
  color: #fff;
  font-size: 0.82em;
  cursor: pointer;
  white-space: nowrap;

  &:hover { border-color: rgba(71, 85, 105, 0.8); }
}

.pt-chevron { opacity: 0.5; font-size: 0.9em; }

.pt-menu {
  background: rgba(10, 14, 24, 0.98);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.25em;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
  font-size: calc-ui-rem();
}

.pt-option {
  padding: 0.4em 0.6em;
  border-radius: 6px;
  cursor: pointer;
  color: #fff;
  font-size: 0.82em;
  white-space: nowrap;

  &:hover { background: rgba(30, 41, 59, 0.6); }
  /* Orange, like every other accent on this screen — this was the lone blue. */
  &.pt-option--active { background: rgba(255, 122, 26, 0.16); color: #ff9647; }
}

.pt-menu--filter {
  min-width: 14em;
  max-height: 28em;
  overflow-y: auto;
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);
}

.pt-filter-group { padding: 0.25em 0.35em; }
.pt-filter-heading {
  font-size: 0.72em;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.45);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  padding: 0.25em 0.25em 0.35em;
}

.pt-check {
  display: flex;
  align-items: center;
  gap: 0.5em;
  padding: 0.3em 0.25em;
  border-radius: 6px;
  cursor: pointer;
  font-size: 0.82em;
  color: #fff;

  &:hover { background: rgba(30, 41, 59, 0.5); }

  input[type="checkbox"] {
    accent-color: #ff7a1a;
    width: 1em;
    height: 1em;
    cursor: pointer;
  }
}

.pt-filter-sep {
  height: 1px;
  background: rgba(71, 85, 105, 0.35);
  margin: 0.25em 0.35em;
}

.pt-clear-btn {
  display: block;
  width: calc(100% - 0.5em);
  margin: 0.25em auto;
  padding: 0.35em;
  border: 0;
  border-radius: 6px;
  background: rgba(239, 68, 68, 0.15);
  color: #f87171;
  font-size: 0.78em;
  font-weight: 600;
  cursor: pointer;

  &:hover { background: rgba(239, 68, 68, 0.25); }
}

/* A window. It has nothing to scroll, so nothing outside this component can
   scroll it — the track inside is moved instead. */
/**
 * `clip`, not `hidden`. Hidden still makes a scroll container — one that nothing
 * can drag but the browser can still scroll itself, which is precisely how
 * focusing a card off to the left kept yanking the strip to the start. Clip
 * creates no scroll container, so there is no scroll position to hijack.
 */
.profiles-strip {
  overflow: clip;
  position: relative;
  z-index: 1;
}

.profiles-track {
  display: flex;
  gap: calc-ui-rem(1);
  padding: 0.25em calc-ui-rem(6) 0.5em calc-ui-rem(6);
  align-items: center;
  position: relative;
  width: max-content;
}

.profiles-empty {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  justify-content: center;
  gap: 0.75em;
  height: calc-ui-rem(28);
  padding: 0 1.5em;
}

.profiles-empty-title {
  font-size: 1.1em;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.75);
  white-space: nowrap;
}

.profiles-empty-btn {
  border: 1px solid rgba(71, 85, 105, 0.55);
  border-radius: 8px;
  padding: 0.5em 1em;
  background: rgba(5, 8, 15, 0.7);
  color: #fff;
  font-size: 0.82em;
  font-family: inherit;
  cursor: pointer;
  white-space: nowrap;

  &:hover {
    border-color: rgba(255, 122, 26, 0.6);
    background: rgba(255, 122, 26, 0.08);
  }
}

/**
 * Runway at both ends rather than spacer elements, so the first and last cards
 * can each be scrolled into the middle of the screen like any other.
 *
 * 11rem is half an unselected card — the widest gap any card needs to reach the
 * centre. A selected card is wider and so needs less. The resting position is
 * not scroll zero any more; the strip centres the first save on load.
 */
.profiles-track--hero {
  padding-left: max(#{calc-ui-rem(1.5)}, calc(50vw - #{calc-ui-rem(11)}));
  padding-right: max(#{calc-ui-rem(4)}, calc(50vw - #{calc-ui-rem(11)}));

  /* Held at the selected card's full height, plus this track's own vertical
     padding — the box is border-box, so the padding has to be in the figure.
     Without it the track is only as tall as its tallest child, and mid-step both
     the outgoing and incoming cards are part-way between the two sizes, so the
     strip shrank and the centred panel above it — search box and all — dropped
     and came back. */
  min-height: calc(#{calc-ui-rem(31)} + 0.75em);
}

/**
 * Every card in the strip is exactly this size, whatever it is showing.
 *
 * 180ms against the scroll's 220ms: the cards must finish growing before the
 * scroll lands, so the strip's final width is settled when the last frame sets
 * the exact position. Centring never measures these mid-flight — it works from
 * the settled widths — so the two can run together.
 */
.profile-card {
  height: calc-ui-rem(28);
  min-height: calc-ui-rem(28);
  max-height: calc-ui-rem(28);
  width: calc-ui-rem(22);
  min-width: calc-ui-rem(22);
  flex: 0 0 auto;
  /* Hundreds of these exist and all but a handful are off screen. Without this
     every one of them is laid out and painted on each step, which starved the
     animation of frames. The intrinsic size matches the real one, so nothing
     shifts when a card comes into view. */
  content-visibility: auto;
  contain-intrinsic-size: calc-ui-rem(22) calc-ui-rem(28);

  /**
   * The size change is not animated, deliberately.
   *
   * A selected card is not a wider version of an unselected one — it is a
   * different layout, artwork beside a panel instead of artwork above a drawer.
   * The layout switches the instant the class does, so while the width was
   * still growing the panel column did not fit and the artwork column was
   * squeezed to nothing, spilling the name and chips across the panel. There is
   * no in-between worth showing. The slide carries the movement instead.
   */
}

/* Measured, never seen: out of flow so it adds nothing to the strip's length. */
.pc-probe {
  position: absolute;
  top: 0;
  left: 0;
  visibility: hidden;
  pointer-events: none;
  height: 0 !important;
  min-height: 0 !important;
  max-height: 0 !important;
}

/* The one card that is always on screen — never skip its rendering. */
/* Browsing: the selection is marked, not opened. */
.profile-card--selected {
  box-shadow: 0 0 0 2px #ff7a1a;
}

.profile-card--hero {
  content-visibility: visible;
  contain-intrinsic-size: auto;
  height: calc-ui-rem(31);
  min-height: calc-ui-rem(31);
  max-height: calc-ui-rem(31);
  width: calc-ui-rem(50);
  min-width: calc-ui-rem(50);
}

.tooltip-outdated-message {
  padding: calc-ui-rem(0.5);
  max-width: calc-ui-rem(16);
}
</style>
