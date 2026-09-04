<template>
  <div
    v-bng-scoped-nav="{ canDeactivate, canBubbleEvent }"
    v-bng-sound-class="'bng_hover_generic'"
    :class="['pc', { 'pc--active': active, 'pc--outdated': incompatibleVersion, 'pc--manage': isManage, 'pc--hover': hovered, 'pc--hero': hero, 'pc--snap-shut': snapDrawerShut, 'profile-card--hero': hero, 'profile-card--selected': selected }]"
    @activate="onScopeChanged(true)"
    @deactivate="onScopeChanged(false)"
    @mouseover="onPointerOver"
    @mouseleave="hovered = false">

    <div class="pc-image" :style="bgStyle">
      <div class="pc-image-overlay" />

      <!-- Labelling the picture, so it sits on the picture. -->
      <div v-if="hero && mapLabel" class="pc-map-tag">{{ mapLabel }}</div>

      <!-- What you were sitting in when the game last saved. The thumbnail is
           only written on saves that ran a thumbnail pass, so it can be absent
           even when the vehicle is known. -->
      <div v-if="hero && lastVehicle" class="pc-vehicle">
        <img
          v-if="lastVehicle.image && vehicleImageOk"
          class="pc-vehicle-img"
          :src="lastVehicle.image"
          alt=""
          @error="vehicleImageOk = false" />
        <div class="pc-vehicle-cap">
          <div class="pc-vehicle-eyebrow">Last driven</div>
          <!-- niceName is a {txt, context} translation for some vehicles and a
               plain string for others; $ctx_t handles both. Printed raw it came
               out as the JSON of the translation object. -->
          <div v-if="lastVehicle.name" class="pc-vehicle-name">{{ $ctx_t(lastVehicle.name) }}</div>
          <div v-if="lastVehicle.location" class="pc-vehicle-loc">{{ $ctx_t(lastVehicle.location) }}</div>
        </div>
      </div>

      <!-- Identity belongs on the art: it is the one part of the card with room
           to spare, and the picture is this save's map. -->
      <div class="pc-header">
        <div v-if="hero && active" class="pc-eyebrow">{{ $ctx_t("ui.career.nowplaying") }}</div>
        <div class="pc-name">{{ displayName || id }}</div>
        <div v-if="hero" class="pc-strapline">{{ heroStrapline }}</div>
        <template v-else>
          <div v-if="active" class="pc-playing">{{ $ctx_t("ui.career.nowplaying") }}</div>
          <div v-else-if="lastPlayedDescription" class="pc-last-played">{{ lastPlayedDescription }}</div>
        </template>

        <!-- Inside the header so the chips sit on the same rhythm as the line
             above them, whether or not that line is there. -->
        <div v-if="(hero || !isManage) && hasBadges" class="pc-badges">
          <span v-if="saveDataMissing" class="pc-chip pc-chip--incomplete">No save data</span>
          <span v-if="modeChipLabel" :class="modeChipClass">{{ modeChipLabel }}</span>
          <span v-if="experimentalMaintenanceEnabled" class="pc-chip pc-chip--maintenance">Maintenance</span>
          <span v-if="outdatedVersion && !incompatibleVersion" class="pc-chip pc-chip--migration">Migration available</span>
        </div>
      </div>
    </div>

    <div :class="['pc-drawer', { 'pc-drawer--open': showBody }]">
      <div ref="bodyRef" class="pc-body" v-bng-on-ui-nav:menu,back="goBack">
          <div v-if="backupStep === 'name'" class="pc-backup-section">
            <div class="pc-section-head">
              <div class="pc-section-title">Backup</div>
              <div class="pc-section-sub">Copy of {{ originalName }}</div>
            </div>
            <label class="pc-backup-label">Backup name</label>
            <div :class="['pc-backup-input-wrap', { 'pc-backup-input-wrap--error': backupNameError }]">
              <input
                v-bng-text-input
                :value="backupName"
                :maxlength="PROFILE_NAME_MAX_LENGTH"
                class="pc-backup-input"
                @input="onBackupInput"
                @focus="onBackupInputFocus"
                @blur="onBackupInputBlur"
                @keydown.enter.prevent="onBackupEnter" />
            </div>
            <span v-if="backupNameError" class="pc-backup-error">{{ backupNameError }}</span>
            <div class="pc-btns pc-btns--backup">
              <button ref="backupCancelBtn" class="pc-btn pc-btn--secondary" type="button" @click="cancelBackup">Cancel</button>
              <button
                ref="backupCreateBtn"
                v-bng-sound-class="'bng_click_generic'"
                class="pc-btn pc-btn--primary"
                type="button"
                :disabled="!!backupNameError || !backupName.trim()"
                @click="confirmBackup">Create</button>
            </div>
          </div>
          <div v-else-if="backupStep === 'loading'" class="pc-backup-feedback">
            <div class="pc-backup-spinner" />
          </div>
          <div v-else-if="backupStep === 'success'" class="pc-backup-feedback pc-backup-feedback--success">
            Backup created
          </div>
          <div v-else-if="savesOpen" class="pc-manage-section pc-saves-section">
            <div class="pc-section-head">
              <div class="pc-section-title">Saves</div>
              <div class="pc-section-sub">{{ savesSubtitle }}</div>
            </div>
            <div v-if="savesLoading" class="pc-saves-state">Loading saves…</div>
            <div v-else-if="!saveFolders.length" class="pc-saves-state">No saves in this profile.</div>
            <div v-else class="pc-saves-list">
              <button
                v-for="save in saveFolders"
                :key="save.name"
                type="button"
                class="pc-save-row"
                :class="{ 'pc-save-row--current': save.isCurrent }"
                :disabled="save.incompatibleVersion || save.corrupted"
                @click="onLoadSave(save)">
                <span class="pc-save-name">
                  {{ save.name }}
                  <span v-if="save.isCurrent" class="pc-save-chip">Current</span>
                </span>
                <span class="pc-save-sub">{{ saveRowSub(save) }}</span>
              </button>
            </div>
            <div class="pc-btns pc-btns--back">
              <button class="pc-btn pc-btn--secondary" @click="closeSaves">Back</button>
            </div>
          </div>
          <div v-else-if="isManage && currentMenu === MENU_ITEMS.RENAME" class="pc-manage-section">
            <div class="pc-section-head">
              <div class="pc-section-title">{{ $ctx_t("ui.career.rename") }}</div>
              <div v-if="!hero" class="pc-section-sub">{{ originalName }}</div>
            </div>
            <BngInput
              v-model="saveName"
              :maxlength="PROFILE_NAME_MAX_LENGTH"
              :validate="validateFn"
              :errorMessage="nameError"
              externalLabel="Save Name"
              @blur="onInputBlur"
              @keydown.enter.prevent />
            <div class="pc-btns">
              <button ref="startButton" class="pc-btn pc-btn--primary" :disabled="nameError !== null || saveName === originalName" @click="updateProfileName">Save</button>
              <button ref="cancelButton" class="pc-btn pc-btn--secondary" @click="goBack">Back</button>
            </div>
          </div>
          <div v-else-if="isManage && currentMenu === MENU_ITEMS.DELETE" class="pc-manage-section">
            <div class="pc-section-head">
              <div class="pc-section-title pc-section-title--danger">{{ $ctx_t("ui.career.delete") }}</div>
              <div v-if="!hero" class="pc-section-sub">{{ originalName }}</div>
            </div>
            <span class="pc-delete-prompt">{{ $ctx_t("ui.career.deletePrompt") }}</span>
            <div class="pc-btns">
              <button class="pc-btn pc-btn--danger" @click="deleteProfile">{{ $ctx_t("ui.common.yes") }}</button>
              <button class="pc-btn pc-btn--secondary" @click="goBack">{{ $ctx_t("ui.common.no") }}</button>
            </div>
          </div>
          <div v-else-if="isManage" class="pc-manage-section">
            <div class="pc-section-head">
              <div class="pc-section-title">Manage</div>
              <div v-if="!hero" class="pc-section-sub">{{ displayName || id }}</div>
            </div>
            <!-- Rows, not a stack of identical grey buttons: each one says what it
                 does to the save, and the destructive one does not look like the
                 other two. -->
            <div class="pc-actions">
              <button class="pc-action" type="button" :disabled="active" @click="() => (currentMenu = MENU_ITEMS.RENAME)">
                <span class="pc-action-label">{{ $ctx_t("ui.career.rename") }}</span>
                <span class="pc-action-desc">Change the name shown on this card</span>
              </button>
              <button
                v-bng-sound-class="'bng_click_generic'"
                class="pc-action"
                type="button"
                :disabled="incompatibleVersion"
                @click="startBackup">
                <span class="pc-action-label">Backup</span>
                <span class="pc-action-desc">Copy everything into a new named save</span>
              </button>
              <button class="pc-action pc-action--danger" type="button" :disabled="active" @click="() => (currentMenu = MENU_ITEMS.DELETE)">
                <span class="pc-action-label">{{ $ctx_t("ui.career.delete") }}</span>
                <span class="pc-action-desc">{{ active ? "Cannot delete the save you are playing" : "Remove this save and all of its progress" }}</span>
              </button>
            </div>
            <div class="pc-btns pc-btns--back">
              <button class="pc-btn pc-btn--secondary" @click="goBack">Back</button>
            </div>
          </div>
          <div v-else class="pc-status-section">
            <div v-if="!hero" class="pc-money">{{ formatMoney(money?.value || 0) }}</div>

            <!-- The featured card is the one the player is most likely to press,
                 so it answers "where was I?" without being opened first: what you
                 are worth, what you own, what you are good at, what just moved. -->
            <!-- Two rows: what the save is worth, then what it owns. Five figures
                 across one row collided and truncated their own captions. -->
            <template v-if="hero">
              <div class="pc-tiles pc-tiles--money">
                <div v-for="tile in heroMoneyTiles" :key="tile.label" :class="['pc-tile', { 'pc-tile--cash': tile.cash }]">
                  <span class="pc-tile-cap">{{ tile.label }}</span>
                  <span class="pc-tile-num">{{ tile.value }}</span>
                </div>
              </div>
              <div class="pc-tiles">
                <div v-for="tile in heroCountTiles" :key="tile.label" class="pc-tile">
                  <span class="pc-tile-cap">{{ tile.label }}</span>
                  <span class="pc-tile-num">{{ tile.value }}</span>
                </div>
              </div>
            </template>

            <!-- Side by side on the featured card, a plain block on every other one. -->
            <div :class="['pc-detail', { 'pc-detail--split': hero }]">
              <div v-if="topSkills.length" class="pc-skills">
                <div v-if="hero" class="pc-col-title">Skills</div>
                <div v-for="sk in topSkills" :key="sk.id" class="pc-skill">
                  <BngIcon :type="sk.icon" class="pc-skill-icon" />
                  <span class="pc-skill-name">{{ sk.label }}</span>
                  <span class="pc-skill-lvl">{{ $ctx_t(sk.levelLabel) }}</span>
                  <div v-if="hero" class="pc-bar">
                    <div class="pc-bar-fill" :style="{ width: `${Math.round(skillRatio(sk) * 100)}%` }" />
                  </div>
                </div>
              </div>

              <!-- Always present on the selected card, even before its rows have
                   been read. Making the column conditional on the data meant the
                   whole panel relaid out a beat after every step. -->
              <div v-if="hero" class="pc-txns">
                <div class="pc-col-title">Recent money</div>
                <div v-for="(txn, i) in recentMoney" :key="i" class="pc-txn">
                  <span class="pc-txn-label">{{ txn.label ? $ctx_t(txn.label) : "Transaction" }}</span>
                  <span :class="['pc-txn-amount', txn.amount < 0 ? 'pc-txn-amount--out' : 'pc-txn-amount--in']">
                    {{ txn.amount < 0 ? "−" : "+" }}{{ formatMoney(Math.abs(txn.amount)) }}
                  </span>
                </div>
                <!-- Blank while it is still being read: an empty-state message that
                     turns into rows is its own little flash. -->
                <div v-if="!recentMoney.length && !highlightsPending" class="pc-txns-empty">
                  Nothing recorded yet
                </div>
              </div>
            </div>


            <div v-if="!isManage && !isHardcore" class="pc-maintenance-row">
              <span class="pc-maintenance-label">Police</span>
              <button
                type="button"
                class="pc-switch"
                :class="{ 'pc-switch--active': policeEnabled }"
                :aria-pressed="policeEnabled"
                :disabled="incompatibleVersion || policeToggleSaving"
                @click.stop="onPoliceSwitchClick">
                <span class="pc-switch-track">
                  <span class="pc-switch-thumb" />
                </span>
                <span class="pc-switch-value">{{ policeEnabled ? "On" : "Off" }}</span>
              </button>
            </div>

            <div class="pc-maintenance-row">
              <span class="pc-maintenance-label">Experimental maintenance</span>
              <button
                type="button"
                class="pc-switch"
                :class="{ 'pc-switch--active': experimentalMaintenanceEnabled }"
                :aria-pressed="experimentalMaintenanceEnabled"
                :disabled="incompatibleVersion || maintenanceToggleSaving"
                @click.stop="onExperimentalMaintenanceSwitchClick">
                <span class="pc-switch-track">
                  <span class="pc-switch-thumb" />
                </span>
                <span class="pc-switch-value">{{ experimentalMaintenanceEnabled ? "On" : "Off" }}</span>
              </button>
            </div>

            <div class="pc-btns">
              <button
                v-bng-sound-class="'bng_click_generic'"
                class="pc-btn pc-btn--secondary"
                @click="enableManage">Manage</button>
              <button
                v-bng-sound-class="'bng_click_generic'"
                class="pc-btn pc-btn--secondary"
                :disabled="incompatibleVersion"
                @click="openSaves">Saves</button>
              <button
                v-bng-sound-class="'bng_click_generic'"
                class="pc-btn pc-btn--primary"
                :disabled="active || incompatibleVersion"
                @click="$emit('load', id)">{{ hero && !active ? "Continue" : "Load" }}</button>
            </div>
          </div>
      </div>
    </div>

    <div v-if="active" class="pc-active-bar" />
  </div>
