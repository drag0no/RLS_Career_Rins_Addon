import { icons } from '@/common/components/base'

export default {
  id: 'fre-contracts',
  name: 'FRE Contracts',
  icon: icons.roadblockL,
  iconTile: 'fre-contracts.png',
  route: '/career/phone-fre-contracts',
  color: '#ff6a00',
  iconColor: '#ffffff',
  category: 'Activities',
  storeTagline: 'Contracts and sponsors',
  storeDescription: 'Pick up FRE contract offers, track active deals, and get notified when new work is available.',
  defaultPage: 0,
  defaultPosition: 11,
  notifications: [
    {
      key: 'fre.contractReady',
      label: 'Contract Ready',
      default: true,
      description: 'New contract offers',
      order: 0,
    },
  ],
}
