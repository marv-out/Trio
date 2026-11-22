#!/usr/bin/env bash
# TRIPWIRE (local, fork-only, non-blocking): editing the smoothing path fires a reminder of the
# three parity layers and the definitive validation method. Per-call green ≠ production-faithful.
source "$(dirname "$0")/_lib.sh"

file="$(hook_file)"; [[ -z "$file" ]] && ok
case "$file" in
  *GlucoseSmoothing/Sources/*|*GlucoseBucketing.swift|*UnscentedKalmanFilter.swift|*FetchGlucoseManager.swift|*InMemoryGlucoseValue.swift) ;;
  *) ok ;;
esac
remind "You're editing the Adaptive Smoothing path. Parity with AAPS has THREE layers that must
all hold — prove each before claiming parity:
  1. Per-call: bit-exact to the AAPS Kotlin plugin + Python V4UKF (golden vectors + parity tests).
  2. Persistence: reuse the single sharedSmoother across cycles — never a fresh instance.
  3. Input window: 34 h, newest-first, 5-min bucketed.
Fast check: swift test --package-path GlucoseSmoothing.
DEFINITIVE check before claiming parity: the full rolling-window replay across Swift+Kotlin+
Python in tim2000s/trio-ukf-backtest. Per-call tests alone will NOT catch a persistence bug."
