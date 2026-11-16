---
title: "Apple Health Data Schema: What's in Your Database"
description: "A guide to health4ai raw samples, historical summaries, HealthKit type identifiers, and direct SQL queries."
pubDate: 2026-09-10
slug: "apple-health-data-schema"
tags: ["schema", "postgres", "healthkit", "apple-health", "sql", "database", "reference"]
draft: false
---

Understanding the health4ai database schema lets you write custom SQL queries, build dashboards directly on the database, and debug sync issues. The [published schema](/schema.sql) is the authoritative definition for a new Supabase project.

## Two Tables

health4ai uses a two-tier storage architecture:

- `healthkit_metrics` — raw HealthKit samples, including recent and selected older samples
- `healthkit_daily_summaries` — daily aggregates for older quantity samples where summarization has run

The summarizer can aggregate older quantity samples into daily rows. Some older samples remain raw: category and workout records retain detail, merged activity types retain raw rows for safe recomputation, and other quantity types remain raw until their history can be compacted without double counting. Historical queries use a daily summary where available and aggregate remaining raw rows in Postgres.

## healthkit_metrics

The raw table stores a UUID `user_id` linked to Supabase Auth. Its unique sample key is `(user_id, metric_type, source_device, started_at)`, so an upload of the same sample does not create another row. `synced_at` records when the row reached the database. See the [published schema](/schema.sql) for the current columns, constraints, and indexes.

**Columns:**

| Column | Description |
|--------|-------------|
| `user_id` | Supabase Auth user UUID |
| `metric_type` | HealthKit quantity/category type identifier |
| `value`, `unit` | Numeric value and its unit |
| `started_at`, `ended_at` | Sample time range |
| `source_device` | Source name or merged HealthKit activity source |
| `metadata` | Additional type-specific details |
| `synced_at` | Time the row was uploaded |

**Workout records** store their detail in the `metadata` JSONB column:

```json
{
  "workout_type": "Running",
  "duration_seconds": 2340.0,
  "total_distance_meters": 5820.0,
  "total_energy_burned_cal": 387.0
}
```

**Sleep records** use integer values for stage codes:
- 0 = InBed
- 2 = Awake
- 3 = AsleepCore
- 4 = AsleepDeep
- 5 = AsleepREM

## healthkit_daily_summaries

The daily table holds averages, minimums, maximums, sums, and sample counts by user, metric type, calendar date, and unit. The [new-project schema](/schema.sql) calls the date column `summary_date`; a legacy deployment may use `date`. Day boundaries follow the project's configured time zone. A fresh self-hosted project does not run the optional historical summarizer, so this table can be empty while historical queries still work from raw samples.

## Common HealthKit Type Identifiers

### Activity
| Metric | Identifier |
|--------|-----------|
| Steps | `HKQuantityTypeIdentifierStepCount` |
| Distance (walk/run) | `HKQuantityTypeIdentifierDistanceWalkingRunning` |
| Distance (cycling) | `HKQuantityTypeIdentifierDistanceCycling` |
| Active energy | `HKQuantityTypeIdentifierActiveEnergyBurned` |
| Basal energy | `HKQuantityTypeIdentifierBasalEnergyBurned` |
| Exercise time | `HKQuantityTypeIdentifierAppleExerciseTime` |
| Stand time | `HKQuantityTypeIdentifierAppleStandTime` |
| Flights climbed | `HKQuantityTypeIdentifierFlightsClimbed` |

### Vitals
| Metric | Identifier |
|--------|-----------|
| Heart rate | `HKQuantityTypeIdentifierHeartRate` |
| Resting HR | `HKQuantityTypeIdentifierRestingHeartRate` |
| Walking HR avg | `HKQuantityTypeIdentifierWalkingHeartRateAverage` |
| HRV (SDNN) | `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` |
| Blood oxygen | `HKQuantityTypeIdentifierOxygenSaturation` |
| Respiratory rate | `HKQuantityTypeIdentifierRespiratoryRate` |

### Body
| Metric | Identifier |
|--------|-----------|
| Weight | `HKQuantityTypeIdentifierBodyMass` |
| BMI | `HKQuantityTypeIdentifierBodyMassIndex` |
| Body fat % | `HKQuantityTypeIdentifierBodyFatPercentage` |
| Lean mass | `HKQuantityTypeIdentifierLeanBodyMass` |
| VO2 Max | `HKQuantityTypeIdentifierVO2Max` |

### Sleep and Workouts
| Metric | Identifier |
|--------|-----------|
| Sleep analysis | `HKCategoryTypeIdentifierSleepAnalysis` |
| Workouts | `HKWorkoutTypeIdentifier` |

## Example Queries

**All metric types in your database:**
```sql
SELECT metric_type, COUNT(*) as rows,
       MIN(started_at)::date as earliest,
       MAX(started_at)::date as latest
FROM healthkit_metrics
WHERE user_id = 'your_user_uuid'
GROUP BY metric_type
ORDER BY rows DESC;
```

**Monthly HRV averages (works on a fresh install with raw history):**
```sql
-- Replace UTC with your HEALTH4AI_TZ setting if you changed it.
SELECT DATE_TRUNC('month', started_at AT TIME ZONE 'UTC') AS month,
       ROUND(AVG(value)::numeric, 1) AS avg_hrv_ms,
       COUNT(*) AS samples
FROM healthkit_metrics
WHERE user_id = 'your_user_uuid'
  AND metric_type = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN'
GROUP BY 1
ORDER BY 1 DESC;
```

**Recent sleep stage records:**
```sql
SELECT started_at, ended_at, value,
       ROUND((EXTRACT(EPOCH FROM (ended_at - started_at)) / 60)::numeric, 1) as duration_min,
       CASE value::int
         WHEN 3 THEN 'Core'
         WHEN 4 THEN 'Deep'
         WHEN 5 THEN 'REM'
         WHEN 2 THEN 'Awake'
       END as stage
FROM healthkit_metrics
WHERE user_id = 'your_user_uuid'
  AND metric_type = 'HKCategoryTypeIdentifierSleepAnalysis'
  AND value IN (2, 3, 4, 5)
  AND started_at >= NOW() - INTERVAL '7 days'
ORDER BY started_at DESC;
```

**Workout list with metadata:**
```sql
SELECT started_at::date as date,
       metadata->>'workout_type' as type,
       ROUND((metadata->>'duration_seconds')::numeric / 60, 0) as duration_min,
       ROUND((metadata->>'total_distance_meters')::numeric / 1000, 2) as distance_km,
       ROUND((metadata->>'total_energy_burned_cal')::numeric) as calories
FROM healthkit_metrics
WHERE user_id = 'your_user_uuid'
  AND metric_type = 'HKWorkoutTypeIdentifier'
  AND started_at >= NOW() - INTERVAL '30 days'
ORDER BY started_at DESC;
```

---

[Get health4ai on the App Store →](https://apps.apple.com/app/health4ai/id6783074944)
