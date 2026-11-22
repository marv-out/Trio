#!/usr/bin/env python3
"""
fetch_v5shadow.py — build the V5-shadow dosing-replay fixture.

Pulls the last N days of Nightscout deviceStatus for every boost site in
~/.config/boost_backtest/sites.json that has a token, keeps only cycles carrying the
on-device V5 shadow (`openaps.suggested.boostV5_score`), projects each to the inputs +
recorded V5 outputs the Swift golden master needs, and writes an NDJSON fixture:

    BoostPort/BoostV5Core/Tests/BoostV5CoreTests/Fixtures/v5_shadow.ndjson

Raw responses are cached under ~/.cache/boost_backtest/v5shadow_raw so re-runs are offline.

The V5 shadow (`boostV5_*`) is produced by the AndroidAPS Kotlin V5; the Swift BoostV5Core is
the port of it, so the replay is a golden master of the port's dosing/safety-gate logic.

Usage:  python3 BoostPort/sim/fetch_v5shadow.py [--days 10] [--offline]
"""
from __future__ import annotations
import argparse, json, re, sys, urllib.request, urllib.parse
from datetime import datetime, timezone, timedelta
from pathlib import Path

SITES = Path.home() / ".config/boost_backtest/sites.json"
CACHE = Path.home() / ".cache/boost_backtest/v5shadow_raw"
OUT = Path(__file__).resolve().parent.parent / "BoostV5Core/Tests/BoostV5CoreTests/Fixtures/v5_shadow.ndjson"


def fetch(base: str, token: str, since_iso: str, count: int = 50000) -> list:
    params = {"count": count, "find[created_at][$gte]": since_iso, "token": token}
    url = f"{base.rstrip('/')}/api/v1/devicestatus.json?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.loads(r.read())


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def console_lines(s: dict) -> list[str]:
    out = []
    for key in ("consoleError", "consoleLog"):
        v = s.get(key)
        if isinstance(v, list):
            out.extend(str(x) for x in v)
        elif isinstance(v, str):
            out.extend(v.split("\n"))
    return out


def parse_console(lines: list[str]) -> dict:
    text = "\n".join(lines)

    def g(pat):
        m = re.search(pat, text)
        return num(m.group(1).replace(",", ".")) if m else None

    return {
        "maxIob": g(r"maxIOB:\s*([-0-9.,]+)"),
        # LGS threshold printed in mmol — normalise to mg/dL below.
        "lgsThreshold": g(r"LGS threshold:\s*([-0-9.,]+)"),
        "roundSmbTo": g(r"round\w*SMB\w*\D*([-0-9.,]+)"),  # may be absent
        "smbAllowed": ("SMB allowed: true" in text)
        if ("SMB allowed:" in text) else None,
    }


def project(rec: dict) -> dict | None:
    s = rec.get("openaps", {}).get("suggested", {})
    if "boostV5_score" not in s:
        return None
    con = parse_console(console_lines(s))
    thr = con["lgsThreshold"]
    if thr is not None and thr < 25:  # mmol -> mg/dL
        thr *= 18.0
    return {
        "ts": rec.get("created_at") or s.get("timestamp"),
        # inputs / gate context
        "bg": num(s.get("bg")),
        "eventualBG": num(s.get("eventualBG")),
        "minGuardBG": num(s.get("minGuardBG")),
        "iob": num(s.get("IOB")),
        "cob": num(s.get("COB")),
        "targetBG": num(s.get("targetBG")),
        "insulinReq": num(s.get("insulinReq")),     # baseInsulinReq
        "deltaAccl": num(s.get("deltaAcceleration")),
        "mlHypoRisk": num(s.get("mlHypoRisk")),
        "mlMealLikely": num(s.get("mlMealLikely")),
        "units": num(s.get("units")),               # actually delivered
        "boostTier": s.get("boostTier"),
        "maxIob": con["maxIob"],
        "lgsThreshold": thr,
        "roundSmbTo": con["roundSmbTo"],
        "smbAllowed": con["smbAllowed"],
        # recorded V5 shadow outputs (the golden-master reference)
        "v5_state": s.get("boostV5_state"),
        "v5_age": num(s.get("boostV5_age")),
        "v5_score": num(s.get("boostV5_score")),
        "v5_budget": num(s.get("boostV5_budget")),
        "v5_actionMult": num(s.get("boostV5_actionMult")),
        "v5_finalDose": num(s.get("boostV5_finalDose")),
        "v5_gateReduction": s.get("boostV5_gateReduction"),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=10)
    ap.add_argument("--offline", action="store_true", help="use cached raw responses only")
    args = ap.parse_args()

    sites = json.loads(SITES.read_text())["sites"]
    since = (datetime.now(timezone.utc) - timedelta(days=args.days)).isoformat().replace("+00:00", "Z")
    CACHE.mkdir(parents=True, exist_ok=True)
    OUT.parent.mkdir(parents=True, exist_ok=True)

    total = 0
    per_user = {}
    with OUT.open("w") as out:
        for site in sites:
            tag, base, token = site.get("tag"), site.get("base"), site.get("token")
            if not token:
                print(f"  {tag}: no token — skipped")
                continue
            cache_file = CACHE / f"{tag}_{args.days}d.json"
            try:
                if args.offline and cache_file.exists():
                    ds = json.loads(cache_file.read_text())
                else:
                    ds = fetch(base, token, since)
                    cache_file.write_text(json.dumps(ds))
            except Exception as e:  # noqa: BLE001
                print(f"  {tag}: fetch failed ({e}) — skipped")
                continue
            n = 0
            for rec in ds:
                row = project(rec)
                if row is None or row["ts"] is None or row["bg"] is None:
                    continue
                row["user"] = tag
                out.write(json.dumps(row) + "\n")
                n += 1
            per_user[tag] = n
            total += n
            print(f"  {tag}: {len(ds)} deviceStatus -> {n} V5 cycles")

    print(f"\nWrote {total} V5 cycles -> {OUT}")
    print("Per user:", per_user)
    if total == 0:
        print("WARNING: no V5 cycles — check tokens / that these sites run V5-shadow.", file=sys.stderr)


if __name__ == "__main__":
    main()
