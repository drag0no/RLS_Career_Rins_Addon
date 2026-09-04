<template>
  <div
    v-bng-scoped-nav="{ activateOnMount: true }"
    class="profiles-container saves-container"
    @deactivate="onDeactivate"
  >
    <BngScreenHeading class="profiles-title" :preheadings="[$ctx_t('ui.playmodes.career')]">
      {{ heading }}
    </BngScreenHeading>
    <BackAside
      v-bng-on-ui-nav:back,menu="onBack"
      class="profiles-back"
      @click="onBack"
    />

    <div class="profiles-panel saves-panel" :class="{ 'saves-panel--busy': isBusy }">
      <div v-if="isSaveMode" class="saves-toolbar">
        <div class="pt-search saves-name-wrap">
          <input
            v-model="saveName"
            class="pt-input"
            :maxlength="SAVE_NAME_MAX_LENGTH"
            :placeholder="$t('ui.career.profiles.saves.namePlaceholder')"
            :disabled="isBusy"
            @focus="onInputFocus"
            @blur="onInputBlur"
            @keydown.enter.prevent="onSave"
          />
        </div>
        <button
          v-bng-sound-class="'bng_click_generic'"
          class="saves-action-btn"
          type="button"
          :disabled="!canSave"
          @click="onSave"
        >
          {{ saveButtonLabel }}
        </button>
      </div>
      <div v-if="isSaveMode && nameError" class="saves-error">{{ nameError }}</div>

      <div class="saves-list-shell">
        <div v-if="isLoadingSaves" class="saves-state">{{ $t("ui.common.loading") }}</div>
        <div v-else-if="!saveFolders.length" class="saves-state">
          {{ $t("ui.career.profiles.saves.empty") }}
        </div>
        <div v-else class="saves-list">
          <button
            v-for="save in saveFolders"
            :key="save.name"
            type="button"
            class="save-row"
            :class="{
              'save-row--selected': isSaveMode && matchesName(save.name),
              'save-row--current': save.isCurrent,
              'save-row--bad': save.incompatibleVersion || save.corrupted,
            }"
            :disabled="isRowDisabled(save)"
            v-bng-sound-class="'bng_click_generic'"
            @click="onChooseSave(save)"
          >
            <div class="save-row-main">
              <div class="save-row-name">
                {{ save.name }}
                <span v-if="save.isCurrent" class="save-row-chip">Current</span>
              </div>
              <div class="save-row-sub">
                <span v-if="save.incompatibleVersion">{{ $t("ui.career.profiles.warning.incompatibleVersion") }}</span>
                <span v-else-if="save.corrupted">{{ $t("ui.career.profiles.saves.corrupted") }}</span>
                <span v-else>{{ $t("ui.career.profiles.vehicleCountShort", { count: save.vehicleCount || 0 }) }}</span>
              </div>
            </div>
            <div class="save-row-side">
              <BngUnit :money="save.money?.value || 0" />
              <span class="save-row-date">{{ lastPlayed(save) }}</span>
            </div>
            <div class="save-row-actions" @click.stop>
              <button
                v-if="!isSaveMode"
                type="button"
                class="save-icon-btn"
                :disabled="isRowDisabled(save)"
                v-bng-sound-class="'bng_click_generic'"
                :title="$t('ui.common.select')"
                @click="onChooseSave(save)"
              >
                Load
              </button>
              <button
                type="button"
                class="save-icon-btn save-icon-btn--danger"
                :disabled="isDeleteDisabled(save)"
                v-bng-sound-class="'bng_click_generic'"
                :title="$t('ui.career.delete')"
                @click="onDeleteSave(save)"
              >
                Delete
              </button>
            </div>
          </button>
        </div>
      </div>
    </div>
  </div>
  <LegacyMigrationModal
    v-if="migrationReport"
    :report="migrationReport"
    :busy="migrationBusy"
    :error="migrationError"
    @cancel="cancelMigration"
    @migrate="runMigration" />
</template>