</template>

<script>
const MENU_ITEMS = {
  RENAME: "rename",
  DELETE: "delete",
}
</script>

<script setup>
import { computed, inject, nextTick, onBeforeUnmount, ref, watch } from "vue"
import { BngInput, BngIcon } from "@/common/components/base"
import { vBngScopedNav, vBngSoundClass, vBngOnUiNav, vBngTextInput } from "@/common/directives"
import { timeSpan } from "@/utils/datetime"
import { shrinkNum } from "@/utils/format"
import { lua } from "@/bridge"
import { openConfirmation } from "@/services/popup"
import { PROFILE_NAME_MAX_LENGTH } from "../../stores/profilesStore"
import { getProfileModeChipLabel, resolveProfileDifficulty, resolveProfileStartMode } from "./start/careerStartModes.js"
import { setFocus } from "@/services/uiNavFocus"

const props = defineProps({
  id: { type: String, required: true },
  displayName: { type: String, default: "" },
  /**
   * Not required: a slot whose save cannot be read has no date, no creation
   * date and no version to compare — the Lua sends an id and saveDataMissing
   * and nothing else. The card already renders that state; demanding the
   * fields only produced a warning per field per such profile.
   */
  date: { type: String, default: "" },
  creationDate: { type: String, default: "" },
  incompatibleVersion: Boolean,
  outdatedVersion: { type: Boolean, default: false },
  preview: { type: String, default: "/ui/modules/career/profilePreview_WCUSA.jpg" },
  beamXP: Object,
  vouchers: Object,
  money: Object,
  active: Boolean,
  branches: Array,
  freSkills: { type: Array, default: () => [] },
  activeChallenge: [Object, String],
  careerStartMode: String,
  difficultyMode: String,
  cheatsMode: Boolean,
  experimentalMaintenanceEnabled: Boolean,
  policeEnabled: { type: Boolean, default: true },
  /** Set by the Lua when the slot has no playerAttributes.json to read. */
  saveDataMissing: Boolean,
  forceCloseManage: Boolean,
  /** The featured save: wider, split in two, and open without being hovered. */
  hero: Boolean,
  /** Ringed while browsing: chosen, but not yet opened. */
  selected: Boolean,
  insuranceScore: Object,
  vehicleCount: Number,
  garageCount: Number,
  /** [{amount, label, time}] newest first — fetched by the parent, hero only. */
  recentMoney: { type: Array, default: () => [] },
  /** Owned vehicles valued at age + mileage, summed. Hero only. */
  assetValue: Number,
  /** {name, location, image} for whatever was being driven at the last save. */
  lastVehicle: Object,
  /** True while the above are still being read, so empty is not mistaken for none. */
  highlightsPending: Boolean,
  /** The strip is in motion; hover means nothing until it stops. */
  sliding: Boolean,
  /** Resolved by the parent against overhaul_maps — the id alone is not a label. */
  mapLabel: { type: String, default: "" },
})

