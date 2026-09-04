<template>
  <Teleport to="body">
    <transition name="rt-promo-fade">
      <div v-if="open" class="rt-promo-overlay" role="dialog" aria-modal="true" @click.stop>
        <RacingTeamPromoPanel
          :title="title"
          :body="body"
          :image-url="imageUrl"
          @click.stop
        >
          <button
            v-if="kind === 'purchase'"
            type="button"
            class="btn btn-primary"
            data-focusable
            @click="onPurchaseContinue"
          >
            {{ continueLabel }}
          </button>
          <button
            v-else-if="kind === 'league2_welcome'"
            type="button"
            class="btn btn-primary"
            data-focusable
            @click="onLeague2WelcomeContinue"
          >
            {{ continueLabel }}
          </button>
          <button
            v-else-if="kind === 'race_unlock'"
            type="button"
            class="btn btn-primary"
            data-focusable
            @click="close"
          >
            {{ continueLabel }}
          </button>
          <button
            v-else-if="kind === 'career_finale'"
            type="button"
            class="btn btn-primary"
            data-focusable
            @click="onCareerFinaleContinue"
          >
            {{ continueLabel }}
          </button>
        </RacingTeamPromoPanel>
      </div>
    </transition>
  </Teleport>
</template>

<script setup>
import { ref, computed, onMounted, onBeforeUnmount } from "vue"
import { useBridge, lua } from "@/bridge"
import RacingTeamPromoPanel from "./RacingTeamPromoPanel.vue"

const bridge = useBridge()
const open = ref(false)
const payload = ref(null)

const kind = computed(() => (payload.value && payload.value.kind) || "")
const title = computed(() => (payload.value && payload.value.title) || "")
const body = computed(() => (payload.value && payload.value.body) || "")
const imageUrl = computed(() => (payload.value && payload.value.imageUrl) || "")
const continueLabel = computed(() => (payload.value && payload.value.continueLabel) || "Continue")

const businessIdStr = computed(() => {
  const b = payload.value && payload.value.businessId
  return b != null && b !== "" ? String(b) : null
})

const close = () => {
  open.value = false
  payload.value = null
}

const normalizeMilestonePayload = raw => {
  if (!raw || typeof raw !== "object") return null
  if (Array.isArray(raw) && raw.length > 0) {
    const first = raw[0]
    if (first && typeof first === "object" && !Array.isArray(first)) {
      return first
    }
    return null
  }
  return raw
}

const onMilestone = (...args) => {
  const raw = args.length > 0 ? args[0] : null
  const data = normalizeMilestonePayload(raw)
  if (!data || typeof data !== "object") return
  payload.value = data
  open.value = true
}

const onPurchaseContinue = async () => {
  const bid = businessIdStr.value
  if (!bid) {
    close()
    return
  }
  try {
    await lua.career_modules_business_businessComputer.racingTeamMilestonePurchaseContinue(bid)
  } catch (e) {
    /* ignore */
  }
  close()
}

const onCareerFinaleContinue = async () => {
  const bid = businessIdStr.value
  if (!bid) {
    close()
    return
  }
  try {
    await lua.career_modules_business_businessComputer.racingTeamMilestoneCareerFinaleContinue(bid)
  } catch (e) {
    /* ignore */
  }
  close()
}

const onLeague2WelcomeContinue = async () => {
  const bid = businessIdStr.value
  if (!bid) {
    close()
    return
  }
  try {
    await lua.career_modules_business_businessComputer.racingTeamMilestoneLeague2WelcomeContinue(bid)
  } catch (e) {
    /* ignore */
  }
  close()
}

onMounted(() => {
  bridge.events.on("RacingTeamMilestoneSplashShow", onMilestone)
  if (typeof window !== "undefined" && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.on("RacingTeamMilestoneSplashShow", onMilestone)
  }
})

onBeforeUnmount(() => {
  bridge.events.off("RacingTeamMilestoneSplashShow", onMilestone)
  if (typeof window !== "undefined" && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.off("RacingTeamMilestoneSplashShow", onMilestone)
  }
})
</script>
