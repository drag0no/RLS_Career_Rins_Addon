<template>
  <main class="journal-screen" bng-ui-scope="travelJournalFullscreen" bng-scoped-nav-autofocus v-bng-on-ui-nav:back,menu.asMouse="handleBack">
    <div class="journal-book">
      <div v-if="loading" class="center-state"><span class="spinner"></span><span>Opening journal...</span></div>
      <div v-else-if="error" class="center-state error-state">
        <strong>Journal unavailable</strong><span>{{ error }}</span>
        <button bng-nav-item class="paper-button primary" @click="loadState">Try again</button>
        <button bng-nav-item class="paper-button" @click="closeJournal">Close</button>
      </div>

      <template v-else-if="selectedMap">
        <header class="book-header">
          <button bng-nav-item class="paper-button close-button" @click="closeJournal">Close Journal</button>
          <div class="map-heading">
            <span class="eyebrow">Travel Journal</span>
            <div class="map-title-row">
              <button bng-nav-item class="page-arrow" :disabled="mapIndex === 0" @click="previousMap">&#8249;</button>
              <div><h1>{{ selectedMap.name }}</h1><p>{{ selectedMap.completedCount }} / {{ selectedMap.totalCount }} locations complete</p></div>
              <button bng-nav-item class="page-arrow" :disabled="mapIndex >= maps.length - 1" @click="nextMap">&#8250;</button>
            </div>
          </div>
          <div class="xp-note"><b>1,000 XP</b><span>per first completion</span></div>
        </header>

        <section class="location-layout" aria-label="Journal locations">
          <button
            v-for="(location, index) in selectedMap.locations"
            :key="location.id"
            bng-nav-item
            class="location-card"
            :class="[`slot-${index + 1}`, location.status]"
            @click="openLocation(location)"
          >
            <span class="polaroid"><span class="photo-window">
              <img v-if="cardImage(selectedMap, location)" :src="cardImage(selectedMap, location)" :alt="`${location.name} journal cover`" />
              <span v-else class="memory-placeholder" :class="{ undiscovered: location.status === 'notFound' }">
                <template v-if="location.status === 'completed'">Memory preserved</template>
              </span>
            </span></span>
            <span class="location-copy">
              <span class="number">No. {{ String(index + 1).padStart(2, '0') }}</span>
              <strong>{{ location.name }}</strong>
              <small>{{ statusLabel(location.status) }} - {{ location.photoCount }} photo{{ location.photoCount === 1 ? '' : 's' }}</small>
            </span>
            <span class="status-mark">{{ location.status === 'completed' ? '✓' : location.status === 'discovered' ? 'FOUND' : '?' }}</span>
          </button>

          <div class="map-stamp" :class="{ earned: selectedMap.stampAwarded }">
            <span class="stamp-ring"><b>{{ selectedMap.stampAwarded ? 'COMPLETE' : 'LOCKED' }}</b><small>{{ selectedMap.stampLabel }}</small></span>
            <p>{{ selectedMap.stampAwarded ? 'Map completion stamp earned' : 'Complete all five locations' }}</p>
          </div>
        </section>

        <div class="page-dots" aria-label="Map pages">
          <button v-for="(map, index) in maps" :key="map.id" bng-nav-item :class="{ active: index === mapIndex }" @click="mapIndex = index"></button>
        </div>
      </template>
    </div>

    <div v-if="selectedLocation" class="detail-backdrop" @click.self="closeLocation">
      <section class="location-detail">
        <header>
          <div><span class="eyebrow">{{ selectedMap.name }}</span><h2>{{ selectedLocation.name }}</h2><p>{{ statusLabel(selectedLocation.status) }} - {{ selectedLocation.photoCount }} photos</p></div>
          <button bng-nav-item class="paper-button" @click="closeLocation">Back to Page</button>
        </header>
        <p class="location-description">{{ selectedLocation.description }}</p>
        <div class="location-actions">
          <button bng-nav-item class="paper-button primary" :disabled="routePending || !selectedLocation.canNavigate" @click="setRoute">
            {{ routePending ? 'Setting Route...' : routedLocationId === selectedLocation.id ? 'Route Selected' : 'Set Route' }}
          </button>
          <button bng-nav-item class="paper-button scene" :disabled="scenePending || !selectedLocation.canEnterScene" @click="enterPhotoScene">
            {{ scenePending ? 'Opening Photo Mode...' : selectedLocation.insideZone ? 'Enter Photo Scene' : 'Drive Into Scenic Area' }}
          </button>
        </div>
        <p v-if="actionFeedback" class="action-feedback" :class="{ error: actionFeedbackError }">{{ actionFeedback }}</p>

        <div class="section-title"><span>Featured photographs</span><small>3 scrapbook slots</small></div>
        <div class="featured-grid">
          <button v-for="slot in 3" :key="slot" bng-nav-item class="featured-photo" :disabled="!featuredPhotos[slot - 1]" @click="openPreview(featuredPhotos[slot - 1])">
            <img v-if="featuredPhotos[slot - 1] && photoUrl(selectedMap.id, selectedLocation.id, featuredPhotos[slot - 1].id)" :src="photoUrl(selectedMap.id, selectedLocation.id, featuredPhotos[slot - 1].id)" alt="Featured photograph" />
            <span v-else>Photo {{ slot }}</span>
          </button>
        </div>

        <div class="section-title"><span>Album</span><small>{{ selectedLocation.photoCount }} photos</small></div>
        <div v-if="selectedLocation.photos.length" class="album-grid">
          <button v-for="photo in selectedLocation.photos" :key="photo.id" bng-nav-item class="album-photo" @click="openPreview(photo)">
            <img v-if="photoUrl(selectedMap.id, selectedLocation.id, photo.id)" :src="photoUrl(selectedMap.id, selectedLocation.id, photo.id)" alt="Journal photograph" />
            <span v-else class="spinner small"></span><span v-if="photo.cover" class="cover-label">Cover</span>
          </button>
        </div>
        <div v-else class="empty-album">Take a photograph during this location's scene to add it here.</div>
      </section>
    </div>

    <div v-if="previewPhoto" class="preview-backdrop" @click.self="closePreview">
      <div class="preview-card">
        <img v-if="previewUrl" :src="previewUrl" alt="Journal photograph preview" /><span v-else class="spinner"></span>
        <button bng-nav-item class="paper-button" @click="closePreview">Close Photo</button>
      </div>
    </div>
  </main>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { lua } from '@/bridge'
