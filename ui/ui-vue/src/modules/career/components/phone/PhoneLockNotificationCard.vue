<template>
  <article
    ref="cardRef"
    class="phone-lock-card"
    :class="`phone-lock-card--${item.kind}`"
    :style="swipeStyle"
    role="button"
    tabindex="0"
    @click="onCardClick"
    @keydown.enter.prevent="onCardClick"
    @keydown.space.prevent="onCardClick"
    @pointerdown="onPointerDown"
    @pointermove="onPointerMove"
    @pointerup="onPointerEnd"
    @pointercancel="onPointerCancel"
  >
    <template v-if="item.kind === 'racing'">
      <div class="phone-lock-card__body phone-lock-card__racing">
        <template v-if="item.presentationSimple">
          <span class="phone-lock-card__headline">{{ item.source }}</span>
        </template>
        <template v-else>
          <span class="phone-lock-card__headline">{{ item.title || 'Race Ready' }}</span>
          <span v-if="item.subline" class="phone-lock-card__sub">{{ item.subline }}</span>
          <span class="phone-lock-card__app">{{ item.source }}</span>
        </template>
      </div>
    </template>
    <template v-else-if="item.presentationSimple">
      <div class="phone-lock-card__body">
        <span class="phone-lock-card__message phone-lock-card__message--simple">{{ item.source }}</span>
      </div>
    </template>
    <template v-else>
      <div class="phone-lock-card__body">
        <span class="phone-lock-card__source">{{ item.source }}</span>
        <span v-if="item.message" class="phone-lock-card__message">{{ item.message }}</span>
        <span v-if="item.meta" class="phone-lock-card__meta">{{ item.meta }}</span>
      </div>
    </template>
  </article>
</template>

<script setup>
import { ref } from 'vue'
import { useHorizontalSwipeDismiss } from '../../composables/useHorizontalSwipeDismiss'

const props = defineProps({
  item: { type: Object, required: true },
})

const emit = defineEmits(['dismiss', 'open'])

const cardRef = ref(null)

const {
  swipeStyle,
  suppressClick,
  onPointerDown,
  onPointerMove,
  onPointerEnd,
  onPointerCancel,
} = useHorizontalSwipeDismiss({
  getElementEl: () => cardRef.value,
  onDismiss: () => emit('dismiss', props.item.id),
})

function onCardClick() {
  if (suppressClick.value) {
    suppressClick.value = false
    return
  }
  emit('open', props.item)
}
</script>

<style scoped lang="scss">
@use '../../styles/phone-notification-text' as phone-notif;

.phone-lock-card {
  pointer-events: auto;
  display: flex;
  align-items: stretch;
  gap: 10px;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  padding: 10px 12px;
  border-radius: 14px;
  background: rgba(15, 17, 22, 0.82);
  backdrop-filter: blur(14px);
  border: 1px solid rgba(255, 255, 255, 0.12);
  color: #f7f1e8;
  box-shadow: 0 6px 16px rgba(0, 0, 0, 0.35);
  font-size: 0.78em;
  line-height: 1.25;
  cursor: pointer;
  text-align: left;

  &:focus-visible {
    outline: 2px solid rgba(125, 211, 252, 0.55);
    outline-offset: 1px;
  }
}

.phone-lock-card__body {
  @include phone-notif.phone-notif-body;
}

.phone-lock-card__source {
  @include phone-notif.phone-notif-source-line;
  font-weight: 800;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: #ffc978;
  font-size: 0.72em;
}

.phone-lock-card__message {
  @include phone-notif.phone-notif-clamped-text(3);
  color: rgba(247, 241, 232, 0.94);
  font-weight: 600;
}

.phone-lock-card__message--simple {
  font-size: 1em;
  font-weight: 700;
  letter-spacing: 0.01em;
  -webkit-line-clamp: 2;
}

.phone-lock-card__meta {
  @include phone-notif.phone-notif-clamped-text(2);
  font-weight: 600;
  font-size: 0.85em;
  line-height: 1.25;
  color: rgba(247, 241, 232, 0.6);
}

.phone-lock-card--success .phone-lock-card__source,
.phone-lock-card--rep .phone-lock-card__source {
  color: #69d48f;
}

.phone-lock-card--warning .phone-lock-card__source,
.phone-lock-card--invite .phone-lock-card__source {
  color: #ffc978;
}

.phone-lock-card--dakar .phone-lock-card__source {
  color: #e0703a;
}

.phone-lock-card--error .phone-lock-card__source {
  color: #ff8a8a;
}

.phone-lock-card--racing {
  align-items: stretch;
}

.phone-lock-card__racing {
  gap: 2px;
}

.phone-lock-card__headline {
  @include phone-notif.phone-notif-clamped-text(2);
  font-weight: 800;
  font-size: 0.95em;
  letter-spacing: 0.03em;
  color: #ffc978;
}

.phone-lock-card__sub {
  @include phone-notif.phone-notif-clamped-text(2);
  font-size: 0.88em;
  font-weight: 600;
  color: rgba(247, 241, 232, 0.94);
}

.phone-lock-card__app {
  @include phone-notif.phone-notif-source-line;
  font-size: 0.68em;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: rgba(247, 241, 232, 0.5);
}
</style>
