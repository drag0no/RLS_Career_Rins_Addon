<template>
  <PhoneWrapper app-name="Do not disturb">
    <div class="phone-notification-settings" :style="accentStyle">
      <div class="settings-card">
        <button
          type="button"
          class="notif-row"
          :class="{ on: isDndActive }"
          @click="toggleDoNotDisturb"
        >
          <span class="notif-copy">
            <span class="notif-label">Do not disturb</span>
            <span class="notif-desc">Silence all phone notifications until turned off or the timer ends.</span>
          </span>
          <span class="notif-switch" :class="{ on: isDndActive }">
            <span class="notif-knob"></span>
          </span>
        </button>

        <div class="setting-surface notif-pref-block">
          <span class="notif-section-label">For how long</span>
          <div class="notif-radio-group">
            <button
              v-for="option in DND_DURATION_OPTIONS"
              :key="option.value"
              type="button"
              class="notif-radio-row"
              :class="{ selected: phoneSettings.doNotDisturbDurationMinutes === option.value }"
              @click="setDndDurationMinutes(option.value)"
            >
              <span
                class="notif-radio-circle"
                :class="{ on: phoneSettings.doNotDisturbDurationMinutes === option.value }"
              ></span>
              <span class="notif-radio-label">{{ option.label }}</span>
            </button>
          </div>
          <p class="notif-desc">Applies when you turn on Do not disturb. Alerts already showing will finish.</p>
        </div>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import PhoneWrapper from './PhoneWrapper.vue'
import { usePhoneSettings } from '../composables/usePhoneSettings'
import {
  useNotificationAccentStyle,
  usePhoneNotificationSettings,
} from '../composables/usePhoneNotificationSettings'

const { phoneSettings } = usePhoneSettings()
const accentStyle = useNotificationAccentStyle()

const {
  DND_DURATION_OPTIONS,
  isDndActive,
  toggleDoNotDisturb,
  setDndDurationMinutes,
  useNotificationSettingsLifecycle,
} = usePhoneNotificationSettings()

useNotificationSettingsLifecycle()
</script>

<style scoped lang="scss">
@use '../styles/phone-notification-settings' as *;
</style>