import { runRaw, serialize } from '@/bridge/libs/Lua'
import { useEvents } from '@/services/events'
import { vBngOnUiNav } from '@/common/directives'

const events = useEvents()
const state = ref(null)
const loading = ref(true)
const error = ref('')
const mapIndex = ref(0)
const selectedLocationId = ref(null)
const previewPhoto = ref(null)
const routePending = ref(false)
const scenePending = ref(false)
const routedLocationId = ref(null)
const actionFeedback = ref('')
const actionFeedbackError = ref(false)
const photoUrls = reactive({})
const photoRequests = new Set()
const MAX_PHOTO_CACHE_ENTRIES = 48
const callJournal = (method, ...args) => runRaw(`gameplay_travelJournal.${method}(${args.map(serialize).join(',')})`)

function normalizeJournalState(raw) {
  if (!raw || typeof raw !== 'object') return raw
  return {...raw, maps: Array.isArray(raw.maps) ? raw.maps.map(map => ({...map, locations: Array.isArray(map.locations) ? map.locations.map(location => ({...location, photos: Array.isArray(location.photos) ? location.photos : [], featuredPhotoIds: Array.isArray(location.featuredPhotoIds) ? location.featuredPhotoIds : []})) : []})) : []}
}

const maps = computed(() => Array.isArray(state.value?.maps) ? state.value.maps : [])
const selectedMap = computed(() => maps.value[mapIndex.value] || null)
const selectedLocation = computed(() => selectedMap.value?.locations.find(location => location.id === selectedLocationId.value) || null)
const featuredPhotos = computed(() => selectedLocation.value ? selectedLocation.value.featuredPhotoIds.map(id => selectedLocation.value.photos.find(photo => photo.id === id)).filter(Boolean) : [])
const previewUrl = computed(() => previewPhoto.value && selectedMap.value && selectedLocation.value ? photoUrl(selectedMap.value.id, selectedLocation.value.id, previewPhoto.value.id) : null)
const photoKey = (mapId, locationId, photoId) => `${mapId}/${locationId}/${photoId}`

