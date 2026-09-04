import { icons } from '@/common/components/base'

export default {
  id: 'rentals',
  name: 'Rentals',
  icon: icons.doorFrontCoins,
  iconTile: 'rentals.png',
  route: '/career/phone-rentals',
  color: '#3b82f6',
  iconColor: '#ffffff',
  category: 'Property',
  storeTagline: 'Rental income',
  storeDescription: 'Manage rental properties, tenants, and payouts from one place.',
  defaultPage: 0,
  defaultPosition: 10,
  notifications: [
    {
      key: 'rentals.rentDue',
      label: 'Rent Due',
      default: true,
      description: 'Missed rent · late warnings',
      order: 0,
    },
    {
      key: 'rentals.eviction',
      label: 'Eviction',
      default: true,
      description: 'Evicted · deposit forfeited',
      order: 1,
    },
    {
      key: 'rentals.leaseSigned',
      label: 'Lease Signed',
      default: true,
      description: 'New lease started',
      order: 2,
    },
    {
      key: 'rentals.leaseComplete',
      label: 'Lease Complete',
      default: true,
      description: 'Lease ended · deposit returned',
      order: 3,
    },
    {
      key: 'rentals.leaseTerminated',
      label: 'Lease Terminated',
      default: true,
      description: 'Early exit · penalty',
      order: 4,
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
