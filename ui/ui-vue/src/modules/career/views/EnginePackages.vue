<template>
  <ComputerWrapper title="Engine Packages" @back="close">
    <ComputerPanel
      class="engine-panel"
      v-bng-blur="1"
      heading="Engine Packages"
    >
      <div class="engine-body">
        <div v-if="message" class="banner" :class="message.success ? 'ok' : 'bad'">
          {{ message.message }}
        </div>

        <div v-if="data.busy" class="banner">Updating engine package…</div>

        <div class="engine-list" v-bng-ui-nav-scroll>
          <div v-if="!data.currentPackageId && data.hasInstalledEngine" class="create-block">
            <div class="create-copy">
              <span class="item-name">Package the installed engine</span>
              <span class="item-meta">The engine stays installed until you swap it. A thumbnail is captured from the isolated engine.</span>
            </div>
            <BngInput
              v-model="createName"
              label="Package name (optional)"
              floating-label
              :disabled="data.busy"
              v-bng-text-input
              @focus="onInputFocus"
              @blur="onInputBlur"
              @keydown.stop="handleCreateKeydown"
            />
            <BngButton
              :accent="ACCENTS.primary"
              :disabled="data.busy"
              @click="createPackage"
            >
              Create Package
            </BngButton>
          </div>

          <div v-else-if="data.currentPackageId" class="banner">
            The installed engine is already tracked as a package. Installing another package will store it automatically.
          </div>

          <div v-else-if="!data.hasInstalledEngine" class="banner">
            No engine is installed. Install a compatible stored package below, or use Part Customization to build another engine.
          </div>

          <div
            v-for="pkg in data.packages"
            :key="pkg.id"
            class="package-card"
            :class="{ selected: pkg.id === data.currentPackageId }"
          >
            <div class="preview">
              <AspectRatio
                :ratio="'16:9'"
                :external-image="thumbUrl(pkg)"
                image-mode="contain"
                class="preview-image"
              >
                <div v-if="!thumbUrl(pkg)" class="no-thumb">No thumbnail yet</div>
                <div class="indicators-overlay">
                  <BngCondition :integrity="pkg.integrity || 0" color="#ccc" show-tooltip />
                  <span class="item-status" :class="statusTone(pkg)">{{ statusLabel(pkg) }}</span>
                </div>
              </AspectRatio>
            </div>

            <div class="content">
              <div class="header">
                <div class="title-section">
                  <div class="name">{{ pkg.name }}</div>
                  <div class="item-meta">{{ pkg.installedVehicleName || pkg.rootEngineNiceName }}</div>
                </div>
              </div>

              <div v-if="renameId === pkg.id" class="rename-row">
                <BngInput
                  v-model="renameName"
                  label="Package name"
                  floating-label
                  :disabled="data.busy"
                  v-bng-text-input
                  @focus="onInputFocus"
                  @blur="onInputBlur"
                  @keydown.stop="handleRenameKeydown($event, pkg)"
                />
                <div class="item-actions">
                  <BngButton
                    :accent="ACCENTS.primary"
                    :disabled="data.busy || !renameName.trim()"
                    @click="commitRename(pkg)"
                  >
                    Save
                  </BngButton>
                  <BngButton :disabled="data.busy" @click="cancelRename">Cancel</BngButton>
                </div>
              </div>

              <div v-else class="details">
                <div class="stat-row"><span>Parts</span><strong>{{ pkg.partCount }}</strong></div>
                <div class="stat-row"><span>Condition</span><strong>{{ conditionPercent(pkg) }}%</strong></div>
                <div class="stat-row"><span>Mileage</span><strong>{{ formatDistance(pkg.odometer) }}</strong></div>
              </div>

              <div
                v-if="pkg.status === 'stored'"
                class="compat"
                :class="pkg.compatible ? 'ok' : 'bad'"
              >
                {{ pkg.compatible ? "Compatible" : pkg.compatibilityReason || "Not compatible" }}
              </div>
              <div v-else-if="pkg.status === 'incomplete'" class="compat bad">
                Package cannot be installed. One or more original inventory parts are unavailable.
              </div>

              <div v-if="confirmDismantleId !== pkg.id" class="item-actions">
                <BngButton
                  v-if="pkg.status === 'stored'"
                  :accent="ACCENTS.primary"
                  :disabled="!pkg.canInstall || data.busy"
                  @click="installPackage(pkg)"
                >
                  Install
                </BngButton>
                <BngButton
                  v-if="pkg.canStore"
                  :accent="ACCENTS.primary"
                  :disabled="data.busy"
                  @click="storePackage(pkg)"
                >
                  Store
                </BngButton>
                <BngButton
                  v-if="renameId !== pkg.id"
                  :disabled="data.busy"
                  @click="startRename(pkg)"
                >
                  Rename
                </BngButton>
                <BngButton
                  :accent="ACCENTS.attention"
                  :disabled="data.busy"
                  @click="askDismantle(pkg)"
                >
                  Dismantle
                </BngButton>
              </div>

              <div v-else class="dismantle-confirm">
                <span>Dismantle this package? Its parts will return to My Parts.</span>
                <div class="item-actions">
                  <BngButton
                    :accent="ACCENTS.attention"
                    :disabled="data.busy"
                    @click="dismantlePackage(pkg)"
                  >
                    Dismantle
                  </BngButton>
                  <BngButton :disabled="data.busy" @click="cancelDismantle">Cancel</BngButton>
                </div>
              </div>
            </div>
          </div>

          <div v-if="!data.packages.length && !data.busy" class="banner">
            No engine packages yet. Create one from the engine currently installed in this vehicle.
          </div>
        </div>
      </div>
    </ComputerPanel>
  </ComputerWrapper>
