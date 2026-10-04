"""
Pure-Python reference model of the PL/SQL rule engine (pkg_aml_rules).

It mirrors the SQL semantics closely enough to:
  * measure recall of each rule against the generator's ground truth, and
  * catch threshold/generator drift in CI without needing an Oracle instance.

Oracle remains the system of record; sql/tests/test_aml_rules.sql tests the
real packages. Keep thresholds here in sync with 05_seed_reference_data.sql.
"""
from __future__ import annotations

import csv
import re
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta

RULES = {
    "STRUCTURING": dict(threshold=10000, lower=8000, lookback=5, min_cnt=3),
    "LARGE_CASH_CTR": dict(threshold=10000),
    "RAPID_MOVEMENT": dict(threshold=25000, lookback=2, pct=85),
    "SANCTIONS_MATCH": dict(match_score=90),
    "HIGH_RISK_GEO": dict(threshold=0),
    "DORMANT_REACTIVATION": dict(threshold=10000, inactivity_days=180),
}
CASH_TYPES = {"CASH_DEP", "CASH_WDL"}
WIRE_TYPES = {"WIRE_IN", "WIRE_OUT"}

_SUFFIX = re.compile(r" (LLC|LTD|LIMITED|INC|CORP|CO|FZE|PLC|SA|GMBH|HOLDINGS?)$")


def normalize_name(name: str | None) -> str | None:
    """Same steps as pkg_aml_util.normalize_name."""
    if not name:
        return None
    n = re.sub(r"[^A-Z0-9 ]", "", name.upper())
    n = re.sub(r" {2,}", " ", n).strip()
    n = _SUFFIX.sub("", n)
    return n.strip()


def jaro_winkler(s1: str, s2: str) -> int:
    """Jaro-Winkler similarity scaled 0-100, like UTL_MATCH.JARO_WINKLER_SIMILARITY."""
    if s1 == s2:
        return 100
    l1, l2 = len(s1), len(s2)
    if not l1 or not l2:
        return 0
    window = max(l1, l2) // 2 - 1
    m1, m2 = [False] * l1, [False] * l2
    matches = 0
    for i, c in enumerate(s1):
        lo, hi = max(0, i - window), min(i + window + 1, l2)
        for j in range(lo, hi):
            if not m2[j] and s2[j] == c:
                m1[i] = m2[j] = True
                matches += 1
                break
    if not matches:
        return 0
    t, k = 0, 0
    for i in range(l1):
        if m1[i]:
            while not m2[k]:
                k += 1
            if s1[i] != s2[k]:
                t += 1
            k += 1
    jaro = (matches / l1 + matches / l2 + (matches - t / 2) / matches) / 3
    prefix = 0
    for a, b in zip(s1[:4], s2[:4]):
        if a != b:
            break
        prefix += 1
    return int((jaro + prefix * 0.1 * (1 - jaro)) * 100)


@dataclass
class Txn:
    txn_id: str
    account_id: str
    ts: datetime
    txn_type: str
    direction: str
    amount: float
    cp_name: str
    cp_country: str

    @property
    def d(self) -> date:
        return self.ts.date()


def load_dataset(inbound_dir: str, tag: str):
    def rows(name):
        with open(f"{inbound_dir}/{name}_{tag}.dat", newline="", encoding="utf-8") as fh:
            yield from csv.DictReader(fh, delimiter="|")

    txns = [Txn(r["TXN_ID"], r["ACCOUNT_ID"], datetime.strptime(r["TXN_TS"], "%Y-%m-%d %H:%M:%S"),
                r["TXN_TYPE"], r["DIRECTION"], float(r["AMOUNT"]), r["COUNTERPARTY_NAME"], r["COUNTERPARTY_COUNTRY"])
            for r in rows("transactions") if r["STATUS"] == "POSTED"]
    accounts = {r["ACCOUNT_ID"]: date.fromisoformat(r["LAST_ACTIVITY_DATE"]) for r in rows("accounts")}
    country_tier = {r["COUNTRY_CODE"]: r["RISK_TIER"] for r in rows("country_risk")}
    sanctions = [(r["SDN_ID"], normalize_name(r["PARTY_NAME"])) for r in rows("sanctions_list")]
    return txns, accounts, country_tier, sanctions


def run_rules(txns, accounts, country_tier, sanctions, run_date: date, scan_days: int = 30):
    """Returns {rule_code: set(account_id)}."""
    lo = run_date - timedelta(days=scan_days)
    window = [t for t in txns if lo <= t.d <= run_date]
    by_acct = defaultdict(list)
    for t in window:
        by_acct[t.account_id].append(t)
    for v in by_acct.values():
        v.sort(key=lambda t: (t.ts, t.txn_id))

    alerts = defaultdict(set)

    # STRUCTURING
    c = RULES["STRUCTURING"]
    for acct, ts in by_acct.items():
        deps = [t for t in ts if t.txn_type in CASH_TYPES and t.direction == "CR"
                and c["lower"] <= t.amount < c["threshold"]]
        for a in deps:
            win = [t for t in deps if a.d <= t.d <= a.d + timedelta(days=c["lookback"] - 1)]
            if len(win) >= c["min_cnt"] and sum(t.amount for t in win) > c["threshold"]:
                alerts["STRUCTURING"].add(acct)
                break

    # LARGE_CASH_CTR
    for t in window:
        if t.txn_type in CASH_TYPES and t.amount > RULES["LARGE_CASH_CTR"]["threshold"]:
            alerts["LARGE_CASH_CTR"].add(t.account_id)

    # RAPID_MOVEMENT
    c = RULES["RAPID_MOVEMENT"]
    for acct, ts in by_acct.items():
        for i in (t for t in ts if t.direction == "CR" and t.amount >= c["threshold"]):
            out = sum(o.amount for o in ts if o.direction == "DR" and o.txn_type in WIRE_TYPES
                      and o.ts >= i.ts and o.d <= i.d + timedelta(days=c["lookback"] - 1))
            if out >= i.amount * c["pct"] / 100:
                alerts["RAPID_MOVEMENT"].add(acct)
                break

    # SANCTIONS_MATCH (first-letter blocking, like the SQL)
    score = RULES["SANCTIONS_MATCH"]["match_score"]
    for t in window:
        if t.txn_type not in WIRE_TYPES:
            continue
        n = normalize_name(t.cp_name)
        if not n:
            continue
        if any(s[1][:1] == n[:1] and jaro_winkler(n, s[1]) >= score for s in sanctions):
            alerts["SANCTIONS_MATCH"].add(t.account_id)

    # HIGH_RISK_GEO
    for t in window:
        if t.txn_type in WIRE_TYPES and country_tier.get(t.cp_country) == "PROHIBITED" \
                and t.amount > RULES["HIGH_RISK_GEO"]["threshold"]:
            alerts["HIGH_RISK_GEO"].add(t.account_id)

    # DORMANT_REACTIVATION
    c = RULES["DORMANT_REACTIVATION"]
    cutoff = run_date - timedelta(days=c["inactivity_days"])
    for acct, ts in by_acct.items():
        last = accounts.get(acct)
        if last and last < cutoff and sum(t.amount for t in ts) > c["threshold"]:
            alerts["DORMANT_REACTIVATION"].add(acct)

    return alerts
