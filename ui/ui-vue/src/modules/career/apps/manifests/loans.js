import { icons } from '@/common/components/base'

export default {
  id: 'loans',
  name: 'Loans',
  icon: icons.beamCurrency,
  iconTile: 'loans.png',
  route: '/career/phone-loans',
  color: '#5a8dee',
  iconColor: '#ffffff',
  category: 'Finance',
  storeTagline: 'Borrow and repay',
  storeDescription: 'View active loans, make payments, and track what you owe without visiting a branch.',
  defaultPage: 0,
  defaultPosition: 0,
  notifications: [
    {
      key: 'loans.paymentMissed',
      label: 'Payment Missed',
      default: true,
      description: 'Failed scheduled payment',
      order: 0,
    },
    {
      key: 'loans.paymentMade',
      label: 'Payment Made',
      default: true,
      description: 'Successful autopay',
      order: 1,
    },
    {
      key: 'loans.paidOff',
      label: 'Loan Paid Off',
      default: true,
      description: 'Loan fully repaid',
      order: 2,
    },
    {
      key: 'loans.approved',
      label: 'Loan Activity',
      default: true,
      description: 'New loan · debt conversion',
      order: 3,
    },
    {
      key: 'loans.prepayment',
      label: 'Prepayment',
      default: true,
      description: 'Extra payment applied',
      order: 4,
    },
  ],
}