</template>

<script setup>
import { onBeforeUnmount, onMounted, ref } from "vue"
import { ACCENTS, BngButton, BngCondition, BngInput } from "@/common/components/base"
import { AspectRatio } from "@/common/components/utility"
import { vBngBlur, vBngTextInput, vBngUiNavScroll } from "@/common/directives"
import { useBridge } from "@/bridge"
import ComputerPanel from "../components/ComputerPanel.vue"
import ComputerWrapper from "./ComputerWrapper.vue"

const { events, lua } = useBridge()

const data = ref({
  busy: false,
  currentInventoryId: null,
  currentPackageId: null,
  hasInstalledEngine: false,
  packages: [],
})
const message = ref(null)
const createName = ref("")
const renameId = ref(null)
const renameName = ref("")
const confirmDismantleId = ref(null)

let messageTimer = null
let inputFocused = false

function onInputFocus() {
  inputFocused = true
  try {
    lua.setCEFTyping(true)
  } catch (_) {}
}

function onInputBlur() {
  inputFocused = false
  try {
    lua.setCEFTyping(false)
  } catch (_) {}
}

function handleCreateKeydown(event) {
  if (event.key !== "Enter") return
  event.preventDefault()
  createPackage()
}

function handleRenameKeydown(event, pkg) {
  if (event.key === "Enter") {
    event.preventDefault()
    commitRename(pkg)
  } else if (event.key === "Escape") {
    event.preventDefault()
    cancelRename()
  }
}

function updateData(payload) {
  data.value = {
    busy: false,
    currentInventoryId: null,
    currentPackageId: null,
    hasInstalledEngine: false,
    ...(payload || {}),
    packages: Array.isArray(payload?.packages) ? payload.packages : [],
  }
}

function handleResult(payload) {
  message.value = payload || null
  if (payload?.success) {
    createName.value = ""
    renameId.value = null
    renameName.value = ""
    confirmDismantleId.value = null
    clearTimeout(messageTimer)
    messageTimer = setTimeout(() => {
      message.value = null
    }, 3500)
  }
}

async function requestData() {
  const result = await lua.career_modules_enginePackages.requestData()
  if (result) updateData(result)
}

async function close() {
  if (data.value.busy) return
  await lua.career_modules_enginePackages.closeMenu()
}

function createPackage() {
  if (data.value.busy || data.value.currentPackageId) return
  lua.career_modules_enginePackages.createFromCurrent(createName.value)
}

function startRename(pkg) {
  if (data.value.busy) return
  renameId.value = pkg.id
  renameName.value = pkg.name
  confirmDismantleId.value = null
}

function cancelRename() {
  renameId.value = null
  renameName.value = ""
}

function commitRename(pkg) {
  if (data.value.busy || !renameName.value.trim()) return
  lua.career_modules_enginePackages.renamePackage(pkg.id, renameName.value)
}

function installPackage(pkg) {
  if (data.value.busy || !pkg.canInstall) return
  confirmDismantleId.value = null
  lua.career_modules_enginePackages.installPackage(pkg.id)
}

function storePackage(pkg) {
  if (data.value.busy || !pkg.canStore) return
  confirmDismantleId.value = null
  lua.career_modules_enginePackages.storeInstalledPackage(pkg.id)
}

function askDismantle(pkg) {
  if (data.value.busy) return
  confirmDismantleId.value = pkg.id
  renameId.value = null
}

function cancelDismantle() {
  confirmDismantleId.value = null
}

function dismantlePackage(pkg) {
  if (data.value.busy) return
  lua.career_modules_enginePackages.dismantlePackage(pkg.id)
}

function statusLabel(pkg) {
  if (pkg.status === "stored") return "Stored"
  if (pkg.status === "installed") return "Installed"
  return "Incomplete"
}

function statusTone(pkg) {
  if (pkg.status === "installed") return "ok"
  if (pkg.status === "incomplete") return "bad"
  if (pkg.status === "stored" && pkg.compatible === false) return "warn"
  return "unknown"
}

function conditionPercent(pkg) {
  return Math.max(0, Math.min(100, Math.round(Number(pkg.integrity || 0) * 100)))
}