const emit = defineEmits(["card:activate", "manage:change", "backup:change", "load", "saves:load"])

const hovered = ref(false)
const isManage = ref(false)
const currentMenu = ref(null)
const backupStep = ref(null)
const backupName = ref("")
const backupNameError = ref(null)
const backupCancelBtn = ref(null)
const backupCreateBtn = ref(null)
const maintenanceToggleSaving = ref(false)
const policeToggleSaving = ref(false)
const savesOpen = ref(false)
const savesLoading = ref(false)
const saveFolders = ref([])

/** Picking a save is a state of this card, not a screen you get sent to. */
async function openSaves() {
  savesOpen.value = true
  savesLoading.value = true
  saveFolders.value = []
  emit("card:activate", true)
  emit("manage:change", true)
  try {
    const folders = await lua.career_career.getSaveFoldersForProfile(props.id)
    saveFolders.value = Array.isArray(folders) ? folders : Object.values(folders || {})
  } catch (_) {
    saveFolders.value = []
  } finally {
    savesLoading.value = false
  }
}

function closeSaves() {
  savesOpen.value = false
  saveFolders.value = []
  emit("card:activate", false)
  emit("manage:change", false)
}

function onLoadSave(save) {
  if (!save || save.incompatibleVersion || save.corrupted) return
  emit("saves:load", props.id, save.name)
}

const savesSubtitle = computed(() => {
  if (savesLoading.value) return "Reading save folders…"
  const n = saveFolders.value.length
  if (!n) return "Nothing stored yet"
  return `${n} to choose from — the newest is loaded by default`
})

function saveRowSub(save) {
  if (save.incompatibleVersion) return "Saved with an older version"
  if (save.corrupted) return "Corrupted"
  return timeSpan(save.date)
}

watch(() => props.forceCloseManage, (shouldClose) => {
  if (shouldClose && isManage.value) {
    isManage.value = false
    currentMenu.value = null
    emit("card:activate", false)
    emit("manage:change", false)
  }
  if (shouldClose && savesOpen.value) closeSaves()
  if (shouldClose && backupStep.value) {
    if (backupStep.value === "loading") return
    backupStep.value = null
    backupName.value = ""
    backupNameError.value = null
    emit("backup:change", false)
    if (!isManage.value) emit("card:activate", false)
  }
})

const validateName = inject("validateName")
const nameError = ref(null)
const bodyRef = ref(null)
const startButton = ref(null)
const cancelButton = ref(null)

const bgStyle = computed(() => ({
  backgroundImage: `url(${props.preview})`,
}))

/** timeSpan returns "-" when there is no date. An empty line says less than no line. */
const lastPlayedDescription = computed(() => {
  const span = timeSpan(props.date)
  return span && span !== "-" ? span : null
})

/**
 * Plain "$" rather than the Beam Bucks glyph. Six figures and up are shortened,
 * because the balance and the history column both have to hold one line.
 */
function formatMoney(value) {
  const n = Number(value)
  if (!Number.isFinite(n)) return "$0"
  const abs = Math.abs(n)
  // Cents only where they carry meaning. On a four-figure balance they are noise
  // and they were wide enough to push the figure into the tile beside it.
  let body
  if (abs > 100000) body = shrinkNum(abs, 1)
  else if (abs >= 1000) body = Math.round(abs).toLocaleString()
  else body = abs.toLocaleString(undefined, { maximumFractionDigits: 2 })
  return `${n < 0 ? "−" : ""}$${body}`
}

