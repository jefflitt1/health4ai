---
title: "health4ai 1.0.2: Google Sheets by Default"
description: "What changed in health4ai 1.0.1 and 1.0.2: Save to Google Sheets, Sync History, Your Sources, a Sheet-first first run, and better handling of iOS 27 limited Health access."
pubDate: 2026-10-07
slug: "health4ai-1-0-2-google-sheets-default"
tags: ["release", "google-sheets", "ios-27", "healthkit", "health4ai"]
draft: true
---

# health4ai 1.0.2: Google Sheets by Default

health4ai is a free iOS app that moves your Apple Health data to a destination you own. Version 1.0.1 added a second destination, a Google Sheet in your own Google Drive. Version 1.0.2 makes that Sheet the default for new installs and smooths over a few things that iOS 27 made more confusing.

This post covers both releases, what they mean in practice, and who each destination suits.

## The short version

- New installs of 1.0.2 start with Google Sheets as the destination.
- If you already use health4ai, your destination does not change.
- The first-run flow is Sheet-first and stays readable at large text sizes.
- On iOS 27, if you granted only "Past 30 Days and Future Data" and later widen access, database users now get the hidden history re-imported automatically.

## Where your data goes

health4ai has no account and no server. It never receives your health data. You pick one of two destinations, and both belong to you.

**A Google Sheet.** One row per day: steps, sleep, heart rate, HRV, workouts and more. The sheet lives in your own Google Drive. The app asks for the `drive.file` scope, which means it can only see files it created itself. It cannot browse the rest of your Drive. The first sync backfills up to 10 years of history. One real account ended up with 3,653 days in a single sheet.

**Your own Postgres or Supabase database.** Every HealthKit sample, not a daily summary. Because it is a normal database, any MCP client can query it, including Claude Desktop, Claude Code and Cursor. This is the path for people who want raw samples and SQL.

The app is open source, so you can read what it does with your data. For the longer explanation see [how it works](/how-it-works/) and the [privacy page](/privacy/).

## What 1.0.1 added

Version 1.0.1 is already live. The changes:

- **Save to Google Sheets.** The new destination described above.
- **Sync History.** A log of every sync, including the ones that ran while the app was closed. If you wonder whether a sync happened, this is where you look.
- **Your Sources.** A list of every device and app writing to Apple Health, not only Apple Watch. Useful when two sources report the same metric and you want to know who is contributing what.
- **A setup checklist.** It shows what is done and what is left.
- **Connect Your AI.** A copy-paste MCP configuration for the database path, so you do not have to hand-write the JSON.
- **A warning about limited Health sharing.** If iOS is only sharing recent Health data with the app, health4ai says so. More on that below.
- **A simpler first screen.**

## What 1.0.2 changes

Version 1.0.2 is about to be submitted to Apple and is not live yet. This post stays unpublished until it is approved.

**Google Sheet is the default for new installs.** Most people who want their Health data somewhere usable want a spreadsheet, not a database server. Starting there means fewer steps before the first sync. Existing users keep whatever destination they already chose. Nothing is migrated behind your back.

**Sheet-first onboarding.** The first-run screens now lead with the Sheet path. The database path is still there for people who want it. The screens are also readable at large text sizes.

**Better handling of iOS 27 limited access.** iOS 27 lets you share only the last 30 days of Health data with an app. If you later switch to all data:

- The Sheet rebuilds itself when access widens. That part already shipped in 1.0.1.
- Database users get the hidden history re-imported automatically. This applies if you widen access after installing 1.0.2. If you widened it earlier, that is not covered.
- The notice tells you where to change the setting: iOS Settings or the Health app.

The background on why this happens, and how to fix it for any app, is in [why your Apple Health export only shows 30 days on iOS 27](/blog/apple-health-export-only-30-days-ios-27/).

## Which destination should you pick?

Pick the **Google Sheet** if you want to open your data in a spreadsheet, make charts, hand a CSV to an AI assistant, or compare one week to another. It needs a Google account and nothing else.

Pick **your own database** if you want every sample, want to run SQL, or want an AI client to query your history directly through MCP. It needs a Postgres or Supabase database you control. The [setup page](/setup/) walks through it.

For a step-by-step Sheet walkthrough, see [Apple Health to Google Sheets with health4ai](/blog/apple-health-to-google-sheets-health4ai/).

## An honest note on background sync

Background sync is best effort. iOS decides when an app gets to run, and that can be minutes or hours. health4ai does not promise real-time updates. Opening the app is the reliable way to nudge a sync, and Sync History shows what actually happened.

## Get it

health4ai is free on the App Store: [apps.apple.com/app/health4ai/id6783074944](https://apps.apple.com/app/health4ai/id6783074944).

Version 1.0.1 has everything in the first half of this post today. Version 1.0.2 follows once Apple approves it.
