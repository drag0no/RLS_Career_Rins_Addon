<template>
  <PhoneWrapper app-name="App notifications">
    <div class="phone-notification-settings" :style="accentStyle">
      <div class="settings-card">
        <button
          type="button"
          class="notif-row"
          :class="{ on: isBannerEnabled, muted: isDndActive }"
          @click="toggleBannerNotifications"
        >
          <span class="notif-copy">
            <span class="notif-label">Banner notifications</span>
            <span class="notif-desc">Show alerts while the phone is open.</span>
          </span>
          <span class="notif-switch" :class="{ on: isBannerEnabled }">
            <span class="notif-knob"></span>
          </span>
        </button>

        <div class="setting-surface notif-pref-block">
          <div class="notif-pref-header">
            <span class="notif-label">Alert duration</span>
            <span class="notif-pref-value">{{ bannerDisplayLabel }}s</span>
          </div>
          <p class="notif-desc">How long banner alerts stay on screen.</p>
          <div class="career-scrollbar-slider-wrap">
            <input
              type="range"
              v-model.number="bannerDisplaySlider"
              class="career-scrollbar-slider"
              :min="NOTIFICATION_DISPLAY_MIN"
              :max="NOTIFICATION_DISPLAY_MAX"
              step="1"
              aria-label="Banner alert duration"
              @change="applyBannerDisplaySeconds"
            />
            <div class="career-scrollbar-slider-labels">
              <span>{{ NOTIFICATION_DISPLAY_MIN }}s</span>
              <span>{{ NOTIFICATION_DISPLAY_MAX }}s</span>
            </div>
          </div>
        </div>

        <div v-if="!notificationGroups.length" class="setting-surface notif-empty">
          No apps with notifications installed.
        </div>

        <button
          v-for="group in singleChannelGroups"
          :key="group.appId"
          type="button"
          class="notif-row"
          :class="{ on: isChannelEnabled(group.channels[0]) }"
          @click="toggleChannel(group.channels[0])"
        >
          <span class="notif-copy">
            <span class="notif-label">{{ group.appName }}</span>
            <span v-if="group.channels[0].description" class="notif-desc">{{ group.channels[0].description }}</span>
          </span>
          <span class="notif-switch" :class="{ on: isChannelEnabled(group.channels[0]) }">
            <span class="notif-knob"></span>
          </span>
        </button>

        <template v-if="hasFreContracts || multiChannelGroups.length">
          <div class="notif-section-header">Detailed alerts</div>
          <PhoneFreNotificationFilter v-if="hasFreContracts" />
          <details
            v-for="group in multiChannelGroups"
            :key="group.appId"
            class="settings-dropdown notif-app-dropdown"
          >
            <summary class="dropdown-summary notif-app-summary">
              <div class="summary-copy notif-app-summary-copy">
                <span class="notif-group-dot" :style="{ backgroundColor: group.appColor }"></span>
                <span class="dropdown-title">{{ group.appName }}</span>
              </div>
              <span class="dropdown-meta">{{ groupEnabledCount(group) }}/{{ group.channels.length }}</span>
            </summary>
            <div class="dropdown-content notif-app-dropdown-content">
              <button
                v-for="channel in group.channels"
                :key="channel.key"
                type="button"
                class="notif-row notif-row--child"
                :class="{ on: isChannelEnabled(channel) }"
                @click="toggleChannel(channel)"
              >
                <span class="notif-copy">
                  <span class="notif-label">{{ channel.label }}</span>
                  <span v-if="channel.description" class="notif-desc">{{ channel.description }}</span>
                </span>
                <span class="notif-switch" :class="{ on: isChannelEnabled(channel) }">
                  <span class="notif-knob"></span>
                </span>
              </button>
            </div>
          </details>
        </template>
      </div>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed } from 'vue'
import PhoneWrapper from './PhoneWrapper.vue'
import PhoneFreNotificationFilter from '../components/phone/PhoneFreNotificationFilter.vue'
import {
  useNotificationAccentStyle,
  usePhoneNotificationSettings,
} from '../composables/usePhoneNotificationSettings'
import { clampNotificationDisplaySeconds } from '../composables/usePhoneSettings'

const accentStyle = useNotificationAccentStyle()

const {
  NOTIFICATION_DISPLAY_MIN,
  NOTIFICATION_DISPLAY_MAX,
  notificationGroups,
  bannerDisplaySlider,
  isDndActive,
  isBannerEnabled,
  isChannelEnabled,
  toggleChannel,
  toggleBannerNotifications,
  applyBannerDisplaySeconds,
  useNotificationSettingsLifecycle,
} = usePhoneNotificationSettings()

useNotificationSettingsLifecycle()

const bannerDisplayLabel = computed(() =>
  clampNotificationDisplaySeconds(bannerDisplaySlider.value)
)

const hasFreContracts = computed(() =>
  notificationGroups.value.some(g => g.appId === 'fre-contracts')
)

const singleChannelGroups = computed(() =>
  notificationGroups.value.filter(g => g.channels.length === 1 && g.appId !== 'fre-contracts')
)

const multiChannelGroups = computed(() =>
  notificationGroups.value.filter(g => g.channels.length > 1)
)

function groupEnabledCount(group) {
  return group.channels.filter(ch => isChannelEnabled(ch)).length
}
</script>

<style scoped lang="scss">
@use '../styles/phone-notification-settings' as *;
</style>