/** One line under the name. The map is its own tag in the artwork's top corner. */
const heroStrapline = computed(() => {
  if (!lastPlayedDescription.value) return ""
  return `${props.active ? "Last saved" : "Last played"} ${lastPlayedDescription.value} ago`
})

/** The hero's panel is the card, not a drawer — it never has to be revealed. */
const showBody = computed(() => props.hero || hovered.value || isManage.value || savesOpen.value || !!backupStep.value)

const formatCount = num => {
  const n = Number(num)
  if (!Number.isFinite(n)) return "0"
  return Math.round(n).toLocaleString()
}

/**
 * What the save is worth in things, not in points. BeamXP is deliberately absent:
 * nothing in the overhaul gates on it, so it was a number with no consequence.
 */
const heroMoneyTiles = computed(() => [
  { label: "Balance", value: formatMoney(props.money?.value || 0), cash: true },
  // "—" while the figure is still being read — "$0" would read as broke.
  { label: "Asset value", value: props.assetValue == null ? "—" : formatMoney(props.assetValue) },
])

const heroCountTiles = computed(() => {
  const tiles = []
  if (props.vehicleCount != null) tiles.push({ label: "Vehicles", value: formatCount(props.vehicleCount) })
  if (props.garageCount != null) tiles.push({ label: "Garages", value: formatCount(props.garageCount) })
  // Vouchers deliberately absent: nothing in the overhaul spends them.
  if (props.insuranceScore) tiles.push({ label: "Driver score", value: formatCount(props.insuranceScore.value) })
  return tiles
})

function skillRatio(skill) {
  const span = Number(skill?.neededForNext)
  const progress = Number(skill?.curLvlProgress)
  if (!Number.isFinite(span) || span <= 0 || !Number.isFinite(progress)) return 0
  return Math.min(1, Math.max(0, progress / span))
}

const activeView = computed(() => {
  // Loading and loaded are different heights, and the drawer animates to whatever
  // this key last resolved to — so they have to be different keys.
  if (savesOpen.value) return savesLoading.value ? "saves-loading" : `saves-${saveFolders.value.length}`
  if (backupStep.value === "name") return "backup-name"
  if (backupStep.value === "loading") return "backup-loading"
  if (backupStep.value === "success") return "backup-success"
  if (!isManage.value) return "status"
  if (currentMenu.value === MENU_ITEMS.RENAME) return "rename"
  if (currentMenu.value === MENU_ITEMS.DELETE) return "delete"
  return "manage"
})

watch(activeView, () => {
  const el = bodyRef.value
  // The hero's panel is a fixed-height column, so animating it to its content
  // height would collapse it out of the card's grid.
  if (!el || !showBody.value || props.hero) return
  const from = el.offsetHeight
  el.style.height = from + "px"
  nextTick(() => {
    el.style.height = "auto"
    const to = el.offsetHeight
    el.style.height = from + "px"
    el.offsetHeight
    el.style.transition = "height 0.25s cubic-bezier(0.22, 1, 0.36, 1)"
    el.style.height = to + "px"
    const done = e => {
      if (e.target !== el) return
      el.style.height = ""
      el.style.transition = ""
      el.removeEventListener("transitionend", done)
    }
    el.addEventListener("transitionend", done)
  })
})

const topSkills = computed(() => {
  const list = props.freSkills
  if (!list || !list.length) return []
  return [...list]
    .sort((a, b) => {
      const ld = (Number(b.level) || 0) - (Number(a.level) || 0)
      if (ld !== 0) return ld
      return (Number(b.value) || 0) - (Number(a.value) || 0)
    })
    .slice(0, props.hero ? 5 : 3)
})

const modeChipLabel = computed(() => getProfileModeChipLabel(props))
const modeChipClass = computed(() => {
  // Custom is the only path that can carry cheats, so it gets its own colour.
  if (resolveProfileStartMode(props) === "custom" || props.cheatsMode) {
    return "pc-chip pc-chip--cheats"
  }
  return "pc-chip pc-chip--challenge"
})
const isHardcore = computed(() => resolveProfileDifficulty(props)?.id === "hardcore")

/**
 * Hover is only real if the pointer went to the card. While the strip slides,
 * the cards go to the pointer — every one that passes under it fires mouseover
 * and would light up on the way past. Held off until the strip is at rest.
 */
function onPointerOver() {
  if (props.sliding) return
  hovered.value = true
}

watch(
  () => props.sliding,
  isSliding => {
    if (isSliding) hovered.value = false
  }
)

const snapDrawerShut = ref(false)
let snapTimer = null

watch(
  () => props.hero,
  isHero => {
    if (isHero) return
    hovered.value = false
    snapDrawerShut.value = true
    cancelAnimationFrame(snapTimer)
    snapTimer = requestAnimationFrame(() =>
      (snapTimer = requestAnimationFrame(() => {
        snapDrawerShut.value = false
      }))
    )
  }
)

onBeforeUnmount(() => cancelAnimationFrame(snapTimer))

/** Dropped the moment a recorded thumbnail fails to load, so a broken-image
    box never sits in the artwork; resets when the vehicle changes. */
const vehicleImageOk = ref(true)

watch(
  () => props.lastVehicle?.image,
  () => {
    vehicleImageOk.value = true
  }
)

const hasBadges = computed(
  () => !!(modeChipLabel.value || props.experimentalMaintenanceEnabled || props.saveDataMissing || props.outdatedVersion)
)

const originalName = computed(() => props.displayName || props.id)

const validateFn = name => {
  let res = validateName(name)
  // The save's own current name is never a conflict with itself.
  if (name === props.id || name === originalName.value) res = null
  nameError.value = res || null
  return !res
}

const canDeactivate = () => !isManage.value && !savesOpen.value && backupStep.value !== "loading"
const canBubbleEvent = e => e.detail.name === "menu" && !isManage.value && !savesOpen.value && !backupStep.value

const onScopeChanged = value => {
  if (!value && savesOpen.value) closeSaves()
  if (!value && isManage.value) {
    isManage.value = false
    currentMenu.value = null
    emit("manage:change", false)
  }
  if (!value && backupStep.value && backupStep.value !== "loading") {
    cancelBackup()
  }
}

function enableManage() {
  isManage.value = true
  emit("card:activate", true)
  emit("manage:change", true)
}

function goBack() {
  if (savesOpen.value) {
    closeSaves()
    return
  }
  if (backupStep.value === "name") {
    cancelBackup()
    return
  }
  if (backupStep.value === "loading" || backupStep.value === "success") {
    return
  }
  if (currentMenu.value) {
    currentMenu.value = null
  } else {
    isManage.value = false
    emit("card:activate", false)
    emit("manage:change", false)
  }
}

