---
title: "health4ai 1.0.4: Choose What Goes in Your Google Sheet, Plus a Sleep Stages Tab"
description: "health4ai 1.0.4 (submitted to App Review) lets you choose what your Google Sheet keeps, adds a Sleep stages tab, and keeps Sheets sync going when Apple Health refuses to read a day."
pubDate: 2026-10-20
slug: "health4ai-1-0-4-what-to-save-sleep-stages"
tags: ["release", "google-sheets", "sleep", "healthkit", "health4ai"]
draft: false
---

health4ai 1.0.4 has been submitted to the App Store and is in App Review. It is not available yet, and Apple decides when it goes live. This post describes what is in it so you know what to expect. The App Store listing is the place to check whether it has shipped.

health4ai is a free iOS app that writes your Apple Health data to a Google Sheet in your own Google Drive, or to a database you own. Version 1.0.4 is about the Google Sheet.

## The short version

- **What to save.** Choose which data your Sheet keeps. The daily summary is always saved. Workouts and Sleep stages each have a switch.
- **A Sleep stages tab.** One row for each stretch of sleep, with its stage, start, end and the device that recorded it.
- **Sync keeps going when Apple Health refuses a day.** The refused days are named in the app and filled in on a later sync. See [the error explained](/blog/unable-to-invalidate-interval-no-data-source-available/).

## What to save

The Google Sheets screen in 1.0.4 has a new **What to save** section.

- **Daily summary** is always on. It is the one-row-per-day tab: steps, sleep, heart rate, HRV and more.
- **Workouts** has a switch. It controls the tab with one row per workout. Turning it back on fills in the workouts you missed while it was off.
- **Sleep stages** has a switch and is off by default.

Turning a switch off stops new rows from being added. It never deletes rows that are already in your Sheet. While a tab is filling, the app shows "Filling..." under its switch.

Sync History also changed. Days, workouts and sleep records now appear on separate lines, and syncs that follow a change to your choices are labelled "You chose what to save".

## The Sleep stages tab

The daily summary tells you how long you slept. The Sleep stages tab shows the night itself: one row for each stretch of sleep, with these columns.

| Column | What it holds |
|---|---|
| Night | The date you woke up |
| Stage | In bed, awake, core, deep or REM |
| Start | When the stretch began |
| End | When it ended |
| Duration (min) | Length in minutes |
| Source | The device that recorded it |
| Record ID | Used to skip duplicates |

Turn it on and your past nights fill in too, going back as far as Apple Health has sleep records, up to ten years. The last 7 nights are re-read on every sync, so a ring or watch that reaches Apple Health a night late still gets added. Duplicates are skipped, and if you delete the tab, the next sync adds it back.

Two honest limits. Sleep that reaches Apple Health more than 7 nights late is not added. And core, deep and REM stages only exist if your watch or ring records them.

What can you do with it? Chart deep and REM minutes by week, compare nights by device when you wear both a watch and a ring, or hand the tab to an AI assistant and ask how your sleep structure changed. For the stages themselves, see [sleep stage analysis with Apple Health data](/blog/sleep-stage-analysis-apple-health/).

## When Apple Health refuses to read a day

Some people, mostly those with long histories from several devices, hit an Apple Health error that used to stop the Sheets sync. In 1.0.4, health4ai carries on, names the refused days on the Sheets card and in Sync History, and fills them in when Apple Health answers. Values your Sheet already holds are never blanked. The full explanation is in [Unable to invalidate interval: no data source available](/blog/unable-to-invalidate-interval-no-data-source-available/).

## Privacy and permissions

Nothing changes here. health4ai still has no account and no server, still sees only the files it creates in your Drive (the `drive.file` scope), and the sleep data was already being read for the daily summary. See the [privacy page](/privacy/).

## Getting it

Once 1.0.4 is live, update from the App Store and your Sheet keeps working as it is. If you are new, the [Google Sheets walkthrough](/blog/apple-health-to-google-sheets-health4ai/) covers setup, and [what changed in 1.0.1 and 1.0.2](/blog/health4ai-1-0-2-google-sheets-default/) covers the earlier releases. The app is free: [apps.apple.com/app/health4ai/id6783074944](https://apps.apple.com/app/health4ai/id6783074944).
