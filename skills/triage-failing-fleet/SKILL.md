---
name: triage-failing-fleet
description: Use when many services are failing at once, or a long-running system has produced gigabytes of logs and no results. Find the one upstream cause instead of reading the loudest error.
---

# Triage Failing Fleet

## Overview

When a dozen services fail together, the loudest error is almost never the cause. Log volume
measures retry frequency, not information. This skill collapses large logs to their information
content first, then walks the dependency chain backwards to the single upstream failure.

## When to Use

- Multiple services or workers failing simultaneously
- A system that has "been running" but produced no output
- Log directories that have grown to hundreds of megabytes
- Before summarizing results from any long-running automated system

**Do not use** for a single service with a single clear stack trace — read the trace.

## Core Process

### 1. Measure information, not volume

Before reading any large log, collapse it:

```sh
sort -u file.log | wc -l          # distinct lines
```

A 60MB file with **1 distinct line** is a startup banner reprinted on every respawn. It contains
no information. This one command routinely turns "summarize the analysis" into "there is no
analysis" in under a minute.

Do this across the whole log directory before opening a single file:

```sh
for f in logs/*.log; do printf '%8s %s\n' "$(sort -u "$f" | wc -l)" "$f"; done | sort -n
```

### 2. Separate output from errors

Compare total bytes in `*.out.log` versus `*.err.log`. Then check whether the "output" logs
contain results or just banners (step 1 tells you). A system can be 100% retry noise in both.

### 3. Walk backwards to the first failure

Order failures by time, not by volume. The service producing the most errors is usually a
*victim*. Ask what each failing service depends on:

- Many services failing to **connect** to one address → find who was supposed to **bind** it
- That service's own log holds the actual cause

Write the chain out explicitly. If it does not reduce to one upstream cause, you have not
finished.

### 4. Distinguish "running" from "producing"

Check when data was last actually written, not when the process last logged:

```sh
find <data-dir> -type f -newermt '-7 days' | wc -l
```

Zero recent writes plus a live process means the service is running and useless. Scheduled jobs
that log `start` then `skipping` every cycle are the same failure wearing a success costume.

### 5. Report absence as the finding

If the system produced nothing, that is the result. Do not synthesize a summary from
configuration to fill the gap. State the provable failure window, and label it as the window
the surviving logs cover — the real one may be longer.

### 6. Verify any shutdown by byte delta

```sh
before=$(cat logs/*.err.log | wc -c); sleep 30; after=$(cat logs/*.err.log | wc -c)
# delta 0 = genuinely stopped
```

Wait longer than the respawn throttle. See `find-hidden-services` for stopping properly.

## Common Rationalizations

| Excuse | Why It's Wrong |
|--------|---------------|
| "The biggest log is the main problem" | Log size measures retry rate. The cause is usually in a small log |
| "It's been running for weeks, there must be data" | Check last write time on the data store, not process uptime |
| "All twelve services are broken" | Twelve services failing to connect is one service failing to bind |
| "I'll summarize what it was configured to do" | Configuration is intent. Report what it produced, which may be nothing |
| "The health check passes" | Liveness is not usefulness. Nothing measured whether output existed |
| "I read the last 50 lines" | On a repeating log the last 50 lines are the same line 50 times |

## Red Flags

- A log file whose distinct-line count is 1
- Every service reporting healthy while the data store has no recent writes
- Scheduled jobs whose every run ends in `skipping` or `not reachable`
- Restart supervision with no failure ceiling — one broken dependency becomes unbounded log growth
- A summary being written from config values rather than observed output

## Verification

- [ ] Distinct-line count computed for every large log before reading any
- [ ] Failure chain written out and reduced to one upstream cause
- [ ] Last-write time on the data store checked, not just process uptime
- [ ] Provable failure window stated, and labelled as log-limited
- [ ] If nothing was produced, the report says so plainly rather than describing intent
- [ ] Any shutdown confirmed by a zero byte-delta after the throttle interval
