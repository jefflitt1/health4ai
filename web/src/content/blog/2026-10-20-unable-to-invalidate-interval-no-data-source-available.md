---
title: "HealthKit Error: Unable to Invalidate Interval, No Data Source Available"
description: "What the HealthKit error 'Unable to invalidate interval: no data source available' means, why it stops some Apple Health syncs, and how health4ai 1.0.4 works around it for Google Sheets."
pubDate: 2026-10-20
slug: "unable-to-invalidate-interval-no-data-source-available"
tags: ["healthkit", "troubleshooting", "google-sheets", "apple-health", "health4ai"]
draft: false
---

If you searched for **"Unable to invalidate interval: no data source available"**, you have probably met this error in an app or in your own HealthKit code. It comes from Apple's HealthKit framework, with the error domain `com.apple.healthkit` and code 3. This post explains what it means, who gets it, and what to do.

## What the error means

The error is returned by a statistics query, typically `HKStatisticsCollectionQuery`, when HealthKit cannot resolve part of the requested time range to a data source. The wording says there is no data source for the interval, but the range often does have data. The query simply fails.

This is a known problem inside HealthKit, not a sign that your data or your device is broken. Developers have reported it to Apple, and there is no code-level fix on the app side.

## Who sees it

Reports cluster around people whose Health store has a long history from several devices, for example Apple Watch together with Oura, WHOOP and Withings. The more sources that have written to Health over the years, the more likely some stretch of time trips the query.

## Why it can stop a whole sync

An app that asks for a long range in one query gets one error for the whole range. If the app treats that as a failure, the sync fails on every pass, and everything after the refused day never arrives. That is what health4ai did before version 1.0.4: in one support report the Workouts tab kept syncing while the Daily tab stopped at an old date.

## What developers can do

Developers report that a shorter range with the same anchor often succeeds even when the long range fails. So the practical approach is to split the range and retry the pieces, down to single days, and report the days that still fail instead of treating them as a total failure.

## How health4ai 1.0.4 handles it

health4ai 1.0.4 is in App Review and is not available yet. When it ships, Google Sheets sync does this:

- It splits the range down to the days Apple Health refuses, so the other days are read normally. Only this specific error is handled this way. Any other error still fails the sync.
- It carries on instead of stopping.
- It names the refused days on the Sheets card and in Sync History, on every sync while any remain.
- It tries those days again on later syncs and writes them into the Sheet in place when Apple Health answers.
- It never blanks a value your Sheet already holds. A day the Sheet never held stays empty until Apple Health answers.

If you hit this error in 1.0.3 or earlier, nothing is wrong with your Sheet or your Health data. Updating to 1.0.4 once it is live is the fix.

## What you can check today

- Open Sync History in health4ai to see where the sync stops, and Your Sources to see which devices and apps have written to Health. Both are described in the [1.0.2 release post](/blog/health4ai-1-0-2-google-sheets-default/).
- If you write your own HealthKit code, split the failing range and retry the pieces as described above.

See also the [1.0.4 release notes](/blog/health4ai-1-0-4-what-to-save-sleep-stages/) and the general [sync troubleshooting guide](/blog/debug-health4ai-sync/).