<script setup>
import { computed, onBeforeMount, onBeforeUnmount, onMounted, ref, watch } from "vue"
import { BngScreenHeading, BngUnit } from "@/common/components/base"
import { vBngOnUiNav, vBngScopedNav, vBngSoundClass } from "@/common/directives"
import { lua } from "@/bridge"
import { openConfirmation } from "@/services/popup"
import { $translate } from "@/services"
import { timeSpan } from "@/utils/datetime"
import BackAside from "../../../mainmenu/components/BackAside.vue"
import LegacyMigrationModal from "../components/LegacyMigrationModal.vue"
import {
  SAVE_NAME_MAX_LENGTH,
  INVALID_SAVE_NAME_CHARS,
  useProfilesStore,
} from "../../stores/profilesStore"

const props = defineProps({
  profileId: {
    type: String,
    default: "",
  },
  mode: {
    type: String,
    default: "load",
  },
})

const store = useProfilesStore()

const saveFolders = ref([])
const isLoadingSaves = ref(true)
const isSaving = ref(false)
const isDeleting = ref(false)
const isLoadingProfile = ref(false)
const isCareerActive = ref(false)
const resolvedProfileId = ref(props.profileId || "")
const profileDisplayName = ref(props.profileId || "")
const saveName = ref("")
const nameError = ref(null)
let navigatedAway = false
const migrationReport = ref(null)
const migrationBusy = ref(false)
const migrationError = ref("")

const isSaveMode = computed(() => props.mode === "save")
const isBusy = computed(() => isLoadingSaves.value || isSaving.value || isDeleting.value || isLoadingProfile.value)

const heading = computed(() => {
  const displayName = profileDisplayName.value || resolvedProfileId.value || "Career"
  if (isSaveMode.value) {
    return $translate.instant("ui.career.profiles.saves.saveAsTitleFor", { profile: displayName })
  }
  return $translate.instant("ui.career.profiles.saves.titleFor", { profile: displayName })
})

const isOverwrite = computed(() => saveFolders.value.some(save => matchesName(save.name)))
const saveButtonLabel = computed(() =>
  $translate.instant(isOverwrite.value ? "ui.career.profiles.saves.overwrite" : "ui.common.save")
)
const canSave = computed(
  () => isSaveMode.value && !isBusy.value && !!saveName.value.trim() && !getSaveNameError(saveName.value)
)

watch(saveName, name => {
  nameError.value = name ? getSaveNameError(name) : null
})

function matchesName(name) {
  return !!saveName.value && saveName.value.trim().toLowerCase() === String(name || "").toLowerCase()
}

function getSaveNameError(name) {
  const trimmed = (name || "").trim()
  if (!trimmed) return $translate.instant("ui.career.profile.saveNameEmpty")
  if (trimmed.length > SAVE_NAME_MAX_LENGTH) return $translate.instant("ui.career.profile.saveNameTooLong")
  if (INVALID_SAVE_NAME_CHARS.test(trimmed)) return $translate.instant("ui.career.profile.saveNameInvalidChars")
  return null
}

function lastPlayed(save) {
  return save.date ? timeSpan(save.date, null, 1, true) : $translate.instant("ui.common.unknown")
}

function isRowDisabled(save) {
  if (isBusy.value) return true
  return !isSaveMode.value && (save.incompatibleVersion || save.corrupted)
}

function isDeleteDisabled(save) {
  return isBusy.value || !!save.isCurrent
}

function navigate(routeName, params = null) {
  if (lua.extensions?.ui_router?.navigate) {
    lua.extensions.ui_router.navigate(routeName, params, null)
    return
  }
  window.bngVue?.gotoGameState?.(routeName, params || undefined)
}

function goToProfiles() {
  navigatedAway = true
  navigate("career.profiles")
}

function goToExitTarget() {
  navigatedAway = true
  navigate(isCareerActive.value ? "pause" : "menu")
}

async function refreshExitTargetThenGo() {
  const active = await lua.career_career.isActive()
  isCareerActive.value = !!active
  goToExitTarget()
}

function onBack() {
  if (isSaveMode.value) refreshExitTargetThenGo()
  else goToProfiles()
}

function onDeactivate(event) {
  if (event?.detail?.force) return
  if (navigatedAway || isBusy.value) {
    navigatedAway = false
    return
  }
  onBack()
}

async function resolveSaveModeProfile() {
  const current = await lua.career_career.sendCurrentProfileData()
  resolvedProfileId.value = current?.id || ""
  profileDisplayName.value = current?.displayName || current?.id || ""
}

