// Career routes --------------------------------------

import "./utils/installLuaBridgeFallbacks"
import ProgressLanding from "./views/ProgressLanding.vue"
import CargoDeliveryReward from "./views/CargoDeliveryReward.vue"
import CargoOverview from "./views/CargoOverviewMain.vue"
import CargoDropOff from "./views/CargoDropOff.vue"
import MaterialContractPickup from "./views/MaterialContractPickup.vue"
import Computer from "./views/ComputerMain.vue"
import EnginePackages from "./views/EnginePackages.vue"
import Insurances from "./views/InsurancesMain.vue"
import DriverAbstract from "./views/DriverAbstract.vue"
import Logbook from "./views/Logbook.vue"
import Milestones from "./views/Milestones.vue"
import MyCargo from "./views/MyCargo.vue"
import Painting from "./views/PaintingMain.vue"
import PartInventory from "./views/PartInventoryMain.vue"
import PartShopping from "./views/PartShoppingMain.vue"
import Pause from "./views/Pause.vue"
import PauseBigMiddlePanel from "./views/PauseBigMiddlePanel.vue"
import ProfileSelect from "./profiles/views/ProfileSelect.vue"
import ProfileNew from "./profiles/views/ProfileNew.vue"
import ProfileSaveSelect from "./profiles/views/ProfileSaveSelect.vue"
import Repair from "./views/RepairMain.vue"
import Tuning from "./views/TuningMain.vue"
import VehicleInventory from "./views/VehicleInventoryMain.vue"
import VehiclePurchase from "./views/VehiclePurchaseMain.vue"
import VehicleShopping from "./views/VehicleShoppingMain.vue"
import VehicleShoppingVehicles from "./views/VehicleShoppingVehiclesMain.vue"
import VehiclePerformance from "./views/VehiclePerformanceMain.vue"
import VehiclePerformanceCertificationTest from "./views/VehiclePerformanceCertificationTest.vue"
import Organizations from "./views/Organizations.vue"
import ChooseInsurance from "./views/ChooseInsuranceMain.vue"
import Negotiation from "./views/VehicleNegotiationMain.vue"
import Sleep from "./views/SleepMenu.vue"
import Loans from "./views/LoanMenu.vue"
import Maintenance from "./views/MaintenanceMenu.vue"
import RoadsideService from "./views/RoadsideServiceMain.vue"
import RoleAssignment from "./views/RoleAssignment.vue"
import UsedCarAuction from "./views/UsedCarAuction.vue"
import TravelJournal from "./views/TravelJournal.vue"
import DakarMenu from "./views/DakarMenu.vue"
import PurchaseGarage from "./views/PurchaseGarage.vue"
import GarageListing from "./views/GarageListing.vue"
import RealEstateNegotiation from "./views/RealEstateNegotiation.vue"
import GarageListings from "./views/GarageListings.vue"
import GarageOffers from "./views/GarageOffers.vue"
import PurchaseBusiness from "./views/PurchaseBusiness.vue"
import PhoneHomescreen from "./views/PhoneHomescreen.vue"
import PhoneMinimap from "./views/PhoneMinimap.vue"
import PhoneMarketplace from "./views/PhoneMarketplace.vue"
import PhoneMarketplaceSell from "./views/PhoneMarketplaceSell.vue"
import PhoneMarketplaceNegotiate from "./views/PhoneMarketplaceNegotiate.vue"
import PhoneMarketplaceVehicle from "./views/PhoneMarketplaceVehicle.vue"
import PhoneTaxi from "./views/PhoneTaxi.vue"
import CarMeetsPhone from "./views/CarMeetsPhone.vue"
import PhoneDakar from "./views/PhoneDakar.vue"
import PhoneRoadAuthority from "./views/PhoneRoadAuthority.vue"
import CarMeetOffers from "./views/CarMeetOffers.vue"
import PhoneOffroadRecovery from "./views/PhoneOffroadRecovery.vue"
import PhoneRepo from "./views/PhoneRepo.vue"
import PhoneLoans from "./views/PhoneLoans.vue"
import PhoneLoanDetails from "./views/PhoneLoanDetails.vue"
import PhoneOfferDetails from "./views/PhoneOfferDetails.vue"
import PhoneCredit from "./views/PhoneCredit.vue"
import PhoneLoanSettings from "./views/PhoneLoanSettings.vue"
import PhoneBank from "./views/PhoneBank.vue"
import PhoneBankAccount from "./views/PhoneBankAccount.vue"
import PhoneBankRename from "./views/PhoneBankRename.vue"
import PhoneTuningShop from "./views/PhoneTuningShop.vue"
import PhoneRacingTeam from "./views/PhoneRacingTeam.vue"
import PhoneQuarry from "./views/PhoneQuarry.vue"
import PhoneBeamEats from "./views/PhoneBeamEats.vue"
import PhoneFacilityWork from "./views/PhoneFacilityWork.vue"
import PhoneRealEstate from "./views/PhoneRealEstate.vue"
import PhoneRentals from "./views/PhoneRentals.vue"
import PhoneLogistics from "./views/PhoneLogistics.vue"
import PhoneGuide from "./views/PhoneGuide.vue"
import PhoneSkills from "./views/PhoneSkills.vue"
import PhoneSkillDetails from "./views/PhoneSkillDetails.vue"
import PhoneSettings from "./views/PhoneSettings.vue"
import PhoneNotificationsHub from "./views/PhoneNotificationsHub.vue"
import PhoneNotificationAppSettings from "./views/PhoneNotificationAppSettings.vue"
import PhoneNotificationLockScreenSettings from "./views/PhoneNotificationLockScreenSettings.vue"
import PhoneNotificationDndSettings from "./views/PhoneNotificationDndSettings.vue"
import PhoneAppStore from "./views/PhoneAppStore.vue"
import PhoneMarketWatch from "./views/PhoneMarketWatch.vue"
import PhoneFreeroamEvents from "./views/PhoneFreeroamEvents.vue"
import PhoneFreContracts from "./views/PhoneFreContracts.vue"
import PhoneCamera from "./views/PhoneCamera.vue"
import PhoneGallery from "./views/PhoneGallery.vue"
import PhoneTravelJournal from "./views/PhoneTravelJournal.vue"
import PhoneWeather from "./views/PhoneWeather.vue"