function photoUrl(mapId, locationId, photoId) {
  if (!mapId || !locationId || !photoId) return null
  return photoUrls[photoKey(mapId, locationId, photoId)] || null
}

async function loadPhoto(mapId, locationId, photoId) {
  const key = photoKey(mapId, locationId, photoId)
  if (photoRequests.has(key)) return
  photoRequests.add(key)
  try {
    const url = await callJournal('getPhotoDataUrl', mapId, locationId, photoId)
    if (url) {
      photoUrls[key] = url
      const keys = Object.keys(photoUrls)
      if (keys.length > MAX_PHOTO_CACHE_ENTRIES) delete photoUrls[keys[0]]
    }
  } catch (_) {} finally { photoRequests.delete(key) }
}

function queueVisiblePhotos() {
  if (!selectedMap.value) return
  for (const location of selectedMap.value.locations) if (location.coverPhotoId) loadPhoto(selectedMap.value.id, location.id, location.coverPhotoId)
  if (selectedLocation.value) for (const photo of selectedLocation.value.photos) loadPhoto(selectedMap.value.id, selectedLocation.value.id, photo.id)
}

async function loadState() {
  loading.value = true; error.value = ''
  try {
    await lua.extensions.load('gameplay_travelJournal')
    state.value = normalizeJournalState(await callJournal('getJournalState'))
    const currentIndex = maps.value.findIndex(map => map.current)
    if (currentIndex >= 0) mapIndex.value = currentIndex
    queueVisiblePhotos()
  } catch (err) {
    console.error('[TravelJournal] full journal load failed', err)
    error.value = 'The career journal service could not be loaded.'
  } finally { loading.value = false }
}

function applyState(next) {
  if (!next || typeof next !== 'object') return
  const mapId = selectedMap.value?.id
  state.value = normalizeJournalState(next)
  const nextIndex = mapId ? maps.value.findIndex(map => map.id === mapId) : -1
  if (nextIndex >= 0) mapIndex.value = nextIndex
  if (selectedLocationId.value && !selectedLocation.value) selectedLocationId.value = null
  queueVisiblePhotos()
}

function cardImage(map, location) { return location.status === 'completed' && location.coverPhotoId ? photoUrl(map.id, location.id, location.coverPhotoId) : null }
function statusLabel(status) { return status === 'completed' ? 'Completed' : status === 'discovered' ? 'Discovered' : 'Not found' }
function previousMap() { if (mapIndex.value > 0) mapIndex.value -= 1 }
function nextMap() { if (mapIndex.value < maps.value.length - 1) mapIndex.value += 1 }
function openLocation(location) { selectedLocationId.value = location.id; actionFeedback.value = ''; actionFeedbackError.value = false; queueVisiblePhotos() }
function closeLocation() { selectedLocationId.value = null; previewPhoto.value = null; actionFeedback.value = '' }

async function setRoute() {
  if (!selectedMap.value || !selectedLocation.value || routePending.value) return
  routePending.value = true; actionFeedback.value = ''; actionFeedbackError.value = false
  try {
    const result = await callJournal('setRouteToLocation', selectedMap.value.id, selectedLocation.value.id)
    if (result?.success) { routedLocationId.value = selectedLocation.value.id; actionFeedback.value = `Navigation is guiding you to ${selectedLocation.value.name}.` }
    else { actionFeedback.value = result?.reason === 'wrong_map' ? `Load ${selectedMap.value.name} to set this route.` : 'Navigation is unavailable.'; actionFeedbackError.value = true }
  } catch (_) { actionFeedback.value = 'Navigation is unavailable.'; actionFeedbackError.value = true } finally { routePending.value = false }
}

