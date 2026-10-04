"""Generator output contract: files, control trailers, schema alignment with the loaders."""
import csv
import hashlib
import os
import re

FILES = ["customers", "accounts", "transactions", "sanctions_list", "country_risk"]
CTL_FOR = {"customers": "stg_customer", "accounts": "stg_account", "transactions": "stg_transaction",
           "sanctions_list": "stg_sanctions", "country_risk": "stg_country_risk"}


def _path(ds, name):
    return os.path.join(ds["dir"], f"{name}_{ds['tag']}.dat")


def _rows(path):
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.reader(fh, delimiter="|"))


def test_all_files_and_control_trailers(dataset):
    for name in FILES:
        path = _path(dataset, name)
        assert os.path.getsize(path) > 0
        ctl = dict(line.strip().split("=", 1) for line in open(path + ".ctl") if "=" in line)
        assert int(ctl["ROWS"]) == len(_rows(path)) - 1, name
        assert ctl["MD5"] == hashlib.md5(open(path, "rb").read()).hexdigest(), name


def test_header_matches_sqlldr_field_order(dataset, root):
    """SQL*Loader maps by position, so the file header must match the .ctl field list."""
    for name in FILES:
        header = _rows(_path(dataset, name))[0]
        ctl_text = open(os.path.join(root, "sqlldr", CTL_FOR[name] + ".ctl")).read()
        body = ctl_text[ctl_text.index("(", ctl_text.index("TRAILING NULLCOLS")) + 1: ctl_text.rindex(")")]
        fields = [re.split(r"\s+", line.strip())[0].rstrip(",") for line in body.splitlines() if line.strip()]
        file_fields = [f for f in fields if f not in ("BATCH_ID", "SRC_FILE_NAME", "LOAD_TS")]
        assert file_fields == header, name


def test_header_columns_exist_in_staging_ddl(dataset, root):
    ddl = open(os.path.join(root, "sql", "01_ddl", "02_staging.sql")).read().upper()
    for name in FILES:
        table = CTL_FOR[name].upper()
        block = ddl[ddl.index(f"CREATE TABLE {table} ("):]
        block = block[: block.index(";")]
        for col in _rows(_path(dataset, name))[0]:
            assert re.search(rf"\b{col}\b", block), f"{table}.{col} missing from DDL"


def test_transactions_are_well_formed(dataset):
    rows = _rows(_path(dataset, "transactions"))
    header, data = rows[0], rows[1:]
    idx = {c: i for i, c in enumerate(header)}
    ids = [r[idx["TXN_ID"]] for r in data]
    assert len(ids) == len(set(ids)), "duplicate TXN_ID"
    assert len(data) == 120000
    for r in data[:5000] + data[-2000:]:
        assert float(r[idx["AMOUNT"]]) >= 0
        assert r[idx["DIRECTION"]] in ("CR", "DR")
        assert re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", r[idx["TXN_TS"]])


def test_every_transaction_account_exists(dataset):
    accts = {r[0] for r in _rows(_path(dataset, "accounts"))[1:]}
    txn_accts = {r[1] for r in _rows(_path(dataset, "transactions"))[1:]}
    assert txn_accts <= accts


def test_ground_truth_written(dataset):
    path = os.path.join(dataset["dir"], f"injected_patterns_{dataset['tag']}.csv")
    rows = list(csv.DictReader(open(path)))
    patterns = {r["PATTERN"] for r in rows}
    assert patterns == {"STRUCTURING", "RAPID_MOVEMENT", "SANCTIONS_MATCH", "HIGH_RISK_GEO",
                        "DORMANT_REACTIVATION", "LARGE_CASH_CTR"}


def test_deterministic_with_seed(tmp_path, root):
    import subprocess, sys
    outs = []
    for i in range(2):
        d = tmp_path / str(i)
        subprocess.run([sys.executable, os.path.join(root, "data_generator", "generate_transactions.py"),
                        "--accounts", "200", "--transactions", "5000", "--days", "10",
                        "--run-date", "2026-01-31", "--out", str(d), "--seed", "99"], check=True, capture_output=True)
        outs.append(open(d / "transactions_20260131.dat.ctl").read())
    assert outs[0] == outs[1]
