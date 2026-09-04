<template>
  <Transition name="store-sheet">
    <div
      v-if="app"
      class="store-sheet-root"
      role="dialog"
      aria-modal="true"
      :aria-label="`${app.name} details`"
      @click.self="onBackdropClick"
    >
      <article class="store-detail-card">
        <button type="button" class="store-detail-close" aria-label="Close" @click="$emit('close')">
          <span aria-hidden="true">×</span>
        </button>

        <header class="store-detail-header">
          <div class="store-detail-icon" :style="{ backgroundColor: app.iconImage ? 'transparent' : app.color }">
            <img
              v-if="app.iconImage"
              class="store-detail-icon-image"
              :src="app.iconImage"
              :alt="app.name"
              draggable="false"
            />
            <BngIcon v-else :type="app.icon" :style="{ color: app.iconColor }" />
          </div>
          <div class="store-detail-heading">
            <h3 class="store-detail-name">{{ app.name }}</h3>
            <p v-if="app.category" class="store-detail-category">{{ app.category }}</p>
          </div>
        </header>

        <div class="store-detail-body">
          <p class="store-detail-description">{{ app.storeDescription }}</p>
          <p v-if="!app.isUsageUnlocked" class="store-detail-locked">
            {{ app.lockedMessage }}
          </p>
        </div>

        <footer class="store-detail-footer">
          <button
            v-if="isInstalling"
            type="button"
            class="store-pill store-pill--busy store-pill--wide"
            disabled
          >
            Installing...
          </button>
          <template v-else-if="isInstalled">
            <button
              v-if="app.route"
              type="button"
              class="store-pill store-pill--open store-pill--wide store-pill--compact"
              @click="$emit('open')"
            >
              Open
            </button>
            <button
              type="button"
              class="store-pill store-pill--uninstall store-pill--wide store-pill--compact"
              @click="$emit('uninstall')"
            >
              Uninstall
            </button>
          </template>
          <button
            v-else
            type="button"
            class="store-pill store-pill--install store-pill--wide"
            @click="$emit('install')"
          >
            Install
          </button>
        </footer>
      </article>
    </div>
  </Transition>
</template>

<script setup>
import { BngIcon } from '@/common/components/base'

const props = defineProps({
  app: { type: Object, default: null },
  isInstalled: { type: Boolean, default: false },
  isInstalling: { type: Boolean, default: false },
})

const emit = defineEmits(['close', 'install', 'uninstall', 'open'])

function onBackdropClick() {
  if (props.isInstalling) return
  emit('close')
}
</script>

<style scoped lang="scss">
.store-sheet-root {
  position: absolute;
  inset: 0;
  z-index: 30;
  display: flex;
  align-items: flex-end;
  justify-content: center;
  padding: 12px 10px 16px;
  background: rgba(0, 0, 0, 0.58);
  backdrop-filter: blur(2px);
}

.store-detail-card {
  position: relative;
  width: 100%;
  max-height: min(78%, 420px);
  display: flex;
  flex-direction: column;
  border-radius: 18px 18px 16px 16px;
  border: 1px solid rgba(255, 255, 255, 0.12);
  background:
    linear-gradient(180deg, rgba(24, 24, 27, 0.98) 0%, rgba(9, 9, 11, 0.98) 100%);
  box-shadow:
    0 18px 40px rgba(0, 0, 0, 0.45),
    inset 0 1px 0 rgba(255, 255, 255, 0.06);
  overflow: hidden;
}

.store-detail-close {
  position: absolute;
  top: 10px;
  right: 10px;
  z-index: 2;
  width: 28px;
  height: 28px;
  border: none;
  border-radius: 999px;
  background: rgba(255, 255, 255, 0.08);
  color: rgba(248, 250, 252, 0.9);
  font-size: 20px;
  line-height: 1;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: background 0.12s ease;

  &:hover {
    background: rgba(255, 255, 255, 0.14);
  }
}

.store-detail-header {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 16px 16px 10px;
  flex-shrink: 0;
}

.store-detail-icon {
  width: 64px;
  height: 64px;
  border-radius: 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  overflow: hidden;
  font-size: 2em;
  box-shadow: 0 8px 20px rgba(0, 0, 0, 0.28);
}

.store-detail-icon-image {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}

.store-detail-heading {
  min-width: 0;
  padding-right: 24px;
}

.store-detail-name {
  margin: 0;
  font-size: 16px;
  font-weight: 800;
  color: #f8fafc;
  line-height: 1.15;
}

.store-detail-category {
  margin: 4px 0 0;
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: rgba(203, 213, 225, 0.58);
}

.store-detail-body {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding: 0 16px 12px;

  &::-webkit-scrollbar {
    width: 7px;
  }

  &::-webkit-scrollbar-track {
    background: rgba(0, 0, 0, 0.2);
    border-radius: 4px;
  }

  &::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 4px;
  }

  &::-webkit-scrollbar-thumb:hover {
    background: rgba(255, 255, 255, 0.15);
  }
}

.store-detail-description {
  margin: 0;
  font-size: 12px;
  line-height: 1.45;
  color: rgba(226, 232, 240, 0.78);
}

.store-detail-locked {
  margin: 10px 0 0;
  padding: 8px 10px;
  border-radius: 10px;
  border: 1px solid rgba(251, 191, 36, 0.28);
  background: rgba(120, 53, 15, 0.22);
  font-size: 11px;
  line-height: 1.4;
  color: rgba(253, 230, 138, 0.95);
}

.store-detail-footer {
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 12px 16px 16px;
  border-top: 1px solid rgba(255, 255, 255, 0.06);
}

/* Match App Store list GET / Installed colors — larger than list badges for detail CTAs */
.store-pill {
  border: none;
  border-radius: 999px;
  padding: 11px 16px;
  min-height: 42px;
  min-width: 88px;
  font-size: 14px;
  font-weight: 800;
  letter-spacing: 0.04em;
  cursor: pointer;
  transition: transform 0.12s ease, opacity 0.12s ease, background 0.12s ease;

  &:active:not(:disabled) {
    transform: scale(0.98);
  }

  &:disabled {
    cursor: default;
  }
}

.store-pill--wide {
  width: 100%;
}

.store-pill--compact {
  min-height: 44px;
  padding: 11px 16px;
}

.store-pill--install,
.store-pill--open {
  color: #f97316;
  background: rgba(249, 115, 22, 0.14);
  border: 1px solid rgba(249, 115, 22, 0.28);
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.05);
  text-shadow: 0 1px 1px rgba(0, 0, 0, 0.28);

  &:hover {
    background: rgba(249, 115, 22, 0.2);
  }
}

.store-pill--open,
.store-pill--uninstall {
  font-size: 18px;
}

.store-pill--uninstall {
  color: rgba(203, 213, 225, 0.78);
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.1);
  font-weight: 700;
  letter-spacing: 0.02em;
  box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.04);

  &:hover {
    color: #fca5a5;
    border-color: rgba(248, 113, 113, 0.35);
    background: rgba(248, 113, 113, 0.1);
  }
}

.store-pill--busy {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.08);
  color: rgba(203, 213, 225, 0.72);
  font-weight: 700;
  letter-spacing: 0.02em;
}

.store-sheet-enter-active,
.store-sheet-leave-active {
  transition: opacity 0.2s ease;

  .store-detail-card {
    transition: transform 0.24s cubic-bezier(0.22, 1, 0.36, 1);
  }
}

.store-sheet-enter-from,
.store-sheet-leave-to {
  opacity: 0;

  .store-detail-card {
    transform: translateY(18px);
  }
}
</style>
