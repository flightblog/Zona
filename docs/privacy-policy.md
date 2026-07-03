---
title: Zona — Privacy Policy
description: How the Zona indoor-cycling app handles your data.
---

# Zona Privacy Policy

**Last updated: 3 July 2026**

Zona is a personal indoor-cycling app for iOS and macOS. It holds a smart trainer
at a steady power while you aim for a target heart-rate zone, records the ride, and
keeps a history.

This policy explains what data Zona touches and where it goes. The short version:
**Zona runs entirely on your device. There is no Zona server, and Zona does not
collect, transmit to us, sell, or share your personal data.** The developer of Zona
never receives your data.

## Who this covers

Zona is a single-user application that you install and run on your own devices. The
"we"/"us" in this policy refers to the developer of Zona, who operates **no
backend service** and has **no access** to any data described below.

## Data Zona handles, and where it stays

### On-device ride and fitness data

Your FTP, heart-rate settings, and recorded rides (power, heart rate, cadence,
speed, and heart-rate-variability samples) are created and stored **on your
device** using Apple's SwiftData.

If you have iCloud enabled, this ride data syncs across **your own** Apple devices
through **your private iCloud (CloudKit) database**. This uses Apple's iCloud
infrastructure under your Apple ID; it is governed by
[Apple's Privacy Policy](https://www.apple.com/legal/privacy/). The developer of
Zona cannot see this data.

### Bluetooth sensors

Zona connects to your smart trainer and heart-rate monitor over Bluetooth to
control the trainer and read live metrics. This communication is **local, directly
between your device and your sensors**. Nothing from it is sent off your device by
Zona.

### WHOOP (optional)

If you choose to connect WHOOP, Zona uses WHOOP's official API, with your explicit
authorization, to read two things:

- your **maximum heart rate** (body-measurement data), and
- your **resting heart rate** (recovery data).

Zona uses these solely to reconstruct your personal heart-rate training zones on
your device. The request goes **directly from your device to WHOOP's servers** —
never through any server operated by Zona. WHOOP's handling of your data is
governed by [WHOOP's Privacy Policy](https://www.whoop.com/privacy/policy/).

Your WHOOP access is stored as an OAuth token kept **only in your device's
Keychain**. It does not sync to other devices and is not shared. You can revoke it
at any time by tapping **Disconnect WHOOP** in the app (which deletes the token
from your device), and/or by removing Zona's access in your WHOOP account settings.

### Strava (optional)

If you choose to upload a ride to Strava, Zona sends **only that ride's file**,
with your explicit authorization, **directly from your device to Strava**. As with
WHOOP, the OAuth token is stored only in your device's Keychain and can be
disconnected at any time. Strava's handling of your data is governed by
[Strava's Privacy Policy](https://www.strava.com/legal/privacy).

## What Zona does *not* do

- Zona has **no analytics, tracking, or advertising** SDKs.
- Zona does **not** send your data to the developer or to any third party other
  than the services you explicitly connect (WHOOP, Strava) or use (Apple iCloud).
- Zona does **not** sell or rent your data to anyone.

## Data retention and deletion

Because your data lives on your device (and, if enabled, in your private iCloud):

- Delete individual rides from the app's History screen.
- Disconnect WHOOP or Strava in the app to delete the stored token for that
  service.
- Uninstalling Zona removes its on-device data. iCloud-synced rides can be removed
  by deleting the app's data in your iCloud settings.

## Children

Zona is not directed to children and does not knowingly collect data from anyone.

## Changes to this policy

If this policy changes, the "Last updated" date above will change and the revised
policy will be published at this URL.

## Contact

Questions about this policy can be sent to **foster@flightblog.org**.
