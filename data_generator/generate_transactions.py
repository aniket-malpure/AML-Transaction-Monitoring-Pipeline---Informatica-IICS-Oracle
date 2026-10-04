#!/usr/bin/env python3
"""
Synthetic AML data generator.

Produces pipe-delimited flat files that mimic a core-banking daily extract:
  customers_YYYYMMDD.dat, accounts_YYYYMMDD.dat, transactions_YYYYMMDD.dat,
  sanctions_list_YYYYMMDD.dat, country_risk_YYYYMMDD.dat

It deliberately injects known suspicious patterns so the PL/SQL rules have
something real to find, and writes a ground-truth file (injected_patterns.csv)
used by the tests to measure detection recall.

Usage:
  python generate_transactions.py --accounts 50000 --transactions 2000000 \
      --days 30 --out ../data/inbound --seed 42
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import os
import random
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta

DELIM = "|"

FIRST_NAMES = [
    "James", "Mary", "Robert", "Patricia", "John", "Jennifer", "Michael", "Linda",
    "David", "Elizabeth", "William", "Barbara", "Richard", "Susan", "Joseph", "Jessica",
    "Thomas", "Sarah", "Carlos", "Maria", "Wei", "Priya", "Ahmed", "Fatima", "Ivan",
    "Olga", "Kenji", "Yuki", "Luis", "Ana", "Omar", "Leila", "Arjun", "Sofia",
]
LAST_NAMES = [
    "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis",
    "Rodriguez", "Martinez", "Hernandez", "Lopez", "Wilson", "Anderson", "Thomas",
    "Taylor", "Moore", "Jackson", "Martin", "Lee", "Chen", "Patel", "Khan", "Ivanov",
    "Petrov", "Tanaka", "Sato", "Silva", "Haddad", "Nguyen", "Kim", "Singh",
]
US_STATES = ["FL", "NY", "CA", "TX", "IL", "NJ", "GA", "AZ", "WA", "MA", "NV", "CO"]

# ISO country, risk tier (fictional scoring for demo purposes only)
COUNTRIES = [
    ("US", "LOW"), ("CA", "LOW"), ("GB", "LOW"), ("DE", "LOW"), ("JP", "LOW"),
    ("MX", "MEDIUM"), ("BR", "MEDIUM"), ("IN", "MEDIUM"), ("AE", "MEDIUM"),
    ("PA", "HIGH"), ("KY", "HIGH"), ("VG", "HIGH"), ("IR", "PROHIBITED"),
    ("KP", "PROHIBITED"), ("SY", "PROHIBITED"),
]

# Fictional sanctioned parties. None of these refer to real people.
SANCTIONED = [
    ("SDN-00017", "Viktor Branislav Orlenko", "INDIVIDUAL", "KY"),
    ("SDN-00042", "Halcyon Maritime Trading LLC", "ENTITY", "PA"),
    ("SDN-00058", "Rashid Al Qamari", "INDIVIDUAL", "AE"),
    ("SDN-00063", "Northwind Precious Metals FZE", "ENTITY", "AE"),
    ("SDN-00071", "Dmitri Valerevich Sokolin", "INDIVIDUAL", "VG"),
    ("SDN-00089", "Golden Crescent Exchange House", "ENTITY", "PA"),
    ("SDN-00094", "Marisol Quintanar Ybarra", "INDIVIDUAL", "MX"),
    ("SDN-00101", "Taurus Offshore Holdings Ltd", "ENTITY", "VG"),
]

TXN_TYPES = [
    # code, channel, direction, weight, (min,max) amount
    ("CASH_DEP", "BRANCH", "CR", 10, (20, 4000)),
    ("CASH_WDL", "ATM", "DR", 12, (20, 800)),
    ("ACH_IN", "ACH", "CR", 14, (50, 6000)),
    ("ACH_OUT", "ACH", "DR", 14, (25, 3000)),
    ("CARD_POS", "CARD", "DR", 30, (3, 450)),
    ("WIRE_IN", "WIRE", "CR", 3, (500, 40000)),
    ("WIRE_OUT", "WIRE", "DR", 3, (500, 30000)),
    ("P2P_IN", "MOBILE", "CR", 7, (10, 900)),
    ("P2P_OUT", "MOBILE", "DR", 7, (10, 900)),
]
TXN_WEIGHTS = [t[3] for t in TXN_TYPES]


@dataclass
class Account:
    account_id: str
    customer_id: str
    product: str
    open_date: date
    status: str
    dormant: bool


def stable_id(prefix: str, n: int, width: int = 9) -> str:
    return f"{prefix}{n:0{width}d}"


def txn_id(day: date, seq: int) -> str:
    return f"T{day:%Y%m%d}{seq:010d}"


def write_rows(path: str, header: list[str], rows) -> int:
    count = 0
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh, delimiter=DELIM, lineterminator="\n")
        w.writerow(header)
        for r in rows:
            w.writerow(r)
            count += 1
    return count


def write_trailer_manifest(path: str, row_count: int) -> None:
    """Control file the shell layer checks before loading (row count + md5)."""
    md5 = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            md5.update(chunk)
    with open(path + ".ctl", "w", encoding="utf-8") as fh:
        fh.write(f"FILE={os.path.basename(path)}\nROWS={row_count}\nMD5={md5.hexdigest()}\n")


def build_customers(rng: random.Random, n: int):
    customers = []
    for i in range(1, n + 1):
        cid = stable_id("C", i)
        first, last = rng.choice(FIRST_NAMES), rng.choice(LAST_NAMES)
        country = "US" if rng.random() < 0.9 else rng.choice([c for c, _ in COUNTRIES[:12]])
        cust_type = "BUSINESS" if rng.random() < 0.12 else "INDIVIDUAL"
        name = f"{last} {rng.choice(['Trading', 'Imports', 'Logistics', 'Services'])} LLC" \
            if cust_type == "BUSINESS" else f"{first} {last}"
        dob = "" if cust_type == "BUSINESS" else (
            date(1950, 1, 1) + timedelta(days=rng.randint(0, 365 * 52))).isoformat()
        kyc_risk = rng.choices(["LOW", "MEDIUM", "HIGH"], weights=[80, 16, 4])[0]
        pep = "Y" if rng.random() < 0.004 else "N"
        customers.append([cid, name, cust_type, dob, country, rng.choice(US_STATES),
                          kyc_risk, pep, (date(2010, 1, 1) + timedelta(days=rng.randint(0, 5000))).isoformat()])
    return customers


def build_accounts(rng: random.Random, customers, n_accounts: int, run_date: date):
    accounts: list[Account] = []
    for i in range(1, n_accounts + 1):
        cust = customers[(i - 1) % len(customers)] if i <= len(customers) else rng.choice(customers)
        product = rng.choices(["CHECKING", "SAVINGS", "BROKERAGE", "BUSINESS_CHK"], weights=[55, 25, 10, 10])[0]
        open_dt = run_date - timedelta(days=rng.randint(60, 4000))
        dormant = rng.random() < 0.03
        accounts.append(Account(stable_id("A", i, 10), cust[0], product, open_dt, "ACTIVE", dormant))
    return accounts


def normal_transactions(rng, accounts, start: date, days: int, n_txn: int, countries):
    active = [a for a in accounts if not a.dormant]
    for seq in range(1, n_txn + 1):
        acct = rng.choice(active)
        t = rng.choices(TXN_TYPES, weights=TXN_WEIGHTS)[0]
        code, channel, direction, _, (lo, hi) = t
        day = start + timedelta(days=rng.randint(0, days - 1))
        ts = datetime.combine(day, datetime.min.time()) + timedelta(seconds=rng.randint(21600, 79200))
        amount = round(rng.uniform(lo, hi), 2)
        cp_country = "US"
        if channel == "WIRE":
            cp_country = rng.choices([c for c, _ in countries], weights=[60, 6, 6, 5, 3, 5, 4, 4, 4, 1, 1, 1, 0, 0, 0])[0]
        cp_name = f"{rng.choice(FIRST_NAMES)} {rng.choice(LAST_NAMES)}"
        yield [txn_id(day, seq), acct.account_id, ts.strftime("%Y-%m-%d %H:%M:%S"), code, channel,
               direction, f"{amount:.2f}", "USD", cp_name, cp_country, "POSTED"]


def inject_patterns(rng, accounts, start: date, days: int, seq_start: int, truth: list):
    """Inject labelled suspicious behaviour. Returns list of txn rows."""
    rows = []
    seq = seq_start
    pool = [a for a in accounts if not a.dormant]

    def add(acct, day, secs, code, channel, direction, amt, cp_name="", cp_country="US"):
        nonlocal seq
        seq += 1
        ts = datetime.combine(day, datetime.min.time()) + timedelta(seconds=secs)
        rows.append([txn_id(day, seq), acct.account_id, ts.strftime("%Y-%m-%d %H:%M:%S"), code, channel,
                     direction, f"{amt:.2f}", "USD", cp_name, cp_country, "POSTED"])

    # 1. Structuring: 3-6 cash deposits of $8,000-$9,950 within 5 days, total > $10K
    for acct in rng.sample(pool, 120):
        d0 = start + timedelta(days=rng.randint(0, days - 6))
        for k in range(rng.randint(3, 6)):
            add(acct, d0 + timedelta(days=rng.randint(0, 4)), rng.randint(32400, 61200),
                "CASH_DEP", "BRANCH", "CR", round(rng.uniform(8000, 9950), 2))
        truth.append(("STRUCTURING", acct.account_id))

    # 2. Rapid movement: large inbound wire then >= 85% wired out within 48h
    for acct in rng.sample(pool, 80):
        d0 = start + timedelta(days=rng.randint(0, days - 3))
        amt = round(rng.uniform(25000, 150000), 2)
        add(acct, d0, 36000, "WIRE_IN", "WIRE", "CR", amt, "Unrelated Sender Co", "US")
        add(acct, d0 + timedelta(days=rng.randint(0, 1)), 54000, "WIRE_OUT", "WIRE", "DR",
            round(amt * rng.uniform(0.86, 0.98), 2), "Offshore Beneficiary", rng.choice(["KY", "VG", "PA"]))
        truth.append(("RAPID_MOVEMENT", acct.account_id))

    # 3. Sanctions hits: wires to fuzzy-misspelled sanctioned names
    for acct in rng.sample(pool, 40):
        sdn = rng.choice(SANCTIONED)
        name = sdn[1]
        if rng.random() < 0.6:  # introduce a typo so exact-match would miss it
            i = rng.randint(1, len(name) - 2)
            name = name[:i] + name[i + 1] + name[i] + name[i + 2:]
        add(acct, start + timedelta(days=rng.randint(0, days - 1)), 43200, "WIRE_OUT", "WIRE", "DR",
            round(rng.uniform(2000, 60000), 2), name, sdn[3])
        truth.append(("SANCTIONS_MATCH", acct.account_id))

    # 4. High-risk geography: wires to prohibited jurisdictions
    for acct in rng.sample(pool, 30):
        add(acct, start + timedelta(days=rng.randint(0, days - 1)), 50000, "WIRE_OUT", "WIRE", "DR",
            round(rng.uniform(1500, 25000), 2), "Foreign Beneficiary", rng.choice(["IR", "KP", "SY"]))
        truth.append(("HIGH_RISK_GEO", acct.account_id))

    # 5. Dormant reactivation: dormant account suddenly moves big money
    dormant = [a for a in accounts if a.dormant]
    for acct in rng.sample(dormant, min(25, len(dormant))):
        d0 = start + timedelta(days=rng.randint(0, days - 2))
        add(acct, d0, 40000, "ACH_IN", "ACH", "CR", round(rng.uniform(15000, 60000), 2), "Payroll Inc")
        add(acct, d0 + timedelta(days=1), 45000, "CASH_WDL", "BRANCH", "DR", round(rng.uniform(9000, 14000), 2))
        truth.append(("DORMANT_REACTIVATION", acct.account_id))

    # 6. Large cash (CTR threshold): single cash deposit > $10,000
    for acct in rng.sample(pool, 60):
        add(acct, start + timedelta(days=rng.randint(0, days - 1)), 39600, "CASH_DEP", "BRANCH", "CR",
            round(rng.uniform(10001, 48000), 2))
        truth.append(("LARGE_CASH_CTR", acct.account_id))

    return rows


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--accounts", type=int, default=50000)
    p.add_argument("--customers", type=int, default=None, help="default: 80%% of accounts")
    p.add_argument("--transactions", type=int, default=2000000)
    p.add_argument("--days", type=int, default=30)
    p.add_argument("--run-date", default=date.today().isoformat())
    p.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "data", "inbound"))
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args(argv)

    if args.days < 7:
        p.error("--days must be >= 7 so injected patterns fit in the window")

    rng = random.Random(args.seed)
    run_date = date.fromisoformat(args.run_date)
    start = run_date - timedelta(days=args.days)
    tag = run_date.strftime("%Y%m%d")
    os.makedirs(args.out, exist_ok=True)

    n_cust = args.customers or max(1, int(args.accounts * 0.8))
    customers = build_customers(rng, n_cust)
    accounts = build_accounts(rng, customers, args.accounts, run_date)

    def out(name):
        return os.path.join(args.out, f"{name}_{tag}.dat")

    files = {}
    files["customers"] = (out("customers"), write_rows(out("customers"),
        ["CUSTOMER_ID", "CUSTOMER_NAME", "CUSTOMER_TYPE", "DATE_OF_BIRTH", "COUNTRY_CODE",
         "STATE_CODE", "KYC_RISK_RATING", "PEP_FLAG", "ONBOARD_DATE"], customers))

    files["accounts"] = (out("accounts"), write_rows(out("accounts"),
        ["ACCOUNT_ID", "CUSTOMER_ID", "PRODUCT_TYPE", "OPEN_DATE", "ACCOUNT_STATUS", "LAST_ACTIVITY_DATE"],
        ([a.account_id, a.customer_id, a.product, a.open_date.isoformat(), a.status,
          (run_date - timedelta(days=400 if a.dormant else rng.randint(1, 30))).isoformat()] for a in accounts)))

    truth: list[tuple[str, str]] = []
    # Injected rows take sequence numbers above --transactions so ids never clash;
    # background volume is reduced by the same amount to keep the total exact.
    injected = inject_patterns(rng, accounts, start, args.days, args.transactions, truth)
    n_normal = max(0, args.transactions - len(injected))

    def all_txns():
        yield from normal_transactions(rng, accounts, start, args.days, n_normal, COUNTRIES)
        yield from injected

    files["transactions"] = (out("transactions"), write_rows(out("transactions"),
        ["TXN_ID", "ACCOUNT_ID", "TXN_TS", "TXN_TYPE", "CHANNEL", "DIRECTION", "AMOUNT", "CURRENCY",
         "COUNTERPARTY_NAME", "COUNTERPARTY_COUNTRY", "STATUS"], all_txns()))

    files["sanctions_list"] = (out("sanctions_list"), write_rows(out("sanctions_list"),
        ["SDN_ID", "PARTY_NAME", "PARTY_TYPE", "COUNTRY_CODE", "LIST_SOURCE"],
        ([s[0], s[1], s[2], s[3], "DEMO_WATCHLIST"] for s in SANCTIONED)))

    files["country_risk"] = (out("country_risk"), write_rows(out("country_risk"),
        ["COUNTRY_CODE", "RISK_TIER"], COUNTRIES))

    for path, rows in files.values():
        write_trailer_manifest(path, rows)

    truth_path = os.path.join(args.out, f"injected_patterns_{tag}.csv")
    with open(truth_path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["PATTERN", "ACCOUNT_ID"])
        w.writerows(truth)

    for name, (path, rows) in files.items():
        print(f"{name:16s} {rows:>10,d} rows -> {path}")
    print(f"{'ground_truth':16s} {len(truth):>10,d} rows -> {truth_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
