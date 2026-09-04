import { ref, computed, readonly } from 'vue'
import { lua } from '@/bridge'

/** @typedef {'next' | 'tap' | 'done'} PhoneTutorialAdvance} */

/**
 * @typedef {Object} PhoneTutorialStep
 * @property {string} id
 * @property {string} [appId]
 * @property {'dock' | 'homescreen'} [target]
 * @property {PhoneTutorialAdvance} advance
 * @property {string} [label]
 * @property {string} title
 * @property {string} body
 * @property {string} [cta]
 * @property {boolean} [showBinding]
 * @property {string} [route]
 */

/** @type {PhoneTutorialStep[]} */
export const PHONE_TUTORIAL_STEPS = [
  {
    id: 'app-store',
    appId: 'app-store',
    target: 'dock',
    advance: 'next',
    label: 'App Store',
    title: 'Download apps',
    body: 'The App Store is where you grab new apps for jobs, finance, vehicles, and more. Everything you install shows up on your home screen.',
  },
  {
    id: 'skills',
    appId: 'skills',
    target: 'dock',
    advance: 'next',
    label: 'Skills',
    title: 'Track your progress',
    body: 'Skills unlock jobs, features, and opportunities as you play. Check here to see what you have access to and what to work toward next.',
  },
  {
    id: 'market-watch',
    appId: 'market-watch',
    target: 'dock',
    advance: 'next',
    label: 'Market Watch',
    title: 'Follow the economy',
    body: 'Market Watch tracks prices, demand, and trends across the career economy. Use it to spot good deals and plan your next move.',
  },
  {
    id: 'settings',
    appId: 'settings',
    target: 'dock',
    advance: 'next',
    label: 'Settings',
    title: 'Make it yours',
    body: 'Adjust phone size, wallpaper, notifications, and more. Tune the phone so it fits how you play.',
  },
  {
    id: 'guide',
    appId: 'guide',
    target: 'homescreen',
    advance: 'tap',
    label: 'Wiki',
    title: 'Your in-game manual',
    body: 'The Wiki explains career features, systems, and what is new. Open it whenever you need a refresher.',
    cta: 'Tap Wiki to continue',
  },
  {
    id: 'guide-open',
    advance: 'done',
    route: 'phone-guide',
    title: 'Come back anytime',
    body: 'Browse the Wiki whenever you are unsure how something works. New topics get added as the career grows.',
    showBinding: true,
  },
]

const stepIndex = ref(/** @type {number | null} */ (null))
const phoneBindingLabel = ref('your phone key')
const dockReadyTick = ref(0)
const phoneVisibleTick = ref(0)
const phoneSessionVisible = ref(false)

function readPhoneSessionVisible() {
  if (typeof sessionStorage === 'undefined') return false
  return sessionStorage.getItem('phoneVisible') === 'true'
}

export function usePhoneTutorial() {
  const isActive = computed(() => stepIndex.value !== null)

  const currentStep = computed(() => {
    if (stepIndex.value === null) return null
    return PHONE_TUTORIAL_STEPS[stepIndex.value] ?? null
  })

  const tutorialHighlightAppId = computed(() => currentStep.value?.appId ?? null)
  const tutorialBlockLaunches = computed(() => isActive.value && phoneSessionVisible.value)

  const tutorialTargetSelector = computed(() => {
    const step = currentStep.value
    if (!step?.appId || !step.target) return null
    if (step.target === 'dock') return `[data-tutorial-id="dock-${step.appId}"]`
    if (step.target === 'homescreen') return `[data-tutorial-id="homescreen-${step.appId}"]`
    return null
  })

  function resetTutorialState() {
    stepIndex.value = null
  }

  function startTutorial(payload) {
    stepIndex.value = 0
    const binding = payload?.binding
    if (binding && binding !== 'Not bound') {
      phoneBindingLabel.value = binding
    } else {
      phoneBindingLabel.value = 'your phone key'
    }
  }

  function advanceNext() {
    if (stepIndex.value === null) return
    const step = PHONE_TUTORIAL_STEPS[stepIndex.value]
    if (!step || step.advance !== 'next') return
    if (stepIndex.value + 1 < PHONE_TUTORIAL_STEPS.length) {
      stepIndex.value += 1
    }
  }

  function advanceAfterGuideTap() {
    if (stepIndex.value === null) return
    const step = PHONE_TUTORIAL_STEPS[stepIndex.value]
    if (step?.id !== 'guide') return
    stepIndex.value += 1
  }

  /** Backup if homescreen launch hook did not run before the guide route mounted. */
  function tryAdvanceOnGuideRoute() {
    if (stepIndex.value === null) return false
    const step = PHONE_TUTORIAL_STEPS[stepIndex.value]
    if (step?.id === 'guide') {
      stepIndex.value += 1
      return true
    }
    return step?.id === 'guide-open'
  }

  async function finishTutorial() {
    stepIndex.value = null
    try {
      await lua.career_modules_guide?.markPhoneTutorialComplete?.()
    } catch (_) {
      // ignore bridge errors in non-career contexts
    }
  }

  function isLaunchAllowed(appId) {
    if (stepIndex.value === null) return true
    const step = currentStep.value
    if (step?.advance === 'tap' && step.appId === appId) return true
    return false
  }

  function shouldBlockPhoneBack() {
    return isActive.value && phoneSessionVisible.value
  }

  function shouldBlockPhoneClose() {
    return isActive.value && phoneSessionVisible.value
  }

  function notifyDockReady() {
    dockReadyTick.value++
  }

  function notifyPhoneVisible() {
    phoneSessionVisible.value = readPhoneSessionVisible()
    phoneVisibleTick.value++
  }

  function shouldShowTutorialOverlay(routeName) {
    if (stepIndex.value === null) return false
    const step = PHONE_TUTORIAL_STEPS[stepIndex.value]
    if (!step) return false
    if (step.advance === 'done') {
      return routeName === step.route
    }
    return routeName === 'phone-main'
  }

  return {
    stepIndex: readonly(stepIndex),
    currentStep,
    isActive,
    phoneBindingLabel: readonly(phoneBindingLabel),
    dockReadyTick: readonly(dockReadyTick),
    phoneVisibleTick: readonly(phoneVisibleTick),
    tutorialHighlightAppId,
    tutorialBlockLaunches,
    tutorialTargetSelector,
    PHONE_TUTORIAL_STEPS,
    resetTutorialState,
    startTutorial,
    advanceNext,
    advanceAfterGuideTap,
    tryAdvanceOnGuideRoute,
    finishTutorial,
    notifyDockReady,
    notifyPhoneVisible,
    isLaunchAllowed,
    shouldBlockPhoneBack,
    shouldBlockPhoneClose,
    shouldShowTutorialOverlay,
  }
}