import LevelSwitch from "./views/LevelSwitch.vue"
import ChallengeComplete from "./views/ChallengeComplete.vue"
import BusinessComputerMain from "./views/BusinessComputerMain.vue"
import CardTester from "./views/CardTester.vue"
import CardGames from "./views/CardGames.vue"

const computerRouteMeta = {
  infoBar: { visible: true, showSysInfo: true },
  uiApps: { shown: false },
}

export default [
  // Career Pause
  {
    path: "/menu.careerPause",
    name: "menu.careerPause",
    component: Pause,
    props: true,
    meta: {
      clickThrough: true,
      infoBar: {
        withAngular: true,
        visible: true,
        showSysInfo: true,
      },
      uiApps: {
        shown: false,
      },
      topBar: {
        visible: true
      }
    },
  },
  {
    name: "career",
    path: "/career",
    children: [
      // Choose Insurance
      {
        path: "chooseInsurance",
        name: "career.chooseInsurance",
        component: ChooseInsurance,
      },

      // Career Pause (WIP with middle panel)
      {
        path: "pauseBigMiddlePanel",
        name: "career.pauseBigMiddlePanel",
        component: PauseBigMiddlePanel,
        props: true,
      },

      // Logbook
      {
        path: "logbook/:id(\\*?.*?)?",
        name: "career.logbook",
        component: Logbook,
        meta: {
          uiApps: {
            shown: false,
          },
        },
        props: true,
      },

      {
        path: "milestones/:id(\\*?.*?)?",
        name: "career.milestones",
        component: Milestones,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      // Computer
      {
        path: "computer",
        name: "career.computer",
        component: Computer,
        props: true,
        meta: {
          uiApps: {
            shown: false,
            //layout: "tasklist",
          },
        },
      },

      // Vehicle Inventory
      {
        path: "computer/vehicleInventory",
        name: "career.computer.vehicleInventory",
        component: VehicleInventory,
      },

      // Vehicle Certification - in-progress test screen. The exact path must
      // precede the optional inventoryId route below.
      {
        path: "computer/vehiclePerformance/certificationTest",
        name: "career.computer.vehiclePerformance.certificationTest",
        component: VehiclePerformanceCertificationTest,
        meta: { ...computerRouteMeta },
      },

      // Vehicle Certification
      {
        path: "computer/vehiclePerformance/:inventoryId?",
        name: "career.computer.vehiclePerformance",
        component: VehiclePerformance,
        props: true,
      },

      // Tuning
      {
        path: "computer/tuning",
        name: "career.computer.tuning",
        component: Tuning,
      },

      // Painting
      {
        path: "computer/painting",
        name: "career.computer.painting",
        component: Painting,
      },

      // Repair
      {
        path: "computer/repair/:header?",
        name: "career.computer.repair",
        component: Repair,
        props: true,
      },

      // Part Shopping
      {
        path: "computer/partShopping",
        name: "career.computer.partShopping",
        component: PartShopping,
        meta: {
          uiApps: {
            shown: false,
            //layout: "tasklist",
          },
        },
      },
      {
        path: "computer/partShopping/:category",
        name: "career.computer.partShopping.category",
        component: PartShopping,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },
      {
        path: "computer/partShopping/:category/slot/:slotPath(.*)*",
        name: "career.computer.partShopping.category.slot",
        component: PartShopping,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      // Part Inventory
      {
        path: "computer/partInventory",
        name: "career.computer.partInventory",
        component: PartInventory,
      },

      // Engine Packages
      {
        path: "computer/enginePackages",
        name: "career.computer.enginePackages",
        component: EnginePackages,
        meta: { ...computerRouteMeta },
      },

      // Vehicle list must precede the optional-param shopping route below.
      {
        path: "computer/vehicleShopping/vehicles",
        name: "career.computer.vehicleShopping.vehicles",
        component: VehicleShoppingVehicles,
        meta: {
          ...computerRouteMeta,
          handlesOwnReady: true,
        },
      },

      // Vehicle Purchase
      {
        path: "computer/vehicleShopping/vehicles/vehiclePurchase/:vehicleInfo?/:playerMoney?/:inventoryHasFreeSlot?/:lastVehicleInfo?",
        name: "career.computer.vehicleShopping.vehicles.vehiclePurchase",
        component: VehiclePurchase,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },
      {
        path: "computer/vehicleShopping/vehicleInventory",
        name: "career.computer.vehicleShopping.vehicleInventory",
        component: VehicleInventory,
      },

      // Negotiation
      {
        path: "negotiation",
        name: "career.negotiation",
        component: Negotiation,
      },

      {
        path: "carMeetOffers",
        name: "carMeetOffers",
        component: CarMeetOffers,
      },

      // Vehicle Shopping
      {
        path: "computer/vehicleShopping/:screenTag?/:buyingAvailable?/:marketplaceAvailable?/:selectedSellerId?",
        name: "career.computer.vehicleShopping",
        component: VehicleShopping,
        props: true,
        meta: {
          uiApps: {
            shown: false,
            //layout: "tasklist",
          },
        },
      },

      // Insurance policies List
      {
        path: "computer/insurances",
        name: "career.computer.insurances",
        component: Insurances,
      },

      // Organizations / reputation
      {
        path: "organizations/:orgId?",
        name: "career.organizations",
        component: Organizations,
        props: route => ({ orgId: route.params.orgId }),
        meta: {
          uiApps: { shown: false },
          infoBar: { visible: true },
        },
      },

      // Driver's Abstract
      {
        path: "computer/playerAbstract",
        name: "career.computer.playerAbstract",
        component: DriverAbstract,
      },

      // Delivery Reward
      {
        path: "cargoDeliveryReward",
        name: "career.cargoDeliveryReward",
        component: CargoDeliveryReward,
        props: true,
      },

      // delivery dropoff
      {
        path: "cargoDropOff/:facilityId?/:parkingSpotPath(\\*?.*?)?",
        name: "career.cargoDropOff",
        component: CargoDropOff,
        props: true,
      },

      // Cargo Overview
      {
        path: "cargoOverview/:facilityId?/:parkingSpotPath(\\*?.*?)?",
        name: "career.cargoOverview",
        component: CargoOverview,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },
      {
        path: "materialContractPickup",
        name: "career.materialContractPickup",
        component: MaterialContractPickup,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },
      {
        path: "myCargo",
        name: "career.myCargo",
        component: MyCargo,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      // Branch Landing Page
      {
        path: "progressLanding/:pathId?/:comesFromBigMap?",
        name: "career.progressLanding",
        component: ProgressLanding,
        props: route => ({
          pathId: route.params.pathId,
          comesFromBigMap: route.params.comesFromBigMap === "true" || route.params.comesFromBigMap === true
        }),
        meta: {
          uiApps: {
            shown: false,
          },
          infoBar: {
            visible: true,
          },
        },
      },
      {
        path: "branchPage/:pathId?/:comesFromBigMap?",
        name: "career.branchPage",
        component: ProgressLanding,
        props: route => ({
          pathId: route.params.pathId,
          comesFromBigMap: route.params.comesFromBigMap === "true" || route.params.comesFromBigMap === true
        }),
        meta: {
          uiApps: {
            shown: false,
          },
          infoBar: {
            visible: true,
          },
        },
      },

      // Domain Landing Page
      {
        path: "domainSelection",
        name: "career.domainSelection",
        component: ProgressLanding,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
          infoBar: {
            visible: true,
          },
        },
      },
      // Profiles (create/load stay on custom strip; no vanilla wizard)
      {
        path: "profiles",
        name: "career.profiles",
        component: ProfileSelect,
        meta: {
          uiApps: {
            shown: false,
          },
          infoBar: {
            visible: true,
            showSysInfo: true,
          },
        }
      },
      {
        path: "profiles/new",
        name: "career.profiles.new",
        component: ProfileNew,
        meta: {
          uiApps: {
            shown: false,
          },
          infoBar: {
            visible: true,
            showSysInfo: true,
          },
        }
      },
      {
        path: "profiles/saves/:profileId?",
        name: "career.profiles.saves",
        component: ProfileSaveSelect,
        props: route => ({
          profileId: route.params.profileId,
          mode: "load",
        }),
        meta: {
          uiApps: {
            shown: false,
          },
          infoBar: {
            visible: true,
            showSysInfo: true,
          },
        }
      },
      {
        path: "profiles/saveAs",
        name: "career.profiles.saveAs",
        component: ProfileSaveSelect,
        props: () => ({
          mode: "save",
        }),
        meta: {
          uiApps: {
            shown: false,
          },
          infoBar: {
            visible: true,
            showSysInfo: true,
          },
        }
      },

      // Sleep Menu
      {
        path: "sleep-menu",
        name: "sleep-menu",
        component: Sleep
      },

      // Loans Menu
      {
        path: "loans-menu",
        name: "loans-menu",
        component: Loans
      },

      // Maintenance Menu
      {
        path: "maintenance",
        name: "maintenance",
        component: Maintenance
      },

      // Roadside Service
      {
        path: "roadside-service",
        name: "roadside-service",
        component: RoadsideService,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      // Police Assignment
      {
        path: "roleAssignment",
        name: "roleAssignment",
        component: RoleAssignment
      },

      {
        path: "used-car-auction",
        name: "used-car-auction",
        component: UsedCarAuction,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      {
        path: "travel-journal",
        name: "travel-journal",
        component: TravelJournal,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      {
        path: "dakar/:tab?",
        name: "dakar",
        component: DakarMenu,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      {
        path: "purchase-garage",
        name: "purchase-garage",
        component: PurchaseGarage
      },

      {
        path: "garage-listing",
        name: "garage-listing",
        component: GarageListing
      },

      {
        path: "realEstateNegotiation",
        name: "realEstateNegotiation",
        component: RealEstateNegotiation
      },

      {
        path: "garage-listings",
        name: "garage-listings",
        component: GarageListings,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      {
        path: "garage-offers/:garageId",
        name: "garage-offers",
        component: GarageOffers,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      {
        path: "purchase-business",
        name: "purchase-business",
        component: PurchaseBusiness
      },

      {
        path: "phone-minimap",
        name: "phone-minimap",
        component: PhoneMinimap
      },

      {
        path: "phone-main",
        name: "phone-main",
        component: PhoneHomescreen
      },

      {
        path: "car-meets-phone",
        name: "car-meets-phone",
        component: CarMeetsPhone
      },

      {
        path: "phone-dakar",
        name: "phone-dakar",
        component: PhoneDakar
      },

      {
        path: "phone-road-authority",
        name: "phone-road-authority",
        component: PhoneRoadAuthority
      },

      {
        path: "phone-taxi",
        name: "phone-taxi",
        component: PhoneTaxi
      },

      {
        path: "phone-marketplace",
        name: "phone-marketplace",
        component: PhoneMarketplace
      },

      {
        path: "phone-marketplace-sell",
        name: "phone-marketplace-sell",
        component: PhoneMarketplaceSell
      },

      {
        path: "phone-marketplace-negotiate",
        name: "phone-marketplace-negotiate",
        component: PhoneMarketplaceNegotiate
      },

      {
        path: "phone-marketplace-vehicle/:kind/:vehicleId",
        name: "phone-marketplace-vehicle",
        component: PhoneMarketplaceVehicle,
        props: true
      },

      {
        path: "phone-offroad-recovery",
        name: "phone-offroad-recovery",
        component: PhoneOffroadRecovery
      },

      {
        path: "phone-repo",
        name: "phone-repo",
        component: PhoneRepo
      },

      {
        path: "phone-loans",
        name: "phone-loans",
        component: PhoneLoans
      },
      {
        path: "phone-credit",
        name: "phone-credit",
        component: PhoneCredit
      },
      {
        path: "phone-loan/:loanId",
        name: "phone-loan-details",
        component: PhoneLoanDetails,
        props: true
      },
      {
        path: "phone-loan-offer/:orgId",
        name: "phone-offer-details",
        component: PhoneOfferDetails,
        props: true
      },
      {
        path: "phone-loan-settings",
        name: "phone-loan-settings",
        component: PhoneLoanSettings
      },

      {
        path: "phone-bank",
        name: "phone-bank",
        component: PhoneBank
      },

      {
        path: "phone-bank/:accountId",
        name: "phone-bank-account",
        component: PhoneBankAccount,
        props: true
      },

      {
        path: "phone-bank/:accountId/rename",
        name: "phone-bank-rename",
        component: PhoneBankRename,
        props: true
      },

      {
        path: "phone-tuning-shop",
        name: "phone-tuning-shop",
        component: PhoneTuningShop
      },

      {
        path: "phone-racing-team",
        name: "phone-racing-team",
        component: PhoneRacingTeam
      },

      {
        path: "phone-quarry",
        name: "phone-quarry",
        component: PhoneQuarry
      },

      {
        path: "phone-beam-eats",
        name: "phone-beam-eats",
        component: PhoneBeamEats
      },

      {
        path: "phone-facility-work",
        name: "phone-facility-work",
        component: PhoneFacilityWork
      },

      {
        path: "phone-logistics",
        name: "phone-logistics",
        component: PhoneLogistics
      },

      {
        path: "phone-real-estate",
        name: "phone-real-estate",
        component: PhoneRealEstate
      },

      {
        path: "phone-rentals",
        name: "phone-rentals",
        component: PhoneRentals
      },

      {
        path: "phone-guide",
        name: "phone-guide",
        component: PhoneGuide
      },
      {
        path: "phone-skills",
        name: "phone-skills",
        component: PhoneSkills
      },
      {
        path: "phone-skills/:skillId",
        name: "phone-skills-details",
        component: PhoneSkillDetails,
        props: true
      },
      {
        path: "phone-settings",
        name: "phone-settings",
        component: PhoneSettings
      },
      {
        path: "phone-notification-settings",
        name: "phone-notification-settings",
        component: PhoneNotificationsHub
      },
      {
        path: "phone-notification-app-settings",
        name: "phone-notification-app-settings",
        component: PhoneNotificationAppSettings
      },
      {
        path: "phone-notification-lock-screen",
        name: "phone-notification-lock-screen",
        component: PhoneNotificationLockScreenSettings
      },
      {
        path: "phone-notification-dnd",
        name: "phone-notification-dnd",
        component: PhoneNotificationDndSettings
      },
      {
        path: "phone-app-store",
        name: "phone-app-store",
        component: PhoneAppStore
      },

      {
        path: "phone-market-watch",
        name: "phone-market-watch",
        component: PhoneMarketWatch
      },
      {
        path: "phone-weather",
        name: "phone-weather",
        component: PhoneWeather
      },
      {
        path: "phone-events",
        name: "phone-events",
        component: PhoneFreeroamEvents

      },
      {
        path: "phone-fre-contracts",
        name: "phone-fre-contracts",
        component: PhoneFreContracts
      },

      {
        path: "phone-camera",
        name: "phone-camera",
        component: PhoneCamera
      },

      {
        path: "phone-gallery",
        name: "phone-gallery",
        component: PhoneGallery
      },

      {
        path: "phone-travel-journal",
        name: "phone-travel-journal",
        component: PhoneTravelJournal
      },

      {
        path: "level-switch",
        name: "level-switch",
        component: LevelSwitch
      },
      {
        path: "challenge-completed",
        name: "challenge-completed",
        component: ChallengeComplete
      },

      {
        path: "business-computer/:businessType/:businessId",
        name: "business-computer",
        component: BusinessComputerMain,
        props: true,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      {
        path: "card-tester",
        name: "card-tester",
        component: CardTester,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

      {
        path: "card-games",
        name: "card-games",
        component: CardGames,
        meta: {
          uiApps: {
            shown: false,
          },
        },
      },

    ],
  },
]