async function loadSaveFolders() {
  isLoadingSaves.value = true
  try {
    saveFolders.value = await store.getSaveFolders(resolvedProfileId.value)
    if (!isSaveMode.value && saveFolders.value[0]?.displayName) {
      profileDisplayName.value = saveFolders.value[0].displayName
    }
  } finally {
    isLoadingSaves.value = false
  }
}

async function onChooseSave(save) {
  if (!save || isRowDisabled(save)) return
  if (isSaveMode.value) {
    saveName.value = save.name
    nameError.value = null
    return
  }
  const report = await lua.career_career.getLegacySavePreflight(resolvedProfileId.value, save.name)
  if (report?.requiresMigration) {
    migrationReport.value = report
    migrationError.value = ""
    return
  }
  isLoadingProfile.value = true
  try {
    navigatedAway = true
    await store.loadProfileSave(resolvedProfileId.value, save.name)
  } finally {
    isLoadingProfile.value = false
  }
}

function cancelMigration() {
  if (migrationBusy.value) return
  migrationReport.value = null
  migrationError.value = ""
}

async function runMigration(options) {
  if (!migrationReport.value || migrationBusy.value) return
  const source = migrationReport.value
  migrationBusy.value = true
  migrationError.value = ""

  // Loading starts the moment the button is pressed: the screen goes up first and the copy
  // is written behind it. The modal is only dropped once the screen covers it, so the fade
  // is not a gap where the save list flashes back. It returns if migration never starts.
  navigatedAway = true
  await store.startMigrationLoadingScreen()
  migrationReport.value = null

  try {
    const result = await lua.career_career.prepareLegacySaveMigration(source.profile, source.saveFolder, options)
    if (!result?.ok) {
      await failMigration(result?.error || "Migration could not be prepared.",
        result?.report && result.report.canMigrate === false ? result.report : source)
      return
    }
    const loaded = await store.loadPreparedMigration(result.targetProfile, result.targetSaveFolder)
    if (loaded === false) await failMigration("The migrated copy was created, but Career did not start.", source)
  } catch (error) {
    await failMigration(error?.message || "Migration failed unexpectedly.", source)
  } finally {
    migrationBusy.value = false
  }
}

/** Dropping the loading screen can bounce the UI to the main menu, so the toast carries the reason too. */
async function failMigration(message, report) {
  navigatedAway = false
  await store.stopMigrationLoadingScreen()
  migrationError.value = message
  migrationReport.value = report
  store.showMigrationError(message)
}

async function onDeleteSave(save) {
  if (!save || isDeleteDisabled(save)) return
  const title = $translate.instant("ui.career.profiles.saves.deleteTitle", { save: save.name })
  const message = `${$translate.instant("ui.career.profiles.saves.deletePrompt")}\n\n${$translate.instant("ui.career.deleteCannotUndo")}`
  const confirmed = await openConfirmation(title, message)
  if (!confirmed) return

  isDeleting.value = true
  try {
    await store.removeSaveFolder(resolvedProfileId.value, save.name)
    if (matchesName(save.name)) {
      saveName.value = ""
      nameError.value = null
    }
    await loadSaveFolders()
  } finally {
    isDeleting.value = false
  }
}

async function onSave() {
  if (!canSave.value) return
  isSaving.value = true
  try {
    await store.saveCurrentAs(saveName.value.trim())
  } finally {
    isSaving.value = false
  }
  await refreshExitTargetThenGo()
}

function onInputFocus() {
  try { lua.setCEFTyping(true) } catch (_) {}
}
function onInputBlur() {
  try { lua.setCEFTyping(false) } catch (_) {}
  nameError.value = getSaveNameError(saveName.value)
}

onBeforeMount(() => {
  lua.career_career.isActive().then(active => {
    isCareerActive.value = !!active
  })
  lua.simTimeAuthority.pushPauseRequest("profiles")
})

onMounted(async () => {
  if (isSaveMode.value) {
    await resolveSaveModeProfile()
  } else {
    resolvedProfileId.value = props.profileId || ""
    profileDisplayName.value = props.profileId || ""
  }
  await loadSaveFolders()
})

onBeforeUnmount(() => {
  lua.simTimeAuthority.popPauseRequest("profiles")
})
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
  max-width: calc-ui-rem(56);
  margin: 0 auto;
  padding: 2.75em 1.5em;
}

