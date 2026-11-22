#!/usr/bin/env bash
# GUARDRAIL (local, fork-only): never construct a fresh UnscentedKalmanFilter() per cycle.
# AAPS's smoother is a singleton carrying learnedR / innovation windows ACROSS cycles; a fresh
# instance resets learning every call and diverges by ~15 mg/dL, invisible to per-call tests
# (mistake #3). Only sanctioned sites: the sharedSmoother factory, and the package's own tests.
source "$(dirname "$0")/_lib.sh"

ALLOW_CTX='sensorChangedSinceLastCall|makeSharedSmoother|resetSharedSmoother'
NONCOMMENT='^[[:space:]]*(//|\*|/\*)'   # skip docstrings/prose that merely mention the type

file="$(hook_file)"; text="$(hook_new_text)"; [[ -z "$text" ]] && ok
case "$file" in *"/Tests/"*|*Test*.swift) ok ;; esac   # tests may construct it directly

constructs="$(printf '%s' "$text" | grep -vE "$NONCOMMENT" | grep -E 'UnscentedKalmanFilter\(' || true)"
[[ -z "$constructs" ]] && ok
printf '%s' "$constructs" | grep -qvE "$ALLOW_CTX" || ok   # all carry factory context → fine
block "this edit constructs a fresh UnscentedKalmanFilter() outside the shared factory.
The filter MUST be a reused persistent instance (sharedSmoother) so learnedR and the
innovation windows carry across cycles — matching AAPS. A fresh-per-cycle instance resets
learning every call and diverges by ~15 mg/dL, invisible to per-call tests (mistake #3).
Route construction through makeSharedSmoother()."