async function enterPhotoScene() {
  if (!selectedMap.value || !selectedLocation.value || scenePending.value) return
  scenePending.value = true; actionFeedback.value = ''; actionFeedbackError.value = false
  try {
    const result = await callJournal('requestSceneFromJournal', selectedMap.value.id, selectedLocation.value.id)
    if (!result?.success) {
      actionFeedback.value = result?.reason === 'outside_zone' ? 'Drive into the scenic area first.' : result?.reason === 'trailer_attached' ? 'Detach the trailer before entering.' : 'The photography scene could not be opened.'
      actionFeedbackError.value = true; scenePending.value = false
    }
  } catch (_) { actionFeedback.value = 'The photography scene could not be opened.'; actionFeedbackError.value = true; scenePending.value = false }
}

function openPreview(photo) { if (photo) previewPhoto.value = photo }
function closePreview() { previewPhoto.value = null }
function handleBack() { if (previewPhoto.value) return closePreview(); if (selectedLocation.value) return closeLocation(); closeJournal() }
function closeJournal() { runRaw('extensions.ui_router.navigate("play")') }

watch([mapIndex, selectedLocationId], queueVisiblePhotos)
onMounted(() => { events.on('TravelJournalStateChanged', applyState); loadState() })
onBeforeUnmount(() => events.off('TravelJournalStateChanged', applyState))
</script>

