"""Shared fixtures: one small generated dataset reused by every test module."""
import os
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))

RUN_DATE = "2026-09-30"
TAG = RUN_DATE.replace("-", "")


@pytest.fixture(scope="session")
def root():
    return ROOT


@pytest.fixture(scope="session")
def dataset(tmp_path_factory):
    out = tmp_path_factory.mktemp("inbound")
    subprocess.run(
        [sys.executable, os.path.join(ROOT, "data_generator", "generate_transactions.py"),
         "--accounts", "5000", "--transactions", "120000", "--days", "30",
         "--run-date", RUN_DATE, "--out", str(out), "--seed", "7"],
        check=True, capture_output=True, text=True)
    return {"dir": str(out), "tag": TAG, "run_date": RUN_DATE}
