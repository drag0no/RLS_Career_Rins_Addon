<template>
  <Teleport to="body">
    <div v-if="visible" class="rls-load-overlay" aria-busy="true" aria-live="polite">
      <div class="rls-load-overlay__panel">
        <div class="rls-load-overlay__spinner" />
        <p v-if="message" class="rls-load-overlay__msg">{{ message }}</p>
      </div>
    </div>
  </Teleport>
</template>

<script setup>
import { ref, onMounted, onBeforeUnmount } from "vue"
import { useBridge } from "@/bridge"

const bridge = useBridge()
const visible = ref(false)
const message = ref("")

const normalizePayload = raw => {
  if (!raw || typeof raw !== "object") return {}
  if (Array.isArray(raw) && raw.length > 0 && raw[0] && typeof raw[0] === "object" && !Array.isArray(raw[0])) {
    return raw[0]
  }
  return raw
}

const onLoading = (...args) => {
  const d = normalizePayload(args.length > 0 ? args[0] : null)
  if (d.visible === true) {
    visible.value = true
    message.value = typeof d.message === "string" ? d.message : ""
  } else {
    visible.value = false
    message.value = ""
  }
}

onMounted(() => {
  bridge.events.on("rlsCareerLoadingOverlay", onLoading)
  if (typeof window !== "undefined" && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.on("rlsCareerLoadingOverlay", onLoading)
  }
})

onBeforeUnmount(() => {
  bridge.events.off("rlsCareerLoadingOverlay", onLoading)
  if (typeof window !== "undefined" && window.vueEventBus && window.vueEventBus !== bridge.events) {
    window.vueEventBus.off("rlsCareerLoadingOverlay", onLoading)
  }
})
</script>

<style scoped lang="scss">
.rls-load-overlay {
  position: fixed;
  inset: 0;
  z-index: 14000;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(0, 0, 0, 0.45);
  pointer-events: auto;
}

.rls-load-overlay__panel {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.75rem;
  padding: 1.25rem 1.5rem;
  border-radius: 10px;
  background: rgba(20, 22, 28, 0.92);
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.35);
}

.rls-load-overlay__spinner {
  width: 36px;
  height: 36px;
  border: 3px solid rgba(255, 255, 255, 0.15);
  border-top-color: rgba(255, 255, 255, 0.85);
  border-radius: 50%;
  animation: rls-load-spin 0.75s linear infinite;
}

.rls-load-overlay__msg {
  margin: 0;
  font-size: 0.9rem;
  color: rgba(255, 255, 255, 0.88);
  text-align: center;
  max-width: 18rem;
}

@keyframes rls-load-spin {
  to {
    transform: rotate(360deg);
  }
}
</style>
