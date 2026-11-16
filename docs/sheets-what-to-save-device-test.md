# Device test: What to save + Sleep stages tab (PR #22)

Required before this ships. Every check in `ios/scripts/test_sheets_logic.sh` runs against fakes,
so none of them has touched HealthKit on a phone or a real Google Sheet. Run this on a real
iPhone with an Apple Watch or ring that records sleep stages, signed in to a test Google
account. Record the result for each step in the PR.

## Setup
- Install the PR build from TestFlight (or Xcode on a cable).
- Use a Health store that has at least a few months of staged sleep (core, deep, REM).
- Fresh case: sign in with Google so the app makes a new sheet. Upgrade case: install over 1.0.3
  with an existing sheet that has Daily and Workouts rows.

## Steps
1. **Defaults.** On the Connection screen, What to save shows Daily summary "Always saved",
   Workouts on, Sleep stages off. The sheet has no Sleep stages tab.
2. **Turn Sleep stages on.** "Filling…" appears under the switch and goes away when the sync
   ends. Repeat while a sync is already running (pull to refresh on Home, then switch it on
   straight away): the tab still fills. "Filling…" may vanish for up to two seconds between
   the two syncs; note it if that gap looks like a glitch. Sync History shows "You chose what to save" with days, workouts and sleep records on
   separate lines.
3. **Check the tab.** A Sleep stages tab exists with the header row frozen: Night, Stage, Start,
   End, Duration (min), Source, Record ID. Nights go back to the oldest sleep in Health (up to
   ten years). Spot-check three nights against the Health app's sleep chart: the stages and times
   match, and the Night is the date you woke up.
4. **No duplicates.** Tap Sync Now twice. The row count does not change. In the sheet, a quick
   `=COUNTA(G2:G)=COUNTUNIQUE(G2:G)` returns TRUE.
5. **Next morning.** After a night's sleep, open the app. Only last night's records are added.
6. **Late sleep.** Leave the watch or ring unsynced for 2-3 nights, then let it sync to Health
   and open the app. Those nights appear, each once.
7. **Interrupted first fill.** On a long history, turn Sleep stages on and force-quit the app
   partway through. Reopen: the fill continues and step 4 still holds.
8. **Deleted tab.** Delete the Sleep stages tab in Google Sheets, then sync. The tab comes back,
   full, with its header.
9. **Workouts off, then on.** Turn Workouts off, record a workout, and sync: it is not added.
   Turn Workouts on: it is added once, with "Filling…" while it runs.
10. **Turn Sleep stages off.** New nights stop arriving; rows already there stay.
11. **Background.** With the app closed overnight, Sync History gains an "Automatic, app closed"
    or "Scheduled, app closed" entry, and new sleep rows arrive without opening the app.
12. **Large text.** At the largest non-accessibility text size and at AX5, the What to save
    rows and Sync History rows wrap at word boundaries and nothing is clipped.
13. **AI check.** Connect the sheet to ChatGPT, Claude or Gemini and ask "How much deep sleep
    did I get last week?" The answer uses the Sleep stages tab.

## Known limits (expected, not failures)
- Sleep that reaches Health more than 7 nights late is not added.
- If Health access for sleep is denied, iOS reports no data rather than an error, so the tab
  stays empty and nothing is marked done.
