import { icons } from '@/common/components/base'

export default {
  id: 'beam-eats',
  name: 'BeamEats',
  icon: icons.cityOutline,
  iconTile: 'beam-eats.png',
  route: '/career/phone-beam-eats',
  color: '#ff4757',
  iconColor: '#ffffff',
  category: 'Jobs',
  storeTagline: 'Food delivery gigs',
  storeDescription: 'Pick up BeamEats orders, deliver on time, and stack tips from your delivery runs.',
  defaultPage: 0,
  defaultPosition: 7,
  notifications: [
    {
      key: 'beamEats.newOrder',
      label: 'New Order',
      default: true,
      description: 'New delivery orders',
      order: 0,
    },
  ],
}