function validateBackupName(name) {
  const res = validateName(name)
  backupNameError.value = res || null
  return !res
}

function onBackupInputFocus() {
  try { lua.setCEFTyping(true) } catch (_) {}
}

function onBackupInputBlur() {
  try { lua.setCEFTyping(false) } catch (_) {}
}

function onBackupInput(e) {
  backupName.value = e.target.value
  validateBackupName(backupName.value)
}

function onBackupEnter() {
  const focusEl = backupNameError.value || !backupName.value.trim() ? backupCancelBtn : backupCreateBtn
  if (focusEl.value) nextTick(() => setFocus(focusEl.value))
}

function startBackup() {
  if (isManage.value) {
    isManage.value = false
    currentMenu.value = null
    emit("manage:change", false)
  }
  backupName.value = ""
  backupNameError.value = null
  backupStep.value = "name"
  emit("card:activate", true)
  emit("backup:change", true)
}

function cancelBackup() {
  if (backupStep.value === "loading") return
  backupStep.value = null
  backupName.value = ""
  backupNameError.value = null
  emit("backup:change", false)
  if (!isManage.value) emit("card:activate", false)
}

async function confirmBackup() {
  if (!validateBackupName(backupName.value) || backupNameError.value) return
  const trimmed = backupName.value.trim()
  backupStep.value = "loading"
  try {
    const ok = await lua.career_saveSystem.duplicateSaveSlot(props.id, trimmed)
    if (ok) {
      await lua.career_career.sendAllCareerProfilesData()
      backupStep.value = "success"
      emit("backup:change", false)
      window.setTimeout(() => {
        backupStep.value = null
        backupName.value = ""
      }, 1500)
    } else {
      backupStep.value = "name"
      backupNameError.value = "Backup failed"
    }
  } catch (_) {
    backupStep.value = "name"
    backupNameError.value = "Backup failed"
  }
}

// Seed from what the card shows, not the on-disk folder id — otherwise renaming
// "Profile 1" starts you editing "profile1" and saving unchanged silently renames it.
const saveName = ref(props.displayName || props.id)
const deleteProfile = () => {
  lua.career_saveSystem.removeProfile(props.id)
  lua.career_career.sendAllCareerProfilesData()
}
const updateProfileName = async () => {
  await lua.career_saveSystem.renameProfile(props.id, saveName.value)
  await lua.career_career.sendAllCareerProfilesData()
}

async function onPoliceSwitchClick() {
  if (props.incompatibleVersion || policeToggleSaving.value || isHardcore.value) return
  policeToggleSaving.value = true
  try {
    const next = props.policeEnabled === false
    const ok = await lua.career_career.setPoliceEnabledForSaveSlot(props.id, next)
    if (ok) {
      await lua.career_career.sendAllCareerProfilesData()
      // Only warn when already in a session — toggle during load is applied on activate.
      const inSession = await lua.career_career.isActive()
      if (inSession) {
        await openConfirmation(
          "Police",
          "Restart for changes to take effect.",
          [{ label: "OK", value: true, extras: { default: true } }]
        )
      }
    }
  } finally {
    policeToggleSaving.value = false
  }
}

async function onExperimentalMaintenanceSwitchClick() {
  if (props.incompatibleVersion || maintenanceToggleSaving.value) return
  maintenanceToggleSaving.value = true
  try {
    const next = !props.experimentalMaintenanceEnabled
    const ok = await lua.career_career.setMaintenanceModeForSaveSlot(props.id, next)
    if (ok) {
      await lua.career_career.sendAllCareerProfilesData()
    }
  } finally {
    maintenanceToggleSaving.value = false
  }
}

function onInputBlur() {
  let focusButton = nameError.value || saveName.value === originalName.value ? cancelButton : startButton
  if (focusButton.value) nextTick(() => setFocus(focusButton.value))
}
</script>

<style lang="scss" scoped>
@use "@/styles/modules/mixins" as *;

.pc {
  position: relative;
  display: grid;
  grid-template-rows: 1fr auto;
  height: 100%;
  font-size: calc-ui-rem();
  color: #fff;
  border-radius: calc-ui-rem(1);
  overflow: hidden;
  cursor: default;

  &:hover, &.pc--hover {
    transform: translateY(-3px);
    transition: transform 0.22s ease-out;
  }

  /**
   * Two phases, in this order: the card rises to full height, then the panel
   * wipes open to the right. Selecting it does not slam a finished card into
   * place — it grows, then opens.
   */
  transition:
    transform 0.22s ease-out,
    height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    min-height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    max-height 0.2s cubic-bezier(0.33, 1, 0.68, 1),
    width 0.3s cubic-bezier(0.33, 1, 0.68, 1) 0.16s,
    min-width 0.3s cubic-bezier(0.33, 1, 0.68, 1) 0.16s;

  &.pc--outdated {
    filter: grayscale(0.7);
    opacity: 0.7;
  }
}

/**
 * The featured card is the same component turned on its side: art in one column,
 * the panel that is normally a hover drawer permanently open in the other.
 */
