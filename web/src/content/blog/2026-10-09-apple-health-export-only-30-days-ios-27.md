---
title: "Why Your Apple Health Export Only Shows 30 Days on iOS 27"
description: "iOS 27 lets you share only the past 30 days of Health data with an app. Here is how to spot it, how to fix it for any app, and how health4ai handles it."
pubDate: 2026-10-09
slug: "apple-health-export-only-30-days-ios-27"
tags: ["ios-27", "healthkit", "apple-health", "troubleshooting", "health4ai"]
draft: false
---

# Why Your Apple Health Export Only Shows 30 Days on iOS 27

You connect a health app, run an export, and the data starts about a month ago. You have years of history in Apple Health, so something looks wrong. On iOS 27 the cause is probably not a bug in the app. It is a permission you granted, possibly without noticing.

## What changed in iOS 27

iOS 27 lets you give an app limited Health access: **Past 30 Days and Future Data**. If you choose that option, the app can read samples from roughly the last 30 days and anything recorded afterward. It cannot see anything older. For that app, your earlier history does not exist.

This is a reasonable privacy feature. The side effect is confusing: an export or backfill from that app looks like it begins about 30 days before the day you granted access, and then continues normally.

## How to tell it is this

- The earliest date in the export is close to 30 days before you first connected the app.
- Everything after that date looks fine and keeps updating.
- Apple Health itself still shows years of data.

If all three are true, the app is probably working. It is just not allowed to look further back.

## How to fix it

You change the permission, and then the app needs to fetch history again.

1. Open **Settings**, go to **Privacy & Security**, then **Health**, and choose the app. Alternatively, open the **Health** app, tap your profile picture, and look under **Apps** for the app.
2. Look for the data access option and choose all data instead of the past 30 days.
3. Return to the app and trigger a sync, or wait for the next one.

I am deliberately not quoting exact button labels, since Apple words them differently between versions. Look for the data access choice and pick all recorded data.

Step 3 depends on the app. Some apps notice the change and fetch the older history themselves. Others only pick up new samples and need a reset or a re-export. If an app keeps showing only 30 days after you widen access, check its documentation or support.

## This applies to every Health app

Nothing here is specific to one product. Any app that reads HealthKit can hit the limit: fitness trackers, sleep apps, coaching apps, and export tools. If a metric seems to start suddenly one month back, check the permission first.

## What health4ai does about it

health4ai moves Health data to a Google Sheet in your own Drive or to your own Postgres or Supabase database. Because limited access makes data look missing, the app handles it in two ways.

**It warns you.** Since version 1.0.1, health4ai tells you when iOS is sharing only recent Health data, so you do not have to guess from the dates.

**It repairs the destination when you widen access.**

- For Google Sheets, the sheet rebuilds itself when access widens. That has been true since 1.0.1.
- For database users, version 1.0.2 re-imports the hidden history automatically when you widen access, as long as you widen it after installing 1.0.2. Version 1.0.2 is not live yet. Until it is, database users should not assume older history will appear on its own after widening access.
- The notice also tells you where to change the setting: iOS Settings or the Health app.

A rebuild can take a little while for a long history. The first sync can backfill up to 10 years of data, and one real account reached 3,653 days. Sync History in the app shows when the work finished.

Background sync is best effort, and iOS chooses when it runs. Opening the app is the dependable way to prompt a catch-up.

## A quick checklist

- Is the earliest row about 30 days before you connected the app? It is likely limited access.
- Change the app's Health data access to all data in Settings or the Health app.
- Sync again and look at the earliest date.
- If the date has not moved, check that specific app's behavior.

For a walkthrough of getting daily Health data into a spreadsheet, see [Apple Health to Google Sheets with health4ai](/blog/apple-health-to-google-sheets-health4ai/). For the database route, see the [setup page](/setup/), and for what the app does and does not see, the [privacy page](/privacy/).

health4ai is free on the App Store: [Download on the App Store](https://apps.apple.com/app/health4ai/id6783074944).
