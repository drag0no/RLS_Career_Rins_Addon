import { defineStore } from "pinia"
import { ref } from "vue"
import { lua, useBridge } from "@/bridge"
import { openScreenOverlay, addPopup, fixedDelayPopup } from "@/services/popup"

import ActivityStart from "@/modules/activitystart/views/ActivityStart.vue"
import Recovery from "@/modules/recovery/views/Recovery.vue"
import RadialFavoriteSelection from "@/modules/radial/views/FavoriteSelection.vue"
import TutorialPopupDialog from "@/modules/career/components/tutorial/TutorialPopupDialog.vue"
import OptionalChallengeSelect from "@/modules/career/components/tutorial/OptionalChallengeSelect.vue"

export const useGameContextStore = defineStore("gameContext", () => {
  const { events } = useBridge()

  const activities = ref([])
  let activityScreen = null
  let recoveryPrompt = null
  let radialFavoriteSelectionPrompt = null
  let deliveryEndScreen = null
  let simpleDelayPopup = null
  let tutorialPopup = null

  const startMission = missionId => {
    const mission = activities.value.find(x => x.id === missionId)

    if (!mission) console.error(`Mission not found ${missionId}. cannot start`)

    const settings = mission.settings,
      userSettings = mission && settings ? settings.reduce((acc, item) => {
        acc[item.key] = item.value
        return acc
      }, {}) : {}
    lua.gameplay_markerInteraction.startMissionById(mission.id, userSettings)
  }

  const closeActivitiesPrompt = () => {
    lua.gameplay_markerInteraction.closeViewDetailPrompt(true)
  }

  function openRecoveryPrompt() {
    recoveryPrompt = addPopup(Recovery).promise
  }

  function openDynamicSlotConfigurator() {
    radialFavoriteSelectionPrompt = addPopup(RadialFavoriteSelection).promise
  }

  function openSimpleDelayPopup(data) {
    simpleDelayPopup = fixedDelayPopup(data.timer, { title: data.heading })
  }

  function getTutorialPopupComponentData(payload = {}) {
    const popupList = Array.isArray(payload.popups) ? payload.popups : []
    const popupComponents = popupList.map(item => item?.vueComponent).filter(name => typeof name === "string")
    const directComponent = typeof payload.vueComponent === "string" ? payload.vueComponent : null
    const componentName = popupComponents[0] || directComponent
    const isSingleComponentPayload = popupComponents.length > 0 && popupComponents.every(name => name === componentName)

    return { popupComponents, componentName, isSingleComponentPayload }
  }

  function resolveTutorialPopupComponent(payload = {}) {
    const { popupComponents, componentName, isSingleComponentPayload } = getTutorialPopupComponentData(payload)
    if ((isSingleComponentPayload || !popupComponents.length) && componentName === "OptionalChallengeSelect") {
      return OptionalChallengeSelect
    }
    return TutorialPopupDialog
  }

  function shouldShowTutorialContinueButtons(payload = {}) {
    if (payload.showContinueButtons === false) return false
    const { componentName, isSingleComponentPayload } = getTutorialPopupComponentData(payload)
    const isGearboxPopup = componentName === "GearboxSelect" || componentName === "ShiftModeSelect"
    return !(isSingleComponentPayload && isGearboxPopup)
  }

  function openTutorialPopup(data = {}) {
    if (tutorialPopup) {
      tutorialPopup.promise.close(true)
      tutorialPopup = null
    }
    const payload = data && typeof data === "object" ? data : {}
    const popupComponent = resolveTutorialPopupComponent(payload)
    const popup = addPopup(popupComponent, {
      ...payload,
      showContinueButtons: shouldShowTutorialContinueButtons(payload),
    })
    tutorialPopup = popup
    popup.promise.finally(() => {
      if (tutorialPopup === popup) tutorialPopup = null
    })
  }

  const performActivityAction = activityActionIndex => lua.ui_missionInfo.performActivityAction(activityActionIndex)

  events.on("ActivityAcceptUpdate", onActivityAcceptUpdate)
  events.on("ActivityAcceptClose", closeActivitiesPopup)

  events.on("MenuOpenModule", closeActivitiesPopup)

  events.on("ChangeState", closeActivitiesPopup)

  events.on("OpenRecoveryPrompt", openRecoveryPrompt)

  events.on("OpenDynamicSlotConfigurator", openDynamicSlotConfigurator)

  events.on("OpenSimpleDelayPopup", openSimpleDelayPopup)
  events.on("OpenTutorialPopup", openTutorialPopup)
  events.on("CloseTutorialPopup", closeTutorialPopup)

  const deliveryRewardData = ref(false)
  function showDeliveryEndScreen(data) {
    deliveryRewardData.value = data
    window.bngVue.gotoGameState("career.cargoDeliveryReward")
  }
  events.on("OpenDeliveryEndScreen", showDeliveryEndScreen)

  async function getPlayState() {
    try {
      const current = await lua.extensions.ui_router.getCurrent()
      return !!(current && current.resolved.name === "play")
    } catch {
      return false
    }
  }

  // Avoid reopening a stale activity overlay when route checks resolve out of order.
  let updateVersion = 0
  async function onActivityAcceptUpdate(data) {
    const version = ++updateVersion
    closeActivitiesPopup()

    const isPlay = await getPlayState()
    if (version !== updateVersion || !isPlay) return

    activities.value = data

    if (activities.value?.length > 0) {
      activityScreen = openScreenOverlay(ActivityStart)
    }
  }

  function closeActivitiesPopup() {
    if (!activityScreen) return

    activityScreen.close(true)
    activityScreen = null
  }

  function closeRecoveryPrompt() {
    if (!recoveryPrompt) return

    recoveryPrompt.close(true)
    recoveryPrompt = null
  }

  function closeRadialFavoriteSelectionPrompt() {
    if (!radialFavoriteSelectionPrompt) return

    radialFavoriteSelectionPrompt.close(true)
    radialFavoriteSelectionPrompt = null
  }

  function closeSimpleDelayPopup() {
    if (!simpleDelayPopup) return
    simpleDelayPopup.progress.done()
    simpleDelayPopup = null
  }

  function closeTutorialPopup() {
    if (!tutorialPopup) return
    tutorialPopup.promise.close(true)
    tutorialPopup = null
  }

  function closeDeliveryEndScreen() {
    if (!deliveryEndScreen) return

    deliveryEndScreen.close(true)
    deliveryEndScreen = null
  }

  function dispose() {
    events.off("ActivityAcceptUpdate", onActivityAcceptUpdate)
    events.off("ActivityAcceptClose", closeActivitiesPopup)
    events.off("OpenTutorialPopup", openTutorialPopup)
    events.off("CloseTutorialPopup", closeTutorialPopup)
  }

  return {
    activities,
    closeActivitiesPrompt,
    closeDeliveryEndScreen,
    closeRecoveryPrompt,
    closeRadialFavoriteSelectionPrompt,
    closeSimpleDelayPopup,
    closeTutorialPopup,
    deliveryRewardData,
    dispose,
    performActivityAction,
    startMission,
  }
})