.pc--hero {
  grid-template-rows: minmax(0, 1fr);
  /**
   * The artwork column is fixed and the panel takes whatever is left, so the
   * card's growing width opens the panel rather than crushing the artwork.
   * 22rem is exactly an unselected card, which is why the first phase of the
   * reveal can change height alone without anything moving sideways.
   */
  grid-template-columns: calc-ui-rem(22) minmax(0, 1fr);
  box-shadow:
    0 0 0 1px rgba(255, 122, 26, 0.35),
    0 18px 48px rgba(0, 0, 0, 0.55);

  /* It is the anchor of the strip — it should not drift under the cursor. */
  &:hover,
  &.pc--hover {
    transform: none;
  }

  .pc-drawer {
    transition: none;
  }

  .pc-body {
    height: 100%;
    width: calc-ui-rem(28);
    padding: 0.9em 0.9em 0;
    overflow-y: auto;
    /* Dim: this one runs the full height of the panel, and in orange it read as
       a design element rather than a scrollbar. */
    scrollbar-width: thin;
    scrollbar-color: rgba(148, 163, 184, 0.35) transparent;
  }

  /* Fill whatever the persistent header leaves, so Back and Continue land at the
     bottom edge instead of floating halfway up a mostly empty panel. */
  .pc-status-section,
  .pc-manage-section,
  .pc-backup-section {
    display: flex;
    flex: 1 1 auto;
    flex-direction: column;
    min-height: 0;
  }

  /* Nothing in here may be compressed below its content height. Flex's default
     shrink let the skills list be squeezed and then paint over the rows under
     it; if it does not fit, the panel scrolls instead. */
  .pc-status-section > * {
    flex-shrink: 0;
  }

  .pc-saves-list {
    max-height: none;
  }

  .pc-header {
    padding: 0 1.15em 1em;
  }

  /* Taller than the small cards' scrim: this column is mostly sky, and the name
     sits over it at twice the size. */
  .pc-image-overlay {
    background: linear-gradient(
      180deg,
      rgba(0, 0, 0, 0.05) 0%,
      rgba(0, 0, 0, 0.2) 45%,
      rgba(0, 0, 0, 0.82) 100%
    );
  }

  .pc-name {
    font-size: 2.15em;
  }

  /* Skills and money history sit beside each other rather than stacking, which
     is what made the single column read as one undifferentiated list. */
  .pc-detail {
    display: grid;
    align-items: start;
  }

  /* Ruled, like the figures above. A full-width progress bar running to a bare
     18px gutter read as bleeding into the column beside it. */
  /* Not even: skill names are short and right-align a level, while the money
     labels are free text and were losing half of themselves to the ellipsis. */
  .pc-detail--split {
    grid-template-columns: 0.88fr 1.12fr;

    .pc-skills {
      padding-right: 1em;
    }

    .pc-txns {
      padding-left: 1em;
      border-left: 1px solid #1e2533;
    }
  }


  .pc-skills {
    margin-bottom: 0;
  }

  /**
   * A grid, not a wrapping flex row. Flex decides line breaks from each item's
   * unshrunk width, so a long skill name pushed its level onto a second line
   * instead of ellipsising — rows grew by a line each and the panel gained a
   * scrollbar. Here the name column is the only flexible one and it truncates,
   * so every row is exactly the same height whatever the name is.
   */
  .pc-skill {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr) auto;
    align-items: center;
    column-gap: 0.4em;
    row-gap: 0.15em;
    padding: 0.1em 0;
  }

  /* The ruled rows above already draw lines; their own border kept stacking
     more onto the same few pixels. */
  .pc-maintenance-row {
    padding: 0.3em 0;
    margin-bottom: 0;
    border-bottom: 0;
  }

  /**
   * Load leads on its own row; Manage and Saves share the one below it. The
   * block is pinned because the panel scrolls — margin-top:auto alone would push
   * it past the bottom edge the moment the stats are taller than the card.
   */
  .pc-btns {
    position: sticky;
    bottom: 0;
    flex-wrap: wrap;
    margin-top: auto;
    padding: 0.6em 0 0.9em;
    background: linear-gradient(180deg, rgba(11, 15, 25, 0) 0%, #0b0f19 0.6em);

    .pc-btn--primary {
      order: -1;
      flex: 1 0 100%;
      padding: 0.55em 0;
      font-size: 1em;
      font-weight: 700;
    }
  }
}

.pc-eyebrow {
  font-size: 0.72em;
  font-weight: 800;
  letter-spacing: 0.13em;
  text-transform: uppercase;
  color: #ff9647;
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.6);
  margin-bottom: 0.15em;
}

.pc-col-title,
.pc-tile-cap {
  font-weight: 700;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.45);
}

.pc-col-title {
  font-size: 0.68em;
}

/* Flex, not a fixed column count — the strip has to stay even however many of
   these actually have a value to show. */
.pc-tiles {
  display: flex;
  padding-bottom: 0.5em;
  margin-bottom: 0.5em;
  border-bottom: 1px solid #1e2533;
}

.pc-tiles--money {
  padding-bottom: 0.4em;
  margin-bottom: 0.4em;
}

/* Ruled columns rather than gaps: bare numbers in a row need the divisions
   drawn, otherwise they read as one number. */
.pc-tile {
  display: flex;
  flex: 1 1 0;
  flex-direction: column;
  gap: 0.1em;
  min-width: 0;
  padding: 0 0.6em;
  border-left: 1px solid #1e2533;

  &:first-child {
    padding-left: 0;
    border-left: 0;
  }
}

.pc-tile-cap {
  font-size: 0.6em;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.pc-tile-num {
  font-size: 1.1em;
  font-weight: 800;
  line-height: 1.1;
}

/* Both money figures read large; only the spendable one is green. */
.pc-tiles--money .pc-tile-num {
  font-size: 1.4em;
}

.pc-tile--cash .pc-tile-num {
  color: #86efac;
}

/* Two columns on the featured card, one plain block everywhere else. */
.pc-detail {
  min-height: 0;
}

.pc-col-title {
  margin-bottom: 0.3em;
}

.pc-txns {
  display: flex;
  flex-direction: column;
  gap: 0.15em;
  min-width: 0;
}

.pc-txn {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.6em;
  padding: 0.16em 0;
  font-size: 0.78em;
  border-bottom: 1px solid rgba(30, 37, 51, 0.7);
}

.pc-txn-label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: rgba(255, 255, 255, 0.7);
}

.pc-txn-amount {
  flex: 0 0 auto;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}