<style scoped lang="scss">
$ink: #342a25; $muted: #786a61; $rose: #a95e62; $green: #55735b;
.journal-screen { position: fixed; inset: 0; z-index: 100; box-sizing: border-box; overflow: auto; padding: clamp(1rem, 2vw, 2rem); color: $ink; background: rgba(17, 14, 12, 0.88); font-family: Georgia, 'Times New Roman', serif; }
.journal-book { width: min(112rem, 100%); min-height: calc(100vh - clamp(2rem, 4vw, 4rem)); margin: auto; box-sizing: border-box; overflow: hidden; border: 0.8rem solid #70533f; border-radius: 0.8rem; background: radial-gradient(circle at 17% 20%, rgba(121,84,54,.1) 0 1px, transparent 1.6px), linear-gradient(100deg, #f4ecde 0 49.7%, #d7c9b4 49.8% 50.2%, #f1e7d7 50.3%); background-size: 25px 28px, auto; box-shadow: 0 1.2rem 3rem rgba(0,0,0,.55), inset 0 0 5rem rgba(88,59,38,.12); }
.book-header { display: grid; grid-template-columns: minmax(10rem,1fr) minmax(24rem,2fr) minmax(10rem,1fr); align-items: center; gap: 1rem; padding: 1.2rem 1.5rem .7rem; border-bottom: 1px dashed rgba(69,48,34,.28); }
.map-heading { text-align: center; }.map-title-row { display: grid; grid-template-columns: 3rem 1fr 3rem; align-items: center; gap: .8rem; }.map-heading h1 { margin: .1rem 0 0; font-size: clamp(2rem,3.1vw,3.7rem); line-height: .95; }.map-heading p { margin: .3rem 0 0; color: $muted; font: .9rem Arial,sans-serif; }
.eyebrow { color: $rose; font: 700 .72rem Arial,sans-serif; letter-spacing: .16em; text-transform: uppercase; }.page-arrow { width: 2.7rem; height: 2.7rem; border: 0; border-radius: 50%; color: $ink; background: rgba(105,75,54,.1); font-size: 2rem; }.page-arrow:disabled { opacity: .2; }
.paper-button { min-height: 2.6rem; padding: .55rem .9rem; border: 1px solid rgba(78,58,45,.3); border-radius: .3rem; color: $ink; background: #f8f1e3; box-shadow: 0 2px 5px rgba(53,38,27,.15); font: 700 .78rem Arial,sans-serif; }.paper-button.primary { color: #fff; border-color: $rose; background: $rose; }.paper-button.scene { color: #fff; border-color: $green; background: $green; }.paper-button:disabled { opacity: .4; }.xp-note { justify-self: end; display: flex; flex-direction: column; padding: .6rem .85rem; color: $green; border: 2px solid $green; transform: rotate(3deg); text-align: center; }.xp-note b { font: 800 1rem Arial,sans-serif; }.xp-note span { color: $muted; font: .66rem Arial,sans-serif; }
.location-layout { display: grid; grid-template-columns: repeat(3,minmax(17rem,1fr)); grid-template-rows: repeat(2,minmax(15rem,1fr)); grid-template-areas: 'one two three' 'four stamp five'; align-items: center; gap: clamp(.8rem,1.5vw,1.5rem); min-height: calc(100vh - 13.5rem); padding: 1.2rem 2rem; }
.location-card { position: relative; display: grid; grid-template-columns: minmax(8rem,44%) 1fr; align-items: center; gap: .9rem; width: 100%; min-height: 12.5rem; box-sizing: border-box; padding: .75rem .9rem; border: 0; color: $ink; background: rgba(255,251,242,.96); box-shadow: 0 .55rem 1rem rgba(55,37,24,.22); text-align: left; transition: transform .13s,box-shadow .13s; }.location-card:hover,.location-card:focus-visible { z-index: 2; box-shadow: 0 .8rem 1.5rem rgba(55,37,24,.34); transform: rotate(0) scale(1.025); outline: 3px solid rgba(169,94,98,.55); }.slot-1{grid-area:one;transform:rotate(-1.4deg)}.slot-2{grid-area:two;transform:rotate(.8deg)}.slot-3{grid-area:three;transform:rotate(-.7deg)}.slot-4{grid-area:four;transform:rotate(.9deg)}.slot-5{grid-area:five;transform:rotate(-1.1deg)}
.polaroid { display:block; padding:.45rem .45rem 1.1rem; background:#fff; box-shadow:0 .25rem .6rem rgba(38,28,21,.24) }.photo-window { display:block; height:clamp(7.5rem,15vh,11rem); overflow:hidden; background:#cfc4b2 }.photo-window img { width:100%; height:100%; display:block; object-fit:cover }.memory-placeholder { height:100%; display:flex; align-items:center; justify-content:center; color:$green; background:repeating-linear-gradient(45deg,#e3dbc9,#e3dbc9 8px,#eee6d8 8px,#eee6d8 16px) }.memory-placeholder.undiscovered { background:#aaa7a1 }
.location-copy { min-width:0; display:flex; flex-direction:column; gap:.35rem }.location-copy strong { font-size:clamp(1.05rem,1.4vw,1.45rem); line-height:1.05 }.location-copy small { color:$muted; font:.72rem/1.3 Arial,sans-serif }.number { color:$rose; font:700 .67rem Arial,sans-serif; letter-spacing:.1em; text-transform:uppercase }.status-mark { position:absolute; right:.75rem; bottom:.65rem; min-width:2rem; height:2rem; display:flex; align-items:center; justify-content:center; border:2px solid rgba(86,62,46,.35); border-radius:50%; color:$muted; font:700 .55rem Arial,sans-serif; transform:rotate(-8deg) }.location-card.completed .status-mark { color:$green; border-color:$green; font-size:1.1rem }.location-card.discovered .status-mark { color:#a47738; border-color:#a47738 }
.map-stamp { grid-area:stamp; justify-self:center; display:flex; flex-direction:column; align-items:center; gap:.5rem; opacity:.48; text-align:center }.map-stamp.earned{opacity:1}.stamp-ring { width:8.5rem; height:8.5rem; display:flex; flex-direction:column; align-items:center; justify-content:center; border:5px double $rose; border-radius:50%; color:$rose; transform:rotate(-8deg) }.stamp-ring b { font:800 .95rem Arial,sans-serif; letter-spacing:.12em }.stamp-ring small { max-width:7rem; font-size:.7rem }.map-stamp p { margin:0; color:$muted; font:.72rem Arial,sans-serif }.page-dots { display:flex; justify-content:center; gap:.45rem; padding:0 0 1rem }.page-dots button { width:.58rem; height:.58rem; padding:0; border:0; border-radius:50%; background:rgba(62,43,32,.25) }.page-dots button.active { background:$rose; transform:scale(1.25) }
.detail-backdrop,.preview-backdrop { position:fixed; inset:0; z-index:1300; display:flex; align-items:center; justify-content:center; padding:2rem; background:rgba(20,15,12,.72); backdrop-filter:blur(4px) }.location-detail { width:min(76rem,calc(100vw - 4rem)); max-height:calc(100vh - 4rem); overflow:auto; box-sizing:border-box; padding:1.4rem; color:$ink; background:linear-gradient(145deg,#f7efe2,#e6d9c5); box-shadow:0 1.2rem 3rem rgba(0,0,0,.5) }.location-detail>header { display:flex; justify-content:space-between; align-items:center; gap:1rem; border-bottom:1px dashed rgba(69,48,34,.28) }.location-detail h2 { margin:.2rem 0 0; font-size:2rem }.location-detail header p { margin:.2rem 0 .8rem; color:$muted; font:.8rem Arial,sans-serif }.location-description { color:$muted; font-size:1rem; line-height:1.45 }.location-actions { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:.7rem }.action-feedback { color:$green; font:700 .78rem Arial,sans-serif }.action-feedback.error{color:#9f4c4c}.section-title { display:flex; justify-content:space-between; margin:1.15rem 0 .55rem; padding-bottom:.3rem; border-bottom:1px solid rgba(72,49,34,.2); font-weight:700 }.section-title small{color:$muted;font:.72rem Arial,sans-serif}
.featured-grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:.8rem }.featured-photo { height:12rem; padding:.5rem; border:0; color:rgba(79,58,43,.55); background:#fffaf0; box-shadow:0 .25rem .65rem rgba(50,34,22,.16) }.featured-photo img { width:100%; height:100%; object-fit:cover }.featured-photo:disabled{opacity:.65}.album-grid { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:.8rem }.album-photo { position:relative; height:10rem; padding:.4rem; border:0; background:#fffaf0; box-shadow:0 .25rem .65rem rgba(50,34,22,.16) }.album-photo img { width:100%; height:100%; object-fit:cover }.cover-label { position:absolute; left:0; top:.8rem; padding:.25rem .55rem; color:#fff; background:$rose; font:700 .65rem Arial,sans-serif }.empty-album { padding:2.5rem; color:$muted; border:1px dashed rgba(79,58,43,.3); text-align:center }.preview-card { max-width:min(85vw,80rem); max-height:calc(100vh - 4rem); display:flex; flex-direction:column; gap:.7rem; padding:.7rem; background:#eee5d3 }.preview-card img { max-width:100%; max-height:calc(100vh - 8rem); object-fit:contain; background:#171513 }
.center-state { min-height:calc(100vh - 4rem); display:flex; flex-direction:column; align-items:center; justify-content:center; gap:.8rem; color:$muted }.spinner { width:1.8rem; height:1.8rem; display:inline-block; border:3px solid rgba(83,66,54,.2); border-top-color:$rose; border-radius:50%; animation:spin .8s linear infinite }.spinner.small{width:1rem;height:1rem;border-width:2px}@keyframes spin{to{transform:rotate(360deg)}}
@media(max-width:74rem){.location-layout{grid-template-columns:repeat(2,minmax(16rem,1fr));grid-template-rows:auto;grid-template-areas:'one two' 'three four' 'stamp five'}.book-header{grid-template-columns:auto 1fr auto}}
@media(max-width:48rem){.journal-screen{padding:0}.journal-book{min-height:100vh;border-width:.35rem;border-radius:0}.book-header{grid-template-columns:1fr;text-align:center}.xp-note{display:none}.location-layout{display:flex;flex-direction:column;min-height:auto;padding:1rem}.location-card{transform:none}.map-stamp{order:6;margin:1rem}.detail-backdrop{padding:.5rem}.location-detail{width:100%;max-height:calc(100vh - 1rem)}.featured-grid,.album-grid,.location-actions{grid-template-columns:1fr}}
</style>
