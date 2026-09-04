Phone app manifests are auto-discovered by `phoneAppRegistry.js`.

To add a new app without editing `PhoneHomescreen.vue`:

1. Create a new file in this folder, e.g. `my-app.js`.
2. Export a default manifest object:

```js
import { icons } from '@/common/components/base'

export default {
  id: 'my-app',
  name: 'My App',
  // Option A: built-in vector icon
  icon: icons.cars,
  // Option B: custom image icon (full tile art) from `tiles/`
  // iconTile: 'my-app.png',
  // Option C: fully custom image path/URL
  // iconImage: '/local/ui/ui-vue/some/path/my-app.png',
  // iconImageFit: 'cover', // optional: 'cover' (default) | 'contain'
  // iconImageOverlay: false, // optional: adds default dark gradient when true
  route: '/career/phone-my-app',
  color: '#3366ff',
  iconColor: '#ffffff',
  category: 'Tools',
  defaultPage: 0,
  defaultPosition: 9,
  // Optional:
  // defaultDock: 0..3,
  // unlockCondition: async (luaBridge) => true/false  — gates app usage + notifications
  // showInStoreWhenLocked: true — skill-gated apps only; list in App Store during career before unlock
  // lockedMessage: 'Unlock skill to use this app'
  // storeTagline: 'Short line on the store list row'
  // storeDescription: 'Full paragraph on the app detail sheet in the App Store'
}
```

Custom icon example:

```js
import myIconPng from '../images/my-app.png'

export default {
  id: 'my-app',
  name: 'My App',
  iconImage: myIconPng,
  iconImageFit: 'cover',
  route: '/career/phone-my-app',
  color: '#222222',
}
```

Tile filename convention (recommended):

```js
export default {
  id: 'my-app',
  name: 'My App',
  iconTile: 'my-app.png', // resolved to /ui/entrypoints/main/tiles/my-app.png
  route: '/career/phone-my-app',
}
```

Place tile files in:

`ui/entrypoints/main/tiles/`

Note: You still need a matching route/view for `route`.

---

## Notifications

Phone notifications are OS-level. Feature code only calls `ui_phone_layout.fireNotification` — no per-app install hooks.

**Gates (in order):**

1. App **installed** on the phone (`installedAppIds`)
2. App **usage-unlocked** (`unlockCondition` on the manifest — same check as app content)
3. Per-channel toggle (Settings → Notifications)
4. Master mute

If the app is not installed yet, the payload is **queued** in `phoneLayout.json` and flushed when the player installs that app from the App Store.

### Step 1 — Declare channels in the app manifest

```js
notifications: [
  {
    key: 'myApp.somethingHappened', // camelCase namespace: myApp.channelName
    label: 'Something Happened',
    default: true,                  // omit or true = on by default; false = off by default
    description: 'Shown when ...',  // optional, Settings UI
    order: 0,                       // optional sort in Settings
  },
],
```

See `car-meet.js` and `racing-team.js` for real examples.

`phoneNotificationRegistry.js` auto-discovers these for **Settings → Notifications**.

### Step 2 — Map channel → app id in Lua

In `lua/ge/extensions/ui/phone/layout.lua`, add to `NOTIFICATION_CHANNEL_APP_IDS`:

```lua
["myApp.somethingHappened"] = "my-app",
```

Keep in sync with the manifest `id`. Lua uses this for install gating and the defer queue.

### Step 3 — Fire from gameplay (Lua)

Always go through the phone dispatcher:

```lua
local layout = ui_phone_layout
if not layout and extensions and extensions.load then
  pcall(extensions.load, "ui_phone_layout")
  layout = ui_phone_layout
end
if layout and layout.fireNotification then
  layout.fireNotification("myApp.somethingHappened", {
    title = "Headline",
    message = "Body text",
    kind = "info",           -- optional UI hint
    ttl = 8,                 -- optional seconds on lock screen
    source = "My App",       -- used for Settings auto-discovery label
    sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" },
  })
end
```

**Do not:**

- Call `guihooks.trigger("PhoneLockNotification", ...)` directly from features
- Add `onPhoneAppInstalled` hooks for catch-up — the install defer queue handles that

**Optional:** `opts.fallback` when guihooks are unavailable; `opts.appId` if the channel is not in `NOTIFICATION_CHANNEL_APP_IDS`.

### Checklist for a new notification

| Step | Where |
|------|--------|
| `notifications[]` on manifest | `apps/manifests/<app-id>.js` |
| Channel → app id map | `lua/ge/extensions/ui/phone/layout.lua` → `NOTIFICATION_CHANNEL_APP_IDS` |
| Fire when event happens | Your feature `.lua` → `layout.fireNotification(...)` |
| UI build (manifest changed) | `build_ui.bat` |
| Lua reload | Career reload (Lua-only changes need no UI rebuild) |

### Skill-gated apps + notifications

- Use `showInStoreWhenLocked: true` + `unlockCondition` on the manifest (see optional fields above).
- Notification channels appear in Settings only when the app is **installed** and **usage-unlocked**.
- Gameplay can call `fireNotification` anytime; if the app is not installed, it queues until install.
