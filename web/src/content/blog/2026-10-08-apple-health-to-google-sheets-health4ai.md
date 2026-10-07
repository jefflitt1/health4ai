---
title: "Apple Health to Google Sheets with health4ai"
description: "Step by step: send your Apple Health data to a Google Sheet in your own Drive with health4ai, then chart it, compare weeks, and ask an AI about it."
pubDate: 2026-10-07
slug: "apple-health-to-google-sheets-health4ai"
tags: ["google-sheets", "apple-health", "how-to", "healthkit", "health4ai"]
draft: false
---

# Apple Health to Google Sheets with health4ai

Apple Health holds years of data, but it is awkward to work with. You can scroll charts inside the Health app, but you cannot easily sort, filter, or hand the numbers to another tool. A spreadsheet fixes that.

health4ai is a free iOS app that writes your Health data to a Google Sheet in your own Google Drive, one row per day. This post walks through setup and then four things worth doing with the result.

## What you get

- One sheet in your Google Drive, one row per day.
- Columns for steps, sleep, heart rate, HRV, workouts and more.
- Up to 10 years of history on the first sync. One real account produced 3,653 days.
- No health4ai account and no health4ai server. The app never receives your data; it writes straight to your Drive.

On permissions: the Google scope is `drive.file`. That means the app can only see files it created. It cannot read your other documents.

## Before you start

You need an iPhone with the Health app holding some data, and a Google account. That is all. Apple Watch is not required: health4ai reads every device and app that writes to Health, and its Your Sources screen lists them.

## Step by step

1. **Install health4ai** from the [App Store](https://apps.apple.com/app/health4ai/id6783074944). It is free.
2. **Choose Save to Google Sheets** as the destination.
3. **Sign in to Google** and approve access. You are approving the narrow `drive.file` scope described above.
4. **Grant Health access.** iOS shows a permission sheet listing the data types. Turn on the ones you want in the sheet. If iOS 27 offers a choice about how much history to share, choose all data. Otherwise the app only sees the last 30 days. The full explanation is in [why your Apple Health export only shows 30 days on iOS 27](/blog/apple-health-export-only-30-days-ios-27/).
5. **Run the first sync.** The backfill can take a while for a long history. Leave the app open and let it work.
6. **Check Sync History** inside the app. It lists every sync, including ones that ran while the app was closed, so you can confirm rows were written.
7. **Open the sheet** from your Google Drive and look at the rows.

The in-app setup checklist tracks these steps, so you can see what is left if you stop partway.

## After the first sync

Background sync is best effort. iOS decides when to run it, so new days may show up with a delay. If you want today's numbers right now, open the app. Do not expect real-time.

## Four things to do with the sheet

### 1. Ask an AI about it

Download the sheet as a CSV (File, Download, CSV in Google Sheets), or share the contents with an AI assistant you already use. Then ask plain questions:

- "Which weeks in the last year had my lowest average HRV?"
- "Is there a pattern between my sleep hours and my step count the next day?"
- "Summarize how my resting heart rate changed month by month."

Be a little skeptical of the answers. A language model reading a table can miscalculate, so ask it to show the rows it used, and spot check a few. This is data exploration, not medical advice, and nothing here replaces talking to a clinician about your health.

If you would rather have an AI query live data directly, the database destination supports MCP clients. The [setup page](/setup/) covers it.

### 2. Chart a trend

Select the date column and one metric column, then Insert, Chart. A line chart of daily steps over a year shows seasons and travel immediately. Add a second series, such as sleep hours, to look at them together. Smooth noisy data by adding a 7-day moving average column: `=AVERAGE(B2:B8)` filled down.

### 3. Compare this week with last week

Add a small summary block beside the data. With dates in column A and steps in column B, you can use:

```
=AVERAGEIFS(B:B, A:A, ">="&TODAY()-6, A:A, "<="&TODAY())
=AVERAGEIFS(B:B, A:A, ">="&TODAY()-13, A:A, "<="&TODAY()-7)
```

The first line averages the last seven days, the second the seven before that. Repeat for sleep or heart rate. A conditional format on the difference makes the direction obvious.

### 4. Keep a long-term record you own

Apple Health lives on your phone. A sheet in your Drive is a copy you control, that you can duplicate, archive, or export. Make a copy once a year if you like having a frozen snapshot.

## Troubleshooting

- **Only about 30 days of data.** iOS may be sharing only recent Health data with the app. health4ai warns when this happens. Change the data access option to all data, as described in the explainer linked above. The sheet rebuilds itself when access widens.
- **A day looks incomplete.** The row for today fills in as data arrives. Check it again tomorrow.
- **Missing a metric.** iOS asks permission per data type, so that type may be switched off for health4ai in its Health access settings. Your Sources shows which devices and apps are sending data, and some days simply have no data for a metric.

## Sheet or database?

The sheet is the easiest path. If you later want every raw sample and SQL access, health4ai also supports your own Postgres or Supabase database. Compare them in [how it works](/how-it-works/). Your data stays yours either way, see [privacy](/privacy/).

health4ai is free on the App Store: [Download on the App Store](https://apps.apple.com/app/health4ai/id6783074944).
