<template>
  <div
    class="innerTuningCard"
    :class="{
      'with-background': withBackground,
    }"
    v-bng-blur="withBackground"
    v-bng-on-ui-nav:action_4="toggleTuningApps"
    v-bng-ui-nav-label:action_4="showTuningApps ? $t('ui.vehicleconfig.tuning') : ''"
  >
    <TuningDebugAppsPanel v-if="showTuningApps" ref="tuningAppsPanelRef" />

    <div v-if="tuningStore.buckets" class="tuning-form" v-bng-ui-nav-scroll>
      <div v-if="extraFeatures.length > 0" class="extra-features">
        <BngButton
          v-bng-disabled="!extraFeatures.find(f => f.mirrorsEnabled)"
          @click="toMirrors"
          accent="secondary"
        >
          {{ $t("ui.mirrors.name") }}
        </BngButton>
      </div>
      <div class="tuning-category" v-for="category in tuningStore.buckets" :key="category.name">
        <h2 class="category-heading"><span class="category-name">{{ category.name }}</span></h2>
        <div class="tuning-subcategory" v-for="subCategory in category.items" :key="subCategory.name">
          <h3 class="subcategory-heading" v-if="subCategory.name !== 'Other'"><span class="subcategory-name">{{ subCategory.name }}</span></h3>
          <BngRow
            v-for="varData in subCategory.items"
            :key="category.name + subCategory.name + varData.name"
            class="input-container variable-box"
            vertical
            :tooltip="varData.description"
          >
            <template #label>{{ varData.title }}</template>
            <BngSlider
              ref="inputs"
              :min="varData.minDis"
              :max="varData.maxDis"
              :step="varData.stepDis"
              :unit="varData.unit"
              :class="{ 'property-slider': true }"
              with-input
              with-reset
              :orig-value="tuningStore.tuningVariables[varData.name].default"
              v-model="tuningStore.tuningVariables[varData.name].valDis"
              @valueChanged="onChange(varData.name)"
            />
          </BngRow>
        </div>
      </div>
      <div v-if="bottomSpacer" class="tuning-bottom-spacer" aria-hidden="true" />
    </div>

    <div v-if="showControls" class="tuning-static">
      <LiveWheelData v-if="awdShow" class="awd-app" />
      <div class="tuning-controls-row">
        <BngSwitch v-model="awdShow">{{ $t("ui.garage.tune.advWheel") }}</BngSwitch>
        <BngSwitch v-model="autoApply" @valueChanged="applySettingChanged">{{ $t("ui.garage.liveUpdates") }}</BngSwitch>

        <div class="buttons">
          <BngButton
            show-hold
            :icon="icons.undo"
            :accent="ACCENTS.custom_old"
            class="reset-button"
            v-bng-on-ui-nav:ok.asMouse.focusRequired
            v-bng-click="{ holdCallback: resetVarsToLoadedConfig, holdDelay: 1000, repeatInterval: 0 }"
            v-bng-tooltip="$t('ui.common.reset')"
          />

          <BngButton :disabled="autoApply || !isChanged" @click="apply">
            {{ $t("ui.common.apply") }}
          </BngButton>

          <BngButton v-if="closeButton" @click="close" :accent="ACCENTS.attention">
            <BngBinding ui-event="back" deviceMask="xinput" />
            {{ $t("ui.common.close") }}
          </BngButton>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch, onBeforeMount, onUnmounted, nextTick } from "vue"
import { BngRow, BngButton, ACCENTS, BngSwitch, BngSlider, BngBinding, icons } from "@/common/components/base"
import { vBngBlur, vBngTooltip, vBngDisabled, vBngClick, vBngOnUiNav, vBngUiNavLabel, vBngUiNavScroll } from "@/common/directives"
import TuningDebugAppsPanel from "./TuningDebugAppsPanel.vue"
import LiveWheelData from "./LiveWheelData.vue"
import { useTuningStore } from "../stores/tuningStore"
import { getUINavServiceInstance, UI_EVENT_GROUPS } from "@/services/uiNav"
import { debounce } from "@/utils/rateLimit"
import { useBridge } from "@/bridge"
import { useSettingsAsync } from "@/services/settings.js"

