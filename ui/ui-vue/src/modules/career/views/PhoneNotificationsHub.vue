<template>
  <PhoneWrapper app-name="Notifications">
    <div class="phone-notification-settings" :style="accentStyle">
      <div class="settings-card">
        <button type="button" class="settings-link-row" @click="goTo('phone-notification-app-settings')">
          <span class="dropdown-title">App notifications</span>
          <div class="summary-meta-wrap">
            <span class="dropdown-meta">{{ appNotificationsSummaryMeta }}</span>
            <LaunchIcon />
          </div>
        </button>

        <button type="button" class="settings-link-row" @click="goTo('phone-notification-lock-screen')">
          <span class="dropdown-title">Lock screen notifications</span>
          <div class="summary-meta-wrap">
            <span class="dropdown-meta">{{ lockScreenSummaryMeta }}</span>
            <LaunchIcon />
          </div>
        </button>

        <button type="button" class="settings-link-row" @click="goTo('phone-notification-dnd')">
          <span class="dropdown-title">Do not disturb</span>
          <div class="summary-meta-wrap">
            <span class="dropdown-meta">{{ dndSummaryMeta }}</span>
            <LaunchIcon />
          </div>
        </button>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { lua } from '@/bridge'
import PhoneWrapper from './PhoneWrapper.vue'
import LaunchIcon from '../components/phone/PhoneSettingsLaunchIcon.vue'
import {
  useNotificationAccentStyle,
  usePhoneNotificationSettings,
} from '../composables/usePhoneNotificationSettings'

const accentStyle = useNotificationAccentStyle()

const {
  appNotificationsSummaryMeta,
  lockScreenSummaryMeta,
  dndSummaryMeta,
  useNotificationSettingsLifecycle,
} = usePhoneNotificationSettings()

useNotificationSettingsLifecycle()

function goTo(name) {
  lua.extensions.ui_router.navigate(name)
}
</script>

<style scoped lang="scss">
@use '../styles/phone-notification-settings' as *;
</style>
