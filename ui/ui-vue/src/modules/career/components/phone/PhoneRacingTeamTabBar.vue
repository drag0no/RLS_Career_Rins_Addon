<template>
  <nav class="phone-app-tab-bar" aria-label="Racing Team sections">
    <template v-for="(tab, index) in tabs" :key="tab.id">
      <span v-if="index > 0" class="phone-app-tab-bar__divider" aria-hidden="true" />
      <button
        type="button"
        class="phone-app-tab-bar__btn"
        :class="{ 'phone-app-tab-bar__btn--active': activeTab === tab.id }"
        data-focusable
        @click="$emit('select', tab.id)"
        @mousedown.stop
      >
        {{ tab.label }}
      </button>
    </template>
  </nav>
</template>

<script setup>
defineProps({
  activeTab: {
    type: String,
    required: true
  },
  tabs: {
    type: Array,
    required: true,
    validator: (value) => {
      if (!Array.isArray(value)) return false
      return value.every(
        (item) => item && typeof item.id === "string" && typeof item.label === "string"
      )
    }
  }
})

defineEmits(["select"])
</script>

<style scoped lang="scss">
.phone-app-tab-bar {
  display: flex;
  align-items: stretch;
}

.phone-app-tab-bar__divider {
  width: 1px;
  flex-shrink: 0;
  align-self: stretch;
  margin: 0.15em 0;
  background: rgba(245, 73, 0, 0.4);
}

.phone-app-tab-bar__btn {
  flex: 1;
  margin: 0;
  padding: 0.45em 0.2em;
  border: none;
  border-radius: 0;
  background: transparent;
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.68em;
  font-weight: 700;
  line-height: 1.2;
  cursor: pointer;
  transition: color 0.15s;

  &:hover:not(.phone-app-tab-bar__btn--active) {
    color: rgba(255, 255, 255, 0.82);
  }

  &--active {
    color: #f54900;
  }
}
</style>
