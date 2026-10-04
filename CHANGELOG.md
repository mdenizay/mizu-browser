# Changelog

## 0.3.0

For people who build and look after other people's sites.

- ⌘T opens a panel in the middle of the window to type where to go; ⌘K is a
  command palette (tabs, pages, every command); ⇧⌘P switches profile, or makes
  a new one from the name typed
- A profile per client: pin a client's tools (GitHub, Figma, Analytics,
  Search Console, Meta Ads…) from Settings → Profiles, and keep a client's
  accounts with the profile (in the macOS keychain; offered only there)
- Production, staging and development sites are labelled in the address bar
  and framed in colour; names are guessed (staging., localhost, *.vercel.app)
  and can be marked by hand
- Background tabs go to sleep after 15 minutes without use (Settings →
  General)
- Developer panel beside the page (⌥⌘D): SEO, accessibility, requests and
  blocked trackers, cookies and storage, broken links, fonts and colours of
  an element, a colour picker, and CSS to try on the page
- Device view: phones, tablets, 1280/1440/1920 and any size typed in, scaled
  to fit; sizes can be saved. Desktop and mobile side by side
- Screenshot of a single element; user agent presets (Googlebot, iPhone,
  Chrome on Windows…); a switch to bypass the cache
- Web Inspector now docks below the page, not above it
- In the narrow sidebar, profiles, downloads and the menu are at the bottom
  left, as in the wide one
- Popovers (the blocker's shield, downloads, sign-in) open right under their
  button instead of some way below it
- Development builds keep their settings apart from the installed app

## 0.2.0

- The sidebar collapses to a narrow strip of tab icons instead of
  disappearing (Settings → General can make it disappear again)
- With tabs on top, tabs and address now share a single row: the tab in front
  becomes the address field, as in Safari. The two-row arrangement is still
  there in Settings → General

## 0.1.0

The first release.

- Tabs in a sidebar or along the top; pinned tabs; named, coloured groups that
  fold away; drag to reorder
- Tabs you are not using are put to sleep and come back where you left them:
  the one in front is live, a few recent ones stay loaded, the rest cost
  nothing. When the Mac runs short of memory the loaded ones go to sleep too
- Profiles (Personal and Work to start with), each with its own cookies and
  site data, history, bookmarks, tabs and colours; private windows
- A colour field for the theme: drag a dot, add a second for a gradient
- Built-in ad and tracker blocking with Brave's adblock-rust: EasyList,
  EasyPrivacy, uBlock filters, AdGuard Tracking Protection and optional
  Turkish and cookie-banner lists; per-site switch in the address bar
- Passwords from the Passwords app: the key in the address bar fills the
  sign-in form of the page
- For developers: Web Inspector, mobile view with device presets, full-page
  screenshots, view source, switch JavaScript off, clear a site's data
- Downloads, history, bookmarks, find in page, zoom, print and save as PDF
- English and Turkish
- Updates itself from GitHub releases