const { lua } = useBridge()

const tuningStore = useTuningStore()

const props = defineProps({
  withBackground: Boolean,
  buttonTarget: {
    type: Object,
  },
  closeButton: Boolean, // used in career mode
  showControls: {
    type: Boolean,
    default: true,
  },
  bottomSpacer: Boolean,
  autoApply: {
    type: Boolean,
    default: null,
  },
  blockContextNav: {
    type: Boolean,
    default: true,
  },
  mirrorsRoute: {
    type: String,
    default: null,
  },
  showTuningApps: Boolean,
})

const tuningAppsPanelRef = ref(null)
const awdShow = ref(false)

function toggleTuningApps() {
  if (!props.showTuningApps) return true
  tuningAppsPanelRef.value?.toggle?.()
  return false
}

function apply() {
  tuningStore.apply()
}
function close() {
  tuningStore.close()
}

const mirrorsShown = ref(true)
const mirrorsEnabled = ref(false)

let mirrorsRoute = props.mirrorsRoute || "menu.vehicleconfig.tuning.mirrors"

async function toMirrors() {
  await lua.extensions.ui_router.navigate(mirrorsRoute, null, null)
}

const inputs = ref([])

const isChanged = computed(() => inputs.value.some(ipt => ipt.dirty))
const changedCount = computed(() => inputs.value.filter(ipt => ipt.dirty).length)

const localAutoApply = ref(false)
const autoApply = computed({
  get: () => typeof props.autoApply === "boolean" ? props.autoApply : localAutoApply.value,
  set: val => {
    if (typeof props.autoApply !== "boolean") localAutoApply.value = val
    applySettingChanged(val)
  },
})
const applyDebounce = debounce(apply, 1000)

function onChange(varName) {
  //TODO is there a way to check here if the input is dirty or not?
  tuningStore.tuningVarChanged(varName)
  autoApply.value && applyDebounce()
}

const applySettingChanged = val => localStorage.setItem("applyTuningChangesAutomatically", JSON.stringify(val))

watch(
  () => tuningStore.buckets,
  () => nextTick(() => {
    for (let ipt of inputs.value) ipt.markClean()
  })
)

async function resetVarsToLoadedConfig() {
  tuningStore.resetTuningData()
  await tuningStore.requestInitialData()
  await nextTick()
  for (let ipt of inputs.value) ipt.markClean()
}

onBeforeMount(async () => {
  const optAutoApply = localStorage.getItem("applyTuningChangesAutomatically")
  if (optAutoApply) {
    try {
      localAutoApply.value = !!JSON.parse(optAutoApply)
    } catch (err) { }
  }

  if (!props.mirrorsRoute && await lua.extensions.gameplay_garageMode.isActive()) {
    mirrorsRoute = "menu.vehicleconfig.tuning.mirrors.in-garage"
  }

  if (await lua.career_career.isActive()) {
    mirrorsShown.value = false
  } else {
    mirrorsEnabled.value = (await useSettingsAsync()).values.GraphicDynMirrorsEnabled
  }

  await tuningStore.init()
  await tuningStore.requestInitialData()
  getUINavServiceInstance().setFilteredEvents(UI_EVENT_GROUPS.focusMoveScalar)
})

const extraFeatures = computed(() => {
  const features = []
  if (mirrorsEnabled.value) {
    features.push({ mirrorsEnabled: true })
  }
  return features
})

onUnmounted(async () => {
  await tuningStore.notifyOnMenuClosed()
  tuningStore.close()
  tuningStore.$dispose()
  getUINavServiceInstance().clearFilteredEvents()
})

