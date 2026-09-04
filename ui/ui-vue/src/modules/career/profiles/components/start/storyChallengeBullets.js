export function formatStoryMoney(amount) {
  const value = Number(amount)
  if (!Number.isFinite(value)) return "$0"
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  }).format(value)
}

export function formatStoryMapLabel(mapId, mapLabels = {}) {
  if (!mapId) return null
  if (mapLabels[mapId]) return mapLabels[mapId]
  return String(mapId)
    .split("_")
    .filter(Boolean)
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}

export function getStoryBullets(challenge, mapLabels = {}) {
  if (!challenge) return []

  const bullets = []
  bullets.push(`${formatStoryMoney(challenge.startingCapital ?? 10000)} starting cash`)

  if (challenge.winConditionName) {
    bullets.push(`Goal: ${challenge.winConditionName}`)
  }

  const mapLabel = formatStoryMapLabel(challenge.map, mapLabels)
  if (mapLabel) {
    bullets.push(mapLabel)
  } else {
    bullets.push("Any map")
  }

  if (challenge.hasLoans && Number(challenge.loanAmount) > 0) {
    bullets.push(`${formatStoryMoney(challenge.loanAmount)} starting debt`)
  }

  return bullets
}

export function mapStoryChallengeEntry(entry) {
  if (!entry) return null
  return {
    id: entry.id,
    name: entry.name,
    difficulty: entry.difficulty || "Medium",
    description: entry.description || "",
    shortDescription: entry.description || "",
    isLocal: entry.isLocal || false,
    startingCapital: entry.startingCapital ?? 10000,
    winConditionName: entry.winConditionName || null,
    map: entry.map || null,
    hasLoans: entry.hasLoans === true,
    loanAmount: entry.loanAmount || 0,
  }
}
