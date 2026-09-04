import { onMounted, onUnmounted } from 'vue'
import { lua } from '@/bridge'

export function usePhoneMarketplaceUi() {
  onMounted(() => {
    lua.career_modules_marketplace.setPhoneMarketplaceUiOpen(true)
  })
  onUnmounted(() => {
    lua.career_modules_marketplace.setPhoneMarketplaceUiOpen(false)
  })
}