.saves-panel--busy {
  opacity: 0.85;
  pointer-events: none;
}

.saves-toolbar {
  display: flex;
  align-items: center;
  gap: 0.75em;
  margin-bottom: 0.6em;
  position: relative;
  z-index: 2;
}

.saves-name-wrap {
  flex: 1 1 auto;
  max-width: none;
}

.pt-input {
  width: 100%;
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  padding: 0.45em 0.75em;
  color: #fff;
  font-size: 0.9em;
  font-family: inherit;
  outline: none;

  &::placeholder { color: rgba(255, 255, 255, 0.35); }
  &:focus { border-color: rgba(148, 163, 184, 0.5); }
}

.saves-action-btn {
  flex-shrink: 0;
  background: rgba(37, 99, 235, 0.85);
  border: 1px solid rgba(96, 165, 250, 0.55);
  border-radius: 8px;
  color: #fff;
  font-weight: 700;
  font-size: 0.85em;
  padding: 0.45em 1em;
  cursor: pointer;

  &:hover:not(:disabled) { background: rgba(37, 99, 235, 1); }
  &:disabled { opacity: 0.45; cursor: default; }
}

.saves-error {
  color: #fca5a5;
  font-size: 0.8em;
  margin: 0 0 0.75em;
}

.saves-list-shell {
  position: relative;
  z-index: 1;
  border-radius: 12px;
  background: rgba(11, 15, 25, 0.72);
  border: 1px solid rgba(71, 85, 105, 0.35);
  overflow: hidden;
  max-height: min(60vh, 34em);
  display: flex;
  flex-direction: column;
}

.saves-state {
  padding: 2em 1.25em;
  text-align: center;
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.9em;
}

.saves-list {
  overflow: auto;
  display: flex;
  flex-direction: column;
  gap: 0.35em;
  padding: 0.6em;
}

.save-row {
  display: grid;
  grid-template-columns: 1fr auto auto;
  gap: 0.85em;
  align-items: center;
  width: 100%;
  text-align: left;
  background: rgba(5, 8, 15, 0.55);
  border: 1px solid rgba(71, 85, 105, 0.4);
  border-radius: 10px;
  color: #fff;
  padding: 0.75em 0.9em;
  cursor: pointer;
  font: inherit;

  &:hover:not(:disabled) {
    border-color: rgba(148, 163, 184, 0.55);
    background: rgba(15, 23, 42, 0.85);
  }

  &:disabled {
    opacity: 0.5;
    cursor: default;
  }

  &.save-row--selected {
    border-color: rgba(96, 165, 250, 0.7);
    box-shadow: inset 0 0 0 1px rgba(96, 165, 250, 0.25);
  }

  &.save-row--current .save-row-name {
    color: #93c5fd;
  }

  &.save-row--bad {
    opacity: 0.65;
  }
}

.save-row-name {
  font-weight: 800;
  font-size: 1.05em;
  display: flex;
  align-items: center;
  gap: 0.5em;
}

.save-row-chip {
  font-size: 0.65em;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  padding: 0.15em 0.45em;
  border-radius: 999px;
  background: rgba(37, 99, 235, 0.35);
  border: 1px solid rgba(96, 165, 250, 0.45);
}

.save-row-sub {
  margin-top: 0.2em;
  font-size: 0.78em;
  color: rgba(255, 255, 255, 0.55);
}

.save-row-side {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 0.2em;
  font-size: 0.85em;
  white-space: nowrap;
}

.save-row-date {
  color: rgba(255, 255, 255, 0.45);
  font-size: 0.85em;
}

.save-row-actions {
  display: flex;
  gap: 0.4em;
}

.save-icon-btn {
  background: rgba(5, 8, 15, 0.7);
  border: 1px solid rgba(71, 85, 105, 0.5);
  border-radius: 8px;
  color: #fff;
  font-size: 0.75em;
  font-weight: 700;
  padding: 0.35em 0.65em;
  cursor: pointer;

  &:hover:not(:disabled) { border-color: rgba(148, 163, 184, 0.6); }
  &:disabled { opacity: 0.4; cursor: default; }

  &.save-icon-btn--danger:hover:not(:disabled) {
    border-color: rgba(248, 113, 113, 0.7);
    color: #fecaca;
  }
}
</style>