defineExpose({
  apply,
  close,
  changedCount,
  isChanged,
})
</script>

<style scoped lang="scss">
.innerTuningCard {
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  min-height: 0;
  max-height: 100%;
  overflow: hidden;

  > .tuning-static {
    flex: 0 0 auto;
    padding: 0.5em 1em;
    border-top: solid 2px var(--bng-orange);
    display: flex;
    flex-direction: column;
    gap: 0.25em;
    min-height: 0;
    min-width: 0;
    // Leave room for the tuning form's vertical padding when wheel data needs
    // the rest of the available height.
    max-height: calc(100% - 1.5rem);
    box-sizing: border-box;
    overflow: hidden;

    .awd-app {
      flex: 1 1 auto;
      min-height: 0;
      width: 100%;
      padding: 0;
      overflow: auto;
    }

    .tuning-controls-row {
      display: flex;
      flex-direction: row;
      flex-wrap: wrap;
      align-items: center;
      gap: 0.25em;
      width: 100%;
      flex: 0 0 auto;
    }

    .buttons {
      text-align: right;
      display: flex;
      justify-content: flex-end;
      gap: 0.125rem;
      height: 2.8em;
      flex: 1 0 auto;
      margin-left: auto;

      .reset-button {
        --bng-button-custom-hold-offset: 0px;
      }
    }
  }

  &.with-background {
    background-color: rgba(0, 0, 0, 0.6);
  }

  color: white;

  > .tuning-form {
    flex: 1 1 auto;
    min-height: 0;
    width: 100%;
    padding: 0.5rem 0 1rem;
    text-align: center;
    overflow-x: hidden;
    overflow-y: auto;
    will-change: scroll-position;

    .extra-features {
      display: flex;
      flex-direction: row;
      flex-wrap: wrap;
      justify-content: center;
      gap: 0.5rem;
    }

    .tuning-bottom-spacer {
      height: 3rem;
      flex: 0 0 auto;
    }

    .tuning-category {
      display: flex;
      flex-direction: column;
      flex-wrap: nowrap;
      padding: 0.5em 0 0.75em 0;

      .category-heading {
        margin: 0 0 0 0;
        font-size: 1.25em;
        font-weight: 600;
        font-style: italic;
        text-align: left;
        margin: 0;
        padding: 0.5em 0.5em 0.5em 1rem;
        display: inline-flex;
        align-items: center;
        justify-content: flex-start;
        gap: 0.5em;
        color: var(--bng-orange-100);

        &::after {
          content: "";
          display: inline-block;
          transform: translateY(0.125em);
          height: 1px;
          background: var(--bng-orange-750);
          flex: 1 1 auto;
        }
      }

      .tuning-subcategory {
        display: flex;
        flex-direction: column;
        flex-wrap: nowrap;
        padding: 0 0.5rem 0 1rem;

        .subcategory-heading {
          font-size: 1em;
          font-weight: 600;
          font-style: italic;
          text-align: left;
          margin: 0;
          padding: 0.5em 0 0.5em 0;
          display: inline-flex;
          align-items: center;
          justify-content: flex-start;
          gap: 0.5em;

          &::after {
            content: "";
            display: inline-block;
            transform: translateY(0.125em);
            height: 0.0625em;
            background: repeating-linear-gradient(to right, var(--bng-cool-gray-750), var(--bng-cool-gray-750) 0.25em, transparent 0.251em, transparent 0.45em);
            flex: 1 1 auto;
          }
        }
      }

      .input-container {
        display: flex;
        flex-direction: column;
        flex-wrap: nowrap;
      }
    }
  }

  .variable-title {
    text-align: left;
    font-size: 0.875em;
  }

  .variable-box {
    float: left;
    --input-width: 7em;
    --bng-slider-margin: 0.25em;

    .property-slider {
      --input-height: 2em;
      align-items: center;
    }
  }
}
</style>
