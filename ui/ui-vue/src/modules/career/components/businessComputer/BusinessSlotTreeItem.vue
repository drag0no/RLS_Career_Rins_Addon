<template>
  <div class="tree-item-wrapper">
    <div
      class="slot-row"
      :class="{
        'has-children': hasChildren,
        'is-expanded': isExpanded,
        'has-parts': hasAvailableParts,
        'is-selected': isSelected
      }"
      :style="{ paddingLeft: (0.6 + level * 1.1) + 'em' }"
      @click="handleRowClick"
      data-focusable
    >
      <!-- Left: Expand/Collapse Chevron & Slot Name -->
      <div class="slot-row-left">
        <button
          v-if="hasChildren"
          class="tree-chevron-btn"
          type="button"
          :title="isExpanded ? 'Collapse subcategories' : 'Expand subcategories'"
          @click.stop="toggleExpand"
          data-focusable
        >
          <svg
            class="chevron-icon"
            :class="{ rotated: isExpanded }"
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          >
            <polyline points="9 18 15 12 9 6" />
          </svg>
        </button>
        <div v-else class="tree-chevron-placeholder"></div>

        <span class="slot-name" :title="node.slotNiceName || node.slotName">
          {{ node.slotNiceName || node.slotName }}
        </span>

        <span v-if="hasChildren && !isExpanded" class="children-count-badge" :title="childrenCount + ' subcategories'">
          +{{ childrenCount }}
        </span>
      </div>

      <!-- Right: Installed Part Badge / Customize Button -->
      <div class="slot-row-right">
        <button
          v-if="hasAvailableParts"
          class="part-badge-btn"
          type="button"
          :title="'Select replacement for ' + (node.slotNiceName || node.slotName)"
          @click.stop="selectPart"
          data-focusable
        >
          <span class="part-badge-text">{{ node.partNiceName || '-' }}</span>
          <svg class="badge-chevron-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <polyline points="9 18 15 12 9 6" />
          </svg>
        </button>
        <div v-else class="part-badge-static">
          <span class="part-badge-text">{{ node.partNiceName || '-' }}</span>
        </div>
      </div>
    </div>

    <!-- Recursive children list -->
    <transition name="tree-collapse">
      <div v-if="hasChildren && isExpanded" class="children-container">
        <BusinessSlotTreeItem
          v-for="child in sortedChildren"
          :key="child.id"
          :node="child"
          :level="level + 1"
          :expanded-slots="expandedSlots"
          :selected-slot-id="selectedSlotId"
          @toggle-expand="$emit('toggleExpand', $event)"
          @select-slot="$emit('selectSlot', $event)"
        />
      </div>
    </transition>
  </div>
</template>

<script setup>
import { computed } from "vue"

const props = defineProps({
  node: {
    type: Object,
    required: true
  },
  level: {
    type: Number,
    default: 0
  },
  expandedSlots: {
    type: Object,
    default: () => ({})
  },
  selectedSlotId: {
    type: String,
    default: null
  }
})

const emit = defineEmits(["toggleExpand", "selectSlot"])

const hasChildren = computed(() => {
  return Array.isArray(props.node.children) && props.node.children.length > 0
})

const isExpanded = computed(() => {
  return !!props.expandedSlots[props.node.id]
})

const hasAvailableParts = computed(() => {
  return Array.isArray(props.node.availableParts) && props.node.availableParts.length > 0
})

const isSelected = computed(() => {
  return props.selectedSlotId && (props.selectedSlotId === props.node.id || props.selectedSlotId === props.node.path)
})

const childrenCount = computed(() => {
  if (!hasChildren.value) return 0
  return props.node.children.length
})

const sortedChildren = computed(() => {
  if (!hasChildren.value) return []
  return [...props.node.children].sort((a, b) => {
    const nameA = (a.slotNiceName || a.slotName || "").toLowerCase()
    const nameB = (b.slotNiceName || b.slotName || "").toLowerCase()
    return nameA.localeCompare(nameB)
  })
})

const toggleExpand = () => {
  emit("toggleExpand", props.node.id)
}

const selectPart = () => {
  emit("selectSlot", props.node)
}

const handleRowClick = () => {
  if (hasChildren.value) {
    toggleExpand()
  } else if (hasAvailableParts.value) {
    selectPart()
  }
}
</script>

<style scoped lang="scss">
.tree-item-wrapper {
  display: flex;
  flex-direction: column;
}

