<template>
  <PhoneWrapper app-name="App Store">
    <div class="phone-app-store" :style="accentStyle">
      <div class="store-header">
        <h2 class="store-title">Apps</h2>
        <p class="store-subtitle">Browse and install apps onto your home screen.</p>
      </div>

      <div v-if="loading" class="store-state">Loading apps...</div>
      <div v-else-if="!storeApps.length" class="store-state">No apps available right now.</div>

      <div v-else class="store-list">
        <button
          v-for="app in storeApps"
          :key="app.id"
          type="button"
          class="store-row"
          @click="openAppDetail(app)"
        >
          <div class="store-row-icon" :style="{ backgroundColor: app.iconImage ? 'transparent' : app.color }">
            <img
              v-if="app.iconImage"
              class="store-row-icon-image"
              :src="app.iconImage"
              :alt="app.name"
              draggable="false"
            />
            <BngIcon v-else :type="app.icon" :style="{ color: app.iconColor }" />
          </div>
          <div class="store-row-copy">
            <span class="store-row-name">{{ app.name }}</span>
            <span v-if="rowSubtitle(app)" class="store-row-category">{{ rowSubtitle(app) }}</span>
          </div>
          <span
            v-if="isInstalled(app.id)"
            class="store-row-badge store-row-badge--installed"
          >
            Installed
          </span>
          <span v-else class="store-row-badge">GET</span>
          <span class="store-row-chevron" aria-hidden="true">›</span>
        </button>
      </div>

      <PhoneAppStoreDetailSheet
        :app="selectedApp"
        :is-installed="selectedApp ? isInstalled(selectedApp.id) : false"
        :is-installing="selectedApp ? installingId === selectedApp.id : false"
        @close="closeAppDetail"
        @install="installApp(selectedApp)"
        @uninstall="uninstallApp(selectedApp)"
        @open="openInstalledApp(selectedApp)"
      />
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { lua } from '@/bridge'
import { useEvents } from '@/services/events'
import { BngIcon } from '@/common/components/base'
import PhoneWrapper from './PhoneWrapper.vue'
import PhoneAppStoreDetailSheet from '../components/phone/PhoneAppStoreDetailSheet.vue'
import { usePhoneApps } from '../utils/phoneAppRegistry'
import { navigatePhoneRoute } from '../utils/phoneNavigation'
import { usePhoneSettings } from '../composables/usePhoneSettings'
import {
  collectInstalledFromLayout,
  installAppOnLayout,
  isAppInstalled,
  LAYOUT_VERSION,
  uninstallAppFromLayout,
} from '../utils/phoneLayoutUtils'

const INSTALL_DELAY_MS = 1400

const router = useRouter()
const events = useEvents()
const { phoneSettings, getPhoneSettingsSnapshot } = usePhoneSettings()
const { refreshCatalogApps, getStoreApps, APPS_PER_PAGE } = usePhoneApps()

const loading = ref(true)
const storeApps = ref([])
const layoutData = ref(null)
const installedIds = ref([])
const installingId = ref(null)
const selectedApp = ref(null)

function hexToRgba(hex, alpha) {
  const normalized = String(hex || '').replace('#', '')
  if (normalized.length !== 6) return `rgba(21, 9, 251, ${alpha})`
  const r = Number.parseInt(normalized.slice(0, 2), 16)
  const g = Number.parseInt(normalized.slice(2, 4), 16)
  const b = Number.parseInt(normalized.slice(4, 6), 16)
  return `rgba(${r}, ${g}, ${b}, ${alpha})`
}

const accentStyle = computed(() => ({
  '--accent-color': phoneSettings.backgroundColor,
  '--accent-faint': hexToRgba(phoneSettings.backgroundColor, 0.12),
  '--accent-border': hexToRgba(phoneSettings.backgroundColor, 0.66),
}))

function rowSubtitle(app) {
  return app?.storeTagline || app?.category || ''
}

function syncInstalledFromLayout(data) {
  layoutData.value = data && typeof data === 'object' ? { ...data } : null
  installedIds.value = collectInstalledFromLayout(layoutData.value)
}

function isInstalled(appId) {
  return installedIds.value.includes(appId) || isAppInstalled(layoutData.value, appId)
}

function openAppDetail(app) {
  if (!app?.id) return
  selectedApp.value = app
}

function closeAppDetail() {
  if (installingId.value) return
  selectedApp.value = null
}

function openInstalledApp(app) {
  if (!app?.route) return
  sessionStorage.setItem('phoneVisible', 'true')
  navigatePhoneRoute(router, app.route)
}

