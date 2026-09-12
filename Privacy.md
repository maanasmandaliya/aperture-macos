# Privacy

Aperture is a local-first utility. This document describes exactly what it
reads, what it stores, and what it sends. The short version: it sends nothing
about you, and makes exactly one kind of request — for a cover image.

## What leaves your Mac

**Album artwork requests, and nothing else.** When the playback source is
Spotify or Safari, the cover art is published as a URL rather than as image
data, so Aperture downloads it. That is a plain unauthenticated GET for a
picture, to whichever host the source names — `i.scdn.co` for Spotify, or
whatever a page lists in its Media Session metadata. Apple Music and the demo
player need no request at all, because they hand over the image directly.

These requests carry nothing about you:

* an **ephemeral** URL session — no cookies, no credentials, no stored cache
* **HTTPS only**, and never to a loopback, link-local or private address. The
  Safari source takes its URL from whatever page is playing, so that address is
  treated as untrusted input rather than trusted because it arrived
* a 5-second timeout and a 4 MB ceiling; anything not served as an image is
  discarded
* results are cached in memory only, and a URL that fails is not retried

Aperture still contains no analytics SDK, no crash reporter, no telemetry, no
feature flags, no remote configuration, and no update checker. There is no
server of its own to talk to. If you would rather it made no requests at all,
choose Apple Music or the demo player as the source.

## Calendar

* Calendar access is **off by default**. Aperture does not create an
  `EKEventStore` request until you turn on *Show calendar events* in
  Settings ▸ Calendar.
* When enabled, Aperture reads events from the calendars you select (or all of
  them, if you select none) within your chosen look-ahead window.
* Event titles, times, locations and calendar colours are held in memory for as
  long as the app runs, and are used only to draw the overlay.
* Events are never written to disk, never logged, and never transmitted.
* You can revoke access at any time in System Settings ▸ Privacy & Security ▸
  Calendars. Aperture handles revocation by showing an explanatory empty state.

## Media

* The default media source is a **built-in demo player**. It invents its own
  track data and needs no permissions at all.
* If you select *Apple Music* as the source, Aperture sends AppleScript commands
  to the Music app to read the current track (title, artist, album, playback
  position, artwork) and to control playback. macOS asks for Automation
  permission the first time; Aperture never launches Music on its own, and only
  scripts it when it is already running.
* Track details stay in memory. Artwork is cached in memory only.
* Aperture does **not** use `MediaRemote` or any other private "now playing"
  framework.

## Notifications

Aperture does not read, mirror, or intercept other applications' notifications.
macOS provides no public API to do so, and Aperture uses no private API for it. The
notification HUD is driven exclusively by Aperture's own
`NotificationActivity` feed: its demo generator, and any producer an integrator
attaches through the documented `NotificationSource` extension point.

## System state

* **Audio** — Aperture reads and sets the default output device's volume and
  mute state through CoreAudio's public HAL properties. Nothing is recorded.
* **Brightness** — Aperture reads brightness only from displays that publish it
  through IOKit. It never captures screen contents.
* **Focus** — if you grant permission, Aperture asks `INFocusStatusCenter`
  whether *a* Focus is active. It cannot see which Focus, and does not ask.
* Aperture does not request Accessibility permission, Screen Recording
  permission, Input Monitoring permission, or Full Disk Access, and does not
  function as a keylogger of any kind. Its global shortcut uses Carbon's
  `RegisterEventHotKey`, which reports only that shortcut being pressed.

## What is stored on disk

Your preferences, in the standard macOS user defaults domain
`com.aperture.Aperture`. That covers the settings you see in the Settings
window: toggles, overlay scale, accent, look-ahead window, the identifiers of
the calendars you selected, and your keyboard shortcut. Nothing else is written.

To remove everything Aperture has stored:

```bash
defaults delete com.aperture.Aperture
```

## Login item

If you enable *Launch at login*, Aperture registers itself with
`SMAppService`. That registration is managed by macOS and visible to you in
System Settings ▸ General ▸ Login Items.
