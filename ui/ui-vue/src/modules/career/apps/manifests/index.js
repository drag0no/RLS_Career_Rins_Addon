// BeamNG's runtime SFC loader does not implement Vite's import.meta.glob.
// Keep the phone manifest catalog explicit so it works in both the packaged
// UI build and the in-game runtime loader used by unpacked mods.
import appStore from './app-store.js'
import bank from './bank.js'
import beamEats from './beam-eats.js'
import camera from './camera.js'
import carMeet from './car-meet.js'
import dakar from './dakar.js'
import facilityWork from './facility-work.js'
import freContracts from './fre-contracts.js'
import freeroamEvents from './freeroam-events.js'
import gallery from './gallery.js'
import guide from './guide.js'
import loans from './loans.js'
import logistics from './logistics.js'
import marketplace from './marketplace.js'
import marketWatch from './market-watch.js'
import offroadRecovery from './offroad-recovery.js'
import quarry from './quarry.js'
import racingTeam from './racing-team.js'
import realEstate from './real-estate.js'
import rentals from './rentals.js'
import repo from './repo.js'
import roadAuthority from './road-authority.js'
import settings from './settings.js'
import skills from './skills.js'
import taxi from './taxi.js'
import tuningShop from './tuning-shop.js'
import travelJournal from './travel-journal.js'
import weather from './weather.js'

export const APP_MANIFESTS = Object.freeze([
  appStore,
  bank,
  beamEats,
  camera,
  carMeet,
  dakar,
  facilityWork,
  freContracts,
  freeroamEvents,
  gallery,
  guide,
  loans,
  logistics,
  marketplace,
  marketWatch,
  offroadRecovery,
  quarry,
  racingTeam,
  realEstate,
  rentals,
  repo,
  roadAuthority,
  settings,
  skills,
  taxi,
  travelJournal,
  tuningShop,
  weather,
])

export default APP_MANIFESTS
