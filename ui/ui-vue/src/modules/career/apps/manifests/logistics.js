import { icons } from '@/common/components/base'

export default {
  id: 'logistics',
  name: 'Logistics',
  icon: icons.cogs,
  iconTile: 'logistics.png',
  route: '/career/phone-logistics',
  color: '#2b6cb0',
  iconColor: '#ffffff',
  category: 'Jobs',
  storeTagline: 'Deliveries and routes',
  storeDescription: 'Take logistics contracts, plan runs, and track active delivery work from your phone.',
  defaultPage: 0,
  defaultPosition: 11,
  notifications: [
    {
      key: 'logistics.cargoAbandoned',
      label: 'Cargo Abandoned',
      default: true,
      description: 'Abandoned cargo · penalty',
      order: 0,
    },
  ],
  unlockCondition: async (luaBridge) => {
    try {
      await luaBridge.extensions.load('ui_phone_layout')
      const fromLayout = await luaBridge.ui_phone_layout.getCareerActive()
      if (fromLayout) return true
    } catch { }
    try {
      return await luaBridge.career_career.isActive()
    } catch {
      return false
    }
  },
}
