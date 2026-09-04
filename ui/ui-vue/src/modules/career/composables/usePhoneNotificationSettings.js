import { computed, ref, onMounted, onUnmounted, onActivated } from 'vue'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import {
  NOTIFICATION_DISPLAY_MIN,
  NOTIFICATION_DISPLAY_MAX,
  DND_DURATION_OPTIONS,
  clampNotificationDisplaySeconds,
  isDoNotDisturbActive,
  resolveDoNotDisturbUntil,
  getUnixNowSeconds,
  usePhoneSettings,
} from './usePhoneSettings'
import { usePhoneNotifications } from '../utils/phoneNotificationRegistry'

export function useNotificationAccentStyle() {
  const { phoneSettings } = usePhoneSettings()

  function hexToRgba(hex, alpha) {
    const normalized = String(hex || '').replace('#', '')
    if (normalized.length !== 6) return `rgba(21, 9, 251, ${alpha})`
    const r = Number.parseInt(normalized.slice(0, 2), 16)
    const g = Number.parseInt(normalized.slice(2, 4), 16)
    const b = Number.parseInt(normalized.slice(4, 6), 16)
    return `rgba(${r}, ${g}, ${b}, ${alpha})`
  }

  return computed(() => ({
    '--accent-color': phoneSettings.backgroundColor,
    '--accent-faint': hexToRgba(phoneSettings.backgroundColor, 0.12),
    '--accent-soft': hexToRgba(phoneSettings.backgroundColor, 0.22),
    '--accent-strong': hexToRgba(phoneSettings.backgroundColor, 0.34),
    '--accent-border': hexToRgba(phoneSettings.backgroundColor, 0.66),
  }))
}

