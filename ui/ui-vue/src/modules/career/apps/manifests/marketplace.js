import { icons } from '@/common/components/base'

export default {
  id: 'marketplace',
  name: 'Marketplace',
  icon: icons.shoppingCart,
  iconTile: 'marketplace.png',
  route: '/career/phone-marketplace',
  color: '#228B22',
  iconColor: '#ffffff',
  category: 'Vehicles',
  storeTagline: 'Buy and sell cars',
  storeDescription: 'List vehicles, browse listings, and negotiate deals on the player marketplace.',
  defaultPage: 0,
  defaultPosition: 2,
  notifications: [
    {
      key: 'marketplace.newOffer',
      label: 'New Offer',
      default: true,
      description: 'Buyer offers on your listings',
      order: 0,
    },
  ],
}