.slot-row {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding-top: 0.6em;
  padding-bottom: 0.6em;
  padding-right: 0.8em;
  background: rgba(18, 18, 18, 0.85);
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 0.5em;
  margin-bottom: 0.3em;
  cursor: pointer;
  transition: background 0.15s, border-color 0.15s, transform 0.1s, box-shadow 0.15s;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.25);
  user-select: none;

  &:hover {
    background: rgba(28, 28, 28, 0.95);
    border-color: rgba(245, 73, 0, 0.5);
    transform: translateY(-1px);
    box-shadow: 0 6px 16px rgba(0, 0, 0, 0.35);

    .slot-name {
      color: white;
    }

    .tree-chevron-btn .chevron-icon {
      color: rgba(245, 73, 0, 1);
    }
  }

  &:active {
    transform: translateY(0);
    border-color: rgba(245, 73, 0, 0.75);
  }

  &.is-selected {
    border-color: rgba(245, 73, 0, 0.9);
    background: rgba(35, 22, 16, 0.9);
  }

  &.is-expanded {
    border-color: rgba(255, 255, 255, 0.14);
  }
}

.slot-row-left {
  display: flex;
  align-items: center;
  gap: 0.5em;
  min-width: 0;
  flex: 1;

  .tree-chevron-btn {
    background: transparent;
    border: none;
    cursor: pointer;
    padding: 0.2em;
    display: flex;
    align-items: center;
    justify-content: center;
    color: rgba(255, 255, 255, 0.5);
    transition: color 0.15s;
    flex-shrink: 0;
    border-radius: 0.25em;

    &:hover {
      color: rgba(245, 73, 0, 1);
    }

    .chevron-icon {
      transition: transform 0.2s ease;

      &.rotated {
        transform: rotate(90deg);
        color: rgba(245, 73, 0, 0.9);
      }
    }
  }

  .tree-chevron-placeholder {
    width: 1.25em;
    height: 1.25em;
    flex-shrink: 0;
  }

  .slot-name {
    color: rgba(255, 255, 255, 0.9);
    font-size: 0.875em;
    font-weight: 500;
    text-align: left;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .children-count-badge {
    padding: 0.1em 0.45em;
    background: rgba(255, 255, 255, 0.08);
    border-radius: 0.75em;
    color: rgba(255, 255, 255, 0.5);
    font-size: 0.75em;
    font-weight: 600;
    flex-shrink: 0;
  }
}

.slot-row-right {
  display: flex;
  align-items: center;
  gap: 0.5em;
  flex-shrink: 0;
  margin-left: 0.5em;

  .part-badge-btn {
    display: flex;
    align-items: center;
    gap: 0.4em;
    padding: 0.25em 0.65em;
    background: rgba(26, 26, 26, 1);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 0.3em;
    color: rgba(255, 255, 255, 0.85);
    font-size: 0.85em;
    cursor: pointer;
    transition: all 0.15s ease;
    max-width: 15em;

    .part-badge-text {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      max-width: 13em;
    }

    .badge-chevron-icon {
      color: rgba(255, 255, 255, 0.35);
      flex-shrink: 0;
      transition: color 0.15s, transform 0.15s;
    }

    &:hover {
      background: rgba(245, 73, 0, 0.15);
      border-color: rgba(245, 73, 0, 0.6);
      color: white;

      .badge-chevron-icon {
        color: rgba(245, 73, 0, 1);
        transform: translateX(1px);
      }
    }
  }

  .part-badge-static {
    display: flex;
    align-items: center;
    padding: 0.25em 0.65em;
    background: rgba(26, 26, 26, 0.5);
    border: 1px solid rgba(255, 255, 255, 0.05);
    border-radius: 0.3em;
    color: rgba(255, 255, 255, 0.4);
    font-size: 0.85em;
    max-width: 15em;

    .part-badge-text {
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      max-width: 13em;
    }
  }
}

.children-container {
  display: flex;
  flex-direction: column;
  position: relative;
  margin-left: 0.5em;
  border-left: 1px solid rgba(255, 255, 255, 0.06);
  padding-left: 0.25em;
}

.tree-collapse-enter-active,
.tree-collapse-leave-active {
  transition: opacity 0.15s ease, transform 0.15s ease;
}

.tree-collapse-enter-from,
.tree-collapse-leave-to {
  opacity: 0;
  transform: translateY(-4px);
}
</style>