function formatDistance(metres) {
  const miles = Number(metres || 0) / 1609.344
  return `${Math.round(miles).toLocaleString()} mi`
}

function thumbUrl(pkg) {
  return pkg?.thumbnail ? `${pkg.thumbnail}?${pkg.dirtyDate || 0}` : null
}

onMounted(() => {
  events.on("enginePackagesData", updateData)
  events.on("enginePackagesActionResult", handleResult)
  requestData()
})

onBeforeUnmount(() => {
  events.off("enginePackagesData", updateData)
  events.off("enginePackagesActionResult", handleResult)
  clearTimeout(messageTimer)
  if (inputFocused) onInputBlur()
})
</script>

<style scoped lang="scss">
.engine-panel {
  --bng-card-height: 100%;
  width: 60em;
  max-width: 100%;
  height: 100%;
  overflow: hidden;

  &:deep(.panel-content) {
    flex: 1 1 0;
    min-height: 0;
    overflow: hidden;
  }
}

.engine-body {
  display: flex;
  flex-direction: column;
  min-height: 0;
  height: 100%;
  overflow: hidden;
  color: white;
}

.engine-list {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  padding: 0.25rem 0.6rem 0.75rem;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.banner {
  margin: 0;
  padding: 0.6rem 0.75rem;
  border-radius: 0.5rem;
  background: rgba(255, 255, 255, 0.06);
  color: rgba(255, 255, 255, 0.82);
  font-size: 0.9rem;

  &.ok {
    background: rgba(40, 153, 83, 0.18);
    color: #9edb8f;
  }

  &.bad {
    background: rgba(160, 33, 33, 0.8);
    color: #fff;
  }
}

.create-block {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  padding: 0.7rem 0.65rem;
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 0.5rem;
  background: rgba(255, 255, 255, 0.03);
}

.create-copy {
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
}

.package-card {
  display: flex;
  flex-flow: row nowrap;
  align-items: stretch;
  padding: 0.5em;
  box-sizing: border-box;
  background-color: rgba(0, 0, 0, 0.6);
  color: #fff;
  border-radius: var(--bng-corners-1);
  border: 1px solid rgba(255, 255, 255, 0.1);
  gap: 0.25em;

  &:hover {
    background-color: rgba(var(--bng-cool-gray-700-rgb), 0.8);
  }

  &.selected {
    padding-left: 1em;
    border-left: 0.5em solid #f60;
  }
}

.preview {
  position: relative;
  flex: 0 0 18rem;
  width: auto;
  height: auto;
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  overflow: hidden;
  border-radius: var(--bng-corners-1);
  background-color: rgba(0, 0, 0, 0.3);

  .preview-image {
    width: 100%;
    height: 100%;
  }

  .no-thumb {
    color: rgba(255, 255, 255, 0.55);
    font-size: 0.85rem;
    font-weight: 600;
    text-align: center;
    text-shadow: 0 0 0.4em #000;
  }
}

.indicators-overlay {
  position: absolute;
  bottom: 0.5em;
  left: 0.5em;
  display: flex;
  align-items: center;
  gap: 0.5em;
  z-index: 10;
  background-color: rgba(0, 0, 0, 0.7);
  padding: 0.25em 0.5em;
  border-radius: var(--bng-corners-1);
}

.content {
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  padding: 0.35em 0.75em 0.25em;
  min-width: 0;
  overflow: hidden;
  gap: 0.4rem;
}

.header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
}

.title-section {
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
}

.name {
  font-size: 1.25em;
  font-weight: 700;
  white-space: nowrap;
  text-overflow: ellipsis;
  overflow: hidden;
  max-width: 100%;
}

.item-name {
  display: block;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.item-meta {
  color: rgba(255, 255, 255, 0.55);
  font-size: 0.78rem;
  font-weight: 400;
}

.item-status {
  font-size: 0.85rem;
  font-weight: 700;
  white-space: nowrap;

  &.ok { color: #9edb8f; }
  &.warn { color: #ebc140; }
  &.bad { color: #ff7777; }
  &.unknown { color: rgba(255, 255, 255, 0.55); font-weight: 600; }
}

.details {
  display: flex;
  flex-direction: column;
  gap: 0.15rem;
}

.stat-row {
  display: flex;
  justify-content: space-between;
  gap: 0.75rem;
  color: rgba(255, 255, 255, 0.7);
  font-size: 0.88rem;

  strong {
    color: white;
    font-weight: 600;
  }
}

.compat {
  font-size: 0.85rem;

  &.ok { color: #9edb8f; }
  &.bad { color: #ff7777; }
}

.item-actions {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.4rem;
}

.item-actions :deep(.bng-button),
.item-actions :deep(button) {
  width: 100%;
}

.rename-row {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
}

.dismantle-confirm {
  display: flex;
  flex-direction: column;
  gap: 0.4rem;
  color: #ffc2c2;
  font-size: 0.88rem;
}
</style>