async function persistLayout(nextLayout) {
  const payload = {
    ...nextLayout,
    version: LAYOUT_VERSION,
    settings: getPhoneSettingsSnapshot(),
  }
  syncInstalledFromLayout(payload)
  await lua.extensions.load('ui_phone_layout')
  const ok = await lua.ui_phone_layout?.updateLayout?.(payload)
  if (ok === false) throw new Error('Layout save failed')
}

function installApp(app) {
  if (!app?.id || installingId.value || isInstalled(app.id)) return
  installingId.value = app.id
  window.setTimeout(async () => {
    try {
      const base = layoutData.value ? { ...layoutData.value } : {}
      const next = installAppOnLayout(base, app.id, APPS_PER_PAGE)
      await persistLayout(next)
    } catch (err) {
      console.warn('[PhoneAppStore] install failed', err)
    } finally {
      installingId.value = null
    }
  }, INSTALL_DELAY_MS)
}

async function uninstallApp(app) {
  if (!app?.id || installingId.value || !isInstalled(app.id)) return
  try {
    const base = layoutData.value ? { ...layoutData.value } : {}
    const next = uninstallAppFromLayout(base, app.id, APPS_PER_PAGE)
    await persistLayout(next)
  } catch (err) {
    console.warn('[PhoneAppStore] uninstall failed', err)
  }
}

function onLayoutData(data) {
  syncInstalledFromLayout(data)
}

onMounted(async () => {
  try {
    await refreshCatalogApps(lua)
    storeApps.value = getStoreApps()
    await lua.extensions.load('ui_phone_layout')
    events.on('phoneLayoutData', onLayoutData)
    lua.ui_phone_layout.requestLayout()
  } catch (err) {
    console.warn('[PhoneAppStore] init failed', err)
  } finally {
    loading.value = false
  }
})

onUnmounted(() => {
  events.off('phoneLayoutData', onLayoutData)
})
</script>

<style scoped lang="scss">
:deep(.phone-content) {
  background:
    radial-gradient(circle at top, rgba(63, 63, 70, 0.28), rgba(0, 0, 0, 0) 32%),
    linear-gradient(180deg, #09090b 0%, #020617 100%);
}

.phone-app-store {
  position: relative;
  height: 100%;
  display: flex;
  flex-direction: column;
  padding: 52px 14px 16px;
  overflow: hidden;
}

.store-header {
  flex: 0 0 auto;
  margin-bottom: 12px;
}

.store-title {
  margin: 0;
  font-size: 19px;
  font-weight: 800;
  color: #f8fafc;
  line-height: 1.15;
}

.store-subtitle {
  margin: 4px 0 0;
  font-size: 11px;
  line-height: 1.35;
  color: rgba(226, 232, 240, 0.68);
}

.store-state {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  color: rgba(226, 232, 240, 0.72);
}

.store-list {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding-right: 2px;

  &::-webkit-scrollbar {
    width: 7px;
  }

  &::-webkit-scrollbar-track {
    background: transparent;
  }

  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.16);
    border-radius: 999px;
  }

  &::-webkit-scrollbar-thumb:hover {
    background: rgba(255, 255, 255, 0.28);
  }
}

.store-row {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  padding: 10px 12px;
  border-radius: 14px;
  border: 1px solid rgba(255, 255, 255, 0.1);
  background: rgba(8, 8, 8, 0.58);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.04);
  color: inherit;
  text-align: left;
  cursor: pointer;
  transition: border-color 0.14s ease, background 0.14s ease, transform 0.12s ease;

  &:hover {
    border-color: var(--accent-border, rgba(255, 255, 255, 0.22));
    background: rgba(15, 15, 18, 0.72);
  }

  &:active {
    transform: scale(0.995);
  }
}

.store-row-icon {
  width: 40px;
  height: 40px;
  border-radius: 11px;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  overflow: hidden;
  position: relative;
  font-size: 1.35em;
}

.store-row-icon-image {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.store-row-copy {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.store-row-name {
  font-size: 13px;
  font-weight: 700;
  color: #f8fafc;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.store-row-category {
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.02em;
  color: rgba(203, 213, 225, 0.58);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.store-row-badge {
  flex-shrink: 0;
  font-size: 10px;
  font-weight: 800;
  letter-spacing: 0.04em;
  color: #f97316;
  padding: 4px 8px;
  border-radius: 999px;
  background: rgba(249, 115, 22, 0.12);
}

.store-row-badge--installed {
  color: rgba(203, 213, 225, 0.72);
  letter-spacing: 0.02em;
  font-weight: 700;
}

.store-row-chevron {
  flex-shrink: 0;
  font-size: 18px;
  line-height: 1;
  color: rgba(203, 213, 225, 0.45);
  margin-left: -2px;
}
</style>