.pc-txn-amount--in { color: #86efac; }
.pc-txn-amount--out { color: #fca5a5; }

.pc-txns-empty {
  padding-top: 0.2em;
  font-size: 0.75em;
  color: rgba(255, 255, 255, 0.35);
}

/* Arrives after the card does, so it eases in rather than appearing mid-frame. */
.pc-vehicle {
  animation: pc-fade-in 0.18s ease-out;
}

@keyframes pc-fade-in {
  from { opacity: 0; }
  to { opacity: 1; }
}

.pc-bar {
  grid-column: 1 / -1;
  height: 0.25em;
  margin-bottom: 0.1em;
  border-radius: 999px;
  background: rgba(100, 116, 139, 0.3);
  overflow: hidden;
}

.pc-bar-fill {
  height: 100%;
  border-radius: 999px;
  background: linear-gradient(90deg, #ff7a1a, #ff9647);
}

/**
 * Only the drawer snaps. The card itself keeps its size transition on the way
 * out, because a deselected card collapsing instantly shunts everything to its
 * right across by the width difference in a single frame — a hard jump the
 * slide then has to absorb. Shrinking it is safe: once deselected it is back to
 * the stacked layout, which at a wide size is simply a wide picture, not the
 * broken half-state that made growing it a problem.
 */
.pc--snap-shut .pc-drawer {
  transition: none;
}

.pc-image {
  position: relative;
  min-height: 0;
  background-size: cover;
  background-position: center;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
}

.pc-drawer {
  display: grid;
  min-height: 0;
  overflow: hidden;
  background: #0b0f19;
  grid-template-rows: minmax(0, 0fr);
  transition: grid-template-rows 0.32s cubic-bezier(0.22, 1, 0.36, 1);

  &.pc-drawer--open {
    grid-template-rows: minmax(0, 1fr);
  }
}

.pc-image-overlay {
  position: absolute;
  inset: 0;
  background: linear-gradient(180deg, rgba(0,0,0,0.05) 0%, rgba(0,0,0,0.15) 40%, rgba(0,0,0,0.65) 100%);
  pointer-events: none;
}

.pc-header {
  position: relative;
  z-index: 1;
  padding: 0 1em 0.7em;
}

.pc-name {
  font-weight: 900;
  font-size: 2em;
  line-height: 1.15;
  letter-spacing: 0.01em;
  text-shadow: 0 2px 8px rgba(0,0,0,0.5);
  font-family: "Overpass", var(--fnt-defs);
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.pc-playing {
  margin-top: 0.2em;
  font-weight: 700;
  font-size: 0.8em;
  color: var(--bng-orange-400, #fb923c);
  text-shadow: 0 1px 4px rgba(0,0,0,0.5);
}

.pc-last-played {
  margin-top: 0.2em;
  font-size: 0.78em;
  opacity: 0.75;
  text-shadow: 0 1px 4px rgba(0,0,0,0.4);
}

/* Quiet: it names the picture, it is not a headline. */
.pc-map-tag {
  position: absolute;
  top: 0.8em;
  left: 0.9em;
  z-index: 1;
  font-size: 0.78em;
  font-weight: 600;
  letter-spacing: 0.02em;
  color: rgba(255, 255, 255, 0.72);
  text-shadow: 0 1px 5px rgba(0, 0, 0, 0.8);
}

/* Top corner of the art, opposite the name block at the bottom. */
.pc-vehicle {
  position: absolute;
  top: 0.7em;
  right: 0.7em;
  z-index: 1;
  width: 10em;
  padding: 0.45em 0.55em 0.5em;
  border-radius: 10px;
  background: rgba(6, 9, 16, 0.72);
  border: 1px solid rgba(148, 163, 184, 0.25);
  backdrop-filter: blur(3px);
}

.pc-vehicle-img {
  display: block;
  width: 100%;
  height: auto;
  margin-bottom: 0.15em;
}

.pc-vehicle-eyebrow {
  font-size: 0.6em;
  font-weight: 700;
  letter-spacing: 0.09em;
  text-transform: uppercase;
  color: rgba(255, 255, 255, 0.45);
}

.pc-vehicle-name {
  font-size: 0.78em;
  font-weight: 700;
  line-height: 1.2;
}

.pc-vehicle-loc {
  font-size: 0.68em;
  color: rgba(255, 255, 255, 0.55);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* Place and recency on one line — two facts do not need two rows. */
.pc-strapline {
  margin-top: 0.25em;
  font-size: 0.82em;
  color: rgba(255, 255, 255, 0.8);
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.55);
}

.pc-badges {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3em;
  margin-top: 0.3em;
}

.pc-chip {
  display: inline-flex;
  align-items: center;
  padding: 0.15em 0.55em;
  border-radius: 8px;
  font-size: 0.72em;
  font-weight: 800;
  box-shadow: 0 3px 8px rgba(0,0,0,0.3);
}
.pc-chip--challenge { background: linear-gradient(90deg, #ff7a1a, #e85f00); }
.pc-chip--cheats { background: linear-gradient(90deg, #9333ea, #7c3aed); }
.pc-chip--maintenance {
  background: linear-gradient(90deg, #0f9f8f, #22c55e);
  color: #f0fdfa;
}
.pc-chip--migration {
  background: linear-gradient(90deg, #c2410c, #9a3412);
  color: #fff7ed;
}
.pc-chip--incomplete {
  background: rgba(15, 23, 42, 0.85);
  border: 1px solid rgba(148, 163, 184, 0.55);
  color: rgba(255, 255, 255, 0.75);
}

.pc-body {
  display: flex;
  flex-direction: column;
  min-height: 0;
  overflow: hidden;
  padding: 0.55em 0.7em 0.65em;
  background: #0b0f19;
}

.pc-money {
  display: flex;
  justify-content: flex-end;
  font-weight: 700;
  font-size: 1.05em;
  padding-bottom: 0.4em;
  border-bottom: 1px solid #1e2533;
  margin-bottom: 0.35em;
}

.pc-maintenance-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5em;
  padding: 0.35em 0;
  margin-bottom: 0.35em;
  border-bottom: 1px solid #1e2533;
}

.pc-maintenance-label {
  font-size: 0.78em;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.75);
}

.pc-switch {
  display: inline-flex;
  align-items: center;
  gap: 0.4em;
  border: 0;
  background: transparent;
  color: #fff;
  cursor: pointer;
  font-size: 0.78em;
  font-weight: 700;
  padding: 0.15em 0;

  &:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
}

.pc-switch-track {
  position: relative;
  width: 2.4em;
  height: 1.25em;
  border-radius: 999px;
  background: #374151;
  transition: background 0.2s ease;
}

.pc-switch--active .pc-switch-track {
  background: linear-gradient(90deg, #0f9f8f, #22c55e);
}

.pc-switch-thumb {
  position: absolute;
  top: 0.12em;
  left: 0.12em;
  width: 1em;
  height: 1em;
  border-radius: 50%;
  background: #fff;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.35);
  transition: transform 0.2s ease;
}

.pc-switch--active .pc-switch-thumb {
  transform: translateX(1.1em);
}

.pc-switch-value {
  min-width: 1.6em;
  text-align: right;
  opacity: 0.85;
}

.pc-skills {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
  margin-bottom: 0.5em;
}

.pc-skill {
  display: flex;
  align-items: center;
  gap: 0.4em;
  padding: 0.2em 0;

  .pc-skill-icon {
    flex: 0 0 auto;
    font-size: 1.15em;
    opacity: 0.85;
  }

  .pc-skill-name {
    flex: 1 1 auto;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: 600;
    font-size: 0.82em;
  }

  .pc-skill-lvl {
    flex: 0 0 auto;
    font-size: 0.72em;
    font-weight: 700;
    opacity: 0.6;
  }
}

.pc-btns {
  display: flex;
  gap: 0.5em;
  margin-top: 0.15em;
}

.pc-btns--back {
  margin-top: auto;
  padding-top: 0.5em;
}

/**
 * `filter: brightness()` measured ~6/255 on these colours — invisible, and hover
 * and pressed were within ~1 level of each other. Each state now changes the
 * colour outright and pressed also moves, so it reads without a comparison shot.
 */
.pc-btn {
  flex: 1 1 0;
  border: 0;
  border-radius: 8px;
  padding: 0.4em 0;
  font-size: 0.88em;
  font-weight: 500;
  cursor: pointer;
  transition: background 90ms ease, box-shadow 90ms ease, transform 60ms ease;

  &:focus-visible {
    outline: 2px solid #ff7a1a;
    outline-offset: 2px;
  }

  &:disabled {
    opacity: 0.4;
    cursor: not-allowed;
    transform: none;
    box-shadow: none;
  }
}

.pc-btn--primary {
  background: linear-gradient(90deg, #ff7a1a, #e85f00);
  color: #fff;

  &:hover:not(:disabled) {
    background: linear-gradient(90deg, #ff9647, #fb7215);
    box-shadow: 0 0 0 1px rgba(255, 168, 102, 0.75);
  }

  &:active:not(:disabled) {
    background: linear-gradient(90deg, #d95f00, #b34c00);
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.45);
    transform: translateY(1px);
  }
}

.pc-btn--secondary {
  background: #374151;
  color: #f3f4f6;

  &:hover:not(:disabled) {
    background: #4d5b6f;
    box-shadow: 0 0 0 1px rgba(148, 163, 184, 0.55);
  }

  &:active:not(:disabled) {
    background: #262f3c;
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.45);
    transform: translateY(1px);
  }
}

.pc-btn--danger {
  background: #dc2626;
  color: #fff;

  &:hover:not(:disabled) {
    background: #f04444;
    box-shadow: 0 0 0 1px rgba(248, 113, 113, 0.8);
  }

  &:active:not(:disabled) {
    background: #a41919;
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.5);
    transform: translateY(1px);
  }
}

/* Every sub-view opens with the same two lines, so switching between them does
   not feel like landing in an unlabelled box. */
.pc-section-head {
  padding-bottom: 0.45em;
  margin-bottom: 0.15em;
  border-bottom: 1px solid #1e2533;
}

.pc-section-title {
  font-size: 1.05em;
  font-weight: 800;
  line-height: 1.2;
}

.pc-section-title--danger {
  color: #fca5a5;
}

.pc-section-sub {
  font-size: 0.72em;
  color: rgba(255, 255, 255, 0.45);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.pc-actions {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
}

.pc-action {
  display: flex;
  flex-direction: column;
  gap: 0.05em;
  width: 100%;
  text-align: left;
  border: 0;
  border-radius: 8px;
  padding: 0.45em 0.6em;
  background: #1e2533;
  color: #f3f4f6;
  font-family: inherit;
  cursor: pointer;
  transition: background 0.12s ease, box-shadow 0.12s ease, transform 0.06s ease;

  &:hover:not(:disabled) {
    background: #2c3548;
    box-shadow: 0 0 0 1px rgba(148, 163, 184, 0.55);
  }

  &:active:not(:disabled) {
    background: #161c27;
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.45);
    transform: translateY(1px);
  }

  &:focus-visible {
    outline: 2px solid #ff7a1a;
    outline-offset: 2px;
  }

  &:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
}

.pc-action--danger {
  background: rgba(127, 29, 29, 0.35);

  .pc-action-label {
    color: #fca5a5;
  }

  &:hover:not(:disabled) {
    background: rgba(153, 27, 27, 0.55);
    box-shadow: 0 0 0 1px rgba(248, 113, 113, 0.6);
  }

  &:active:not(:disabled) {
    background: rgba(87, 20, 20, 0.7);
  }
}

.pc-action-label {
  font-size: 0.9em;
  font-weight: 600;
}

.pc-action-desc {
  font-size: 0.7em;
  line-height: 1.25;
  color: rgba(255, 255, 255, 0.5);
}

.pc-manage-section {
  display: flex;
  flex-direction: column;
  gap: 0.5em;
  min-height: 8em;

  /* BngInput hangs its error 18px below itself with position:absolute. Reserve
     that lane so the message lands in space instead of across the Save button. */
  :deep(.bng-input) {
    margin-bottom: 1.2em;
  }
}

.pc-saves-section {
  gap: 0.35em;
}

.pc-saves-state {
  font-size: 0.82em;
  color: rgba(255, 255, 255, 0.55);
  padding: 0.6em 0;
}

.pc-saves-list {
  display: flex;
  flex-direction: column;
  gap: 0.3em;
  /* Three autosaves is the normal case — only scroll past that. */
  max-height: 12.5em;
  overflow-y: auto;
  scrollbar-width: thin;
  scrollbar-color: rgba(255, 122, 26, 0.75) rgba(100, 116, 139, 0.2);
}

/* Name left, age right — stacked, these read as three blocks rather than a list. */
.pc-save-row {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.6em;
  width: 100%;
  text-align: left;
  border: 0;
  border-radius: 8px;
  padding: 0.4em 0.55em;
  background: #1e2533;
  color: #f3f4f6;
  font-family: inherit;
  cursor: pointer;
  transition: background 0.12s ease, box-shadow 0.12s ease, transform 0.06s ease;

  &:hover:not(:disabled) {
    background: #2c3548;
    box-shadow: 0 0 0 1px rgba(148, 163, 184, 0.55);
  }

  &:active:not(:disabled) {
    background: #161c27;
    box-shadow: inset 0 2px 5px rgba(0, 0, 0, 0.45);
    transform: translateY(1px);
  }

  &:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }
}

.pc-save-row--current {
  box-shadow: inset 0 0 0 1px rgba(255, 122, 26, 0.5);
}

.pc-save-name {
  display: flex;
  align-items: center;
  gap: 0.4em;
  min-width: 0;
  font-size: 0.85em;
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.pc-save-chip {
  font-size: 0.72em;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: #ff9647;
}

.pc-save-sub {
  flex: 0 1 auto;
  min-width: 0;
  font-size: 0.72em;
  color: rgba(255, 255, 255, 0.5);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.pc-delete-prompt {
  font-size: 0.88em;
  padding: 0.5em 0;
}

.pc-btns--backup {
  margin-top: 0.5em;
}

.pc-backup-section {
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  min-height: 7em;
}

.pc-backup-label {
  font-weight: 600;
  font-size: 0.82em;
  color: rgba(255, 255, 255, 0.65);
  padding-left: 0.1em;
}

.pc-backup-input-wrap {
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.1em 0.5em;

  &:focus-within { border-color: rgba(148, 163, 184, 0.5); }
  &.pc-backup-input-wrap--error { border-color: rgba(239, 68, 68, 0.6); }
}

.pc-backup-input {
  width: 100%;
  background: none;
  border: 0;
  outline: none;
  color: #fff;
  font-size: 0.88em;
  font-family: inherit;
}

.pc-backup-error {
  font-size: 0.72em;
  color: #f87171;
  padding-left: 0.15em;
}

.pc-backup-feedback {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 6em;
}

.pc-backup-feedback--success {
  font-weight: 700;
  font-size: 0.95em;
  color: #86efac;
}

.pc-backup-spinner {
  width: 2.25em;
  height: 2.25em;
  border: 3px solid rgba(148, 163, 184, 0.25);
  border-top-color: #ff7a1a;
  border-radius: 50%;
  animation: pc-backup-spin 0.7s linear infinite;
}

@keyframes pc-backup-spin {
  to { transform: rotate(360deg); }
}

.pc-active-bar {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 0.25em;
  background: var(--bng-orange-400, #fb923c);
  z-index: 5;
}

</style>
