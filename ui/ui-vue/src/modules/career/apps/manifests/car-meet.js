import { icons } from '@/common/components/base'

export default {
  id: 'car-meet',
  name: 'Car Meet',
  icon: icons.cars,
  iconTile: 'car-meet.png',
  route: '/career/car-meets-phone',
  color: '#696969',
  iconColor: '#ffffff',
  category: 'Social',
  storeTagline: 'Invites and reputation',
  storeDescription: 'Browse car meet invites, RSVP to events, and keep up with clubs and your car culture reputation.',
  defaultPage: 0,
  defaultPosition: 3,
  notifications: [
    { key: 'carMeet.invite', label: 'Invites', default: true, description: 'Meet and club invites' },
  ],
}