export function usePhoneNotificationSettings() {
  const {
    phoneSettings,
    setPhoneSettings,
    getPhoneSettingsSnapshot,
    replacePhoneSettings,
  } = usePhoneSettings()

  const { notificationGroups, refreshNotifications } = usePhoneNotifications()
  const events = useEvents()

  const layoutInstalledAppIds = ref(null)
  let saveTimer = null
  let dndExpiryTimer = null

  function snapDisplay(v) {
    return clampNotificationDisplaySeconds(v)
  }

  const lockDisplaySlider = ref(snapDisplay(phoneSettings.lockScreenDisplaySeconds))
  const bannerDisplaySlider = ref(snapDisplay(phoneSettings.bannerDisplaySeconds))

  const isDndActive = computed(() => isDoNotDisturbActive(phoneSettings))

  const isLockScreenEnabled = computed(() => phoneSettings.lockScreenNotificationsEnabled !== false)

  const isBannerEnabled = computed(() => phoneSettings.bannerNotificationsEnabled !== false)

  const lockContentMode = computed(() =>
    phoneSettings.lockScreenContentMode === 'hide' ? 'hide' : 'show'
  )

  const visibleChannels = computed(() => notificationGroups.value.flatMap(g => g.channels))

  const totalNotificationCount = computed(() => visibleChannels.value.length)

  const activeNotificationCount = computed(() =>
    visibleChannels.value.filter(ch => isChannelEnabled(ch)).length
  )

  const notificationSummaryMeta = computed(() => {
    if (isDndActive.value) return 'Do not disturb'
    const parts = []
    if (totalNotificationCount.value) {
      parts.push(`${activeNotificationCount.value}/${totalNotificationCount.value}`)
    }
    if (!isLockScreenEnabled.value && !isBannerEnabled.value) {
      parts.push('Off')
    } else if (!isLockScreenEnabled.value) {
      parts.push('Banners only')
    } else if (!isBannerEnabled.value) {
      parts.push('Lock only')
    }
    return parts.length ? parts.join(' · ') : 'On'
  })

  const dndDurationLabel = computed(() => {
    const found = DND_DURATION_OPTIONS.find(o => o.value === phoneSettings.doNotDisturbDurationMinutes)
    return found?.label ?? 'Until turned off'
  })

  const lockScreenSummaryMeta = computed(() => {
    if (!isLockScreenEnabled.value) return 'Off'
    const mode = lockContentMode.value === 'hide' ? 'Hidden' : 'Shown'
    return `${mode} · ${snapDisplay(phoneSettings.lockScreenDisplaySeconds)}s`
  })

  const appNotificationsSummaryMeta = computed(() => {
    const count = totalNotificationCount.value
      ? `${activeNotificationCount.value}/${totalNotificationCount.value}`
      : null
    const banner = isBannerEnabled.value ? 'On' : 'Off'
    const duration = `${snapDisplay(phoneSettings.bannerDisplaySeconds)}s`
    return [count, banner, duration].filter(Boolean).join(' · ')
  })

  const dndSummaryMeta = computed(() => {
    if (!isDndActive.value) return 'Off'
    if (phoneSettings.doNotDisturbUntil) {
      const remaining = phoneSettings.doNotDisturbUntil - getUnixNowSeconds()
      if (remaining > 0 && remaining < 86400) {
        const mins = Math.ceil(remaining / 60)
        return mins >= 60 ? `${Math.ceil(mins / 60)}h left` : `${mins}m left`
      }
    }
    return dndDurationLabel.value
  })

  function isChannelEnabled(channel) {
    const current = phoneSettings.notifications || {}
    const value = current[channel.key]
    return value === undefined ? channel.default : value !== false
  }

  async function persistSettings() {
    try {
      await lua.extensions.load('ui_phone_layout')
      await lua.ui_phone_layout?.updateSettings?.(getPhoneSettingsSnapshot())
    } catch (e) {
      console.warn('Failed to save phone notification settings', e)
    }
  }

  function queueSave() {
    if (saveTimer) clearTimeout(saveTimer)
    saveTimer = setTimeout(() => {
      saveTimer = null
      persistSettings()
    }, 180)
  }

  function syncDisplaySliders() {
    lockDisplaySlider.value = snapDisplay(phoneSettings.lockScreenDisplaySeconds)
    bannerDisplaySlider.value = snapDisplay(phoneSettings.bannerDisplaySeconds)
  }

  function clearDndExpiryTimer() {
    if (dndExpiryTimer) {
      window.clearTimeout(dndExpiryTimer)
      dndExpiryTimer = null
    }
  }

  function scheduleDndExpiryCheck() {
    clearDndExpiryTimer()
    if (!phoneSettings.doNotDisturb || !phoneSettings.doNotDisturbUntil) return
    const remainingMs = (phoneSettings.doNotDisturbUntil - getUnixNowSeconds()) * 1000
    if (remainingMs <= 0) {
      expireDoNotDisturb()
      return
    }
    dndExpiryTimer = window.setTimeout(() => {
      dndExpiryTimer = null
      expireDoNotDisturb()
    }, Math.min(remainingMs + 50, 2147483647))
  }

  function expireDoNotDisturb() {
    if (!isDoNotDisturbActive(phoneSettings)) {
      if (phoneSettings.doNotDisturb) {
        setPhoneSettings({ doNotDisturb: false, doNotDisturbUntil: null })
        queueSave()
      }
      clearDndExpiryTimer()
      return
    }
    setPhoneSettings({ doNotDisturb: false, doNotDisturbUntil: null })
    queueSave()
    clearDndExpiryTimer()
  }

  function toggleDoNotDisturb() {
    if (isDndActive.value) {
      setPhoneSettings({ doNotDisturb: false, doNotDisturbUntil: null })
      clearDndExpiryTimer()
    } else {
      const until = resolveDoNotDisturbUntil(phoneSettings.doNotDisturbDurationMinutes)
      setPhoneSettings({ doNotDisturb: true, doNotDisturbUntil: until })
      scheduleDndExpiryCheck()
    }
    queueSave()
  }

  function setDndDurationMinutes(minutes) {
    setPhoneSettings({ doNotDisturbDurationMinutes: minutes })
    if (isDndActive.value) {
      const until = resolveDoNotDisturbUntil(minutes)
      setPhoneSettings({ doNotDisturbUntil: until })
      scheduleDndExpiryCheck()
    }
    queueSave()
  }

  function toggleLockScreenNotifications() {
    setPhoneSettings({ lockScreenNotificationsEnabled: !isLockScreenEnabled.value })
    queueSave()
  }

  function setLockScreenContentMode(mode) {
    setPhoneSettings({ lockScreenContentMode: mode === 'hide' ? 'hide' : 'show' })
    queueSave()
  }

  function toggleBannerNotifications() {
    setPhoneSettings({ bannerNotificationsEnabled: !isBannerEnabled.value })
    queueSave()
  }

  async function applyLockDisplaySeconds() {
    const value = snapDisplay(lockDisplaySlider.value)
    lockDisplaySlider.value = value
    if (phoneSettings.lockScreenDisplaySeconds === value) return
    setPhoneSettings({ lockScreenDisplaySeconds: value })
    await persistSettings()
  }

  async function applyBannerDisplaySeconds() {
    const value = snapDisplay(bannerDisplaySlider.value)
    bannerDisplaySlider.value = value
    if (phoneSettings.bannerDisplaySeconds === value) return
    setPhoneSettings({ bannerDisplaySeconds: value })
    await persistSettings()
  }

  function toggleChannel(channel) {
    const next = { ...(phoneSettings.notifications || {}) }
    next[channel.key] = !isChannelEnabled(channel)
    setPhoneSettings({ notifications: next })
    queueSave()
  }

  function seedNotificationDefaults() {
    const current = phoneSettings.notifications || {}
    let changed = false
    const next = { ...current }
    for (const channel of visibleChannels.value) {
      if (next[channel.key] === undefined) {
        next[channel.key] = channel.default !== false
        changed = true
      }
    }
    if (changed) {
      setPhoneSettings({ notifications: next })
      queueSave()
    }
  }

  function rememberLayoutInstalledIds(data) {
    if (!data || data.installedAppIds == null) return
    layoutInstalledAppIds.value = data.installedAppIds
  }

  async function loadNotificationChannels() {
    try {
      await lua.extensions.load('ui_phone_layout')
      const opts = layoutInstalledAppIds.value != null
        ? { installedAppIds: layoutInstalledAppIds.value }
        : {}
      await refreshNotifications(lua, opts)
      seedNotificationDefaults()
    } catch (e) {
      console.warn('Failed to load phone notification channels', e)
    }
  }

  async function onLayoutData(data) {
    if (data?.settings) {
      replacePhoneSettings(data.settings)
    }
    rememberLayoutInstalledIds(data)
    syncDisplaySliders()
    scheduleDndExpiryCheck()
    await loadNotificationChannels()
  }

  function onPhoneLockNotification() {
    loadNotificationChannels()
  }

  function setupNotificationSettingsListeners() {
    events.on('phoneLayoutData', onLayoutData)
    events.on('PhoneLockNotification', onPhoneLockNotification)
  }

  function teardownNotificationSettingsListeners() {
    events.off('phoneLayoutData', onLayoutData)
    events.off('PhoneLockNotification', onPhoneLockNotification)
    clearDndExpiryTimer()
    if (saveTimer) {
      clearTimeout(saveTimer)
      saveTimer = null
      persistSettings()
    }
  }

  async function initNotificationSettings() {
    try {
      await lua.extensions.load('ui_phone_layout')
      setupNotificationSettingsListeners()
      lua.ui_phone_layout.requestLayout()
    } catch (e) {
      console.warn('Failed to init phone notification settings', e)
    }
    scheduleDndExpiryCheck()
    await loadNotificationChannels()
  }

  function useNotificationSettingsLifecycle() {
    onMounted(() => {
      initNotificationSettings()
    })

    onActivated(() => {
      syncDisplaySliders()
      scheduleDndExpiryCheck()
      loadNotificationChannels()
    })

    onUnmounted(() => {
      teardownNotificationSettingsListeners()
    })
  }

  return {
    NOTIFICATION_DISPLAY_MIN,
    NOTIFICATION_DISPLAY_MAX,
    DND_DURATION_OPTIONS,
    notificationGroups,
    lockDisplaySlider,
    bannerDisplaySlider,
    notificationSummaryMeta,
    lockScreenSummaryMeta,
    appNotificationsSummaryMeta,
    dndSummaryMeta,
    dndDurationLabel,
    isDndActive,
    isLockScreenEnabled,
    isBannerEnabled,
    lockContentMode,
    isChannelEnabled,
    toggleChannel,
    toggleDoNotDisturb,
    setDndDurationMinutes,
    toggleLockScreenNotifications,
    setLockScreenContentMode,
    toggleBannerNotifications,
    applyLockDisplaySeconds,
    applyBannerDisplaySeconds,
    loadNotificationChannels,
    useNotificationSettingsLifecycle,
  }
}
