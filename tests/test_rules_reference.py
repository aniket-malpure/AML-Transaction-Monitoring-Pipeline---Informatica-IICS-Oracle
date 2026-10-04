"""Rule logic vs injected ground truth, using the Python reference model."""
import csv
import os
from collections import defaultdict
from datetime import date

import pytest

from reference_rules import jaro_winkler, load_dataset, normalize_name, run_rules


@pytest.fixture(scope="module")
def results(dataset):
    txns, accounts, tiers, sanctions = load_dataset(dataset["dir"], dataset["tag"])
    alerts = run_rules(txns, accounts, tiers, sanctions, date.fromisoformat(dataset["run_date"]))
    truth = defaultdict(set)
    path = os.path.join(dataset["dir"], f"injected_patterns_{dataset['tag']}.csv")
    for r in csv.DictReader(open(path)):
        truth[r["PATTERN"]].add(r["ACCOUNT_ID"])
    return alerts, truth


@pytest.mark.parametrize("rule", ["STRUCTURING", "LARGE_CASH_CTR", "RAPID_MOVEMENT",
                                  "SANCTIONS_MATCH", "HIGH_RISK_GEO", "DORMANT_REACTIVATION"])
def test_recall_of_injected_patterns(results, rule):
    alerts, truth = results
    found = truth[rule] & alerts[rule]
    recall = len(found) / len(truth[rule])
    assert recall >= 0.95, f"{rule}: recall {recall:.1%}, missed {sorted(truth[rule] - alerts[rule])[:5]}"


@pytest.mark.parametrize("rule", ["STRUCTURING", "SANCTIONS_MATCH", "HIGH_RISK_GEO", "DORMANT_REACTIVATION"])
def test_no_false_positives_on_clean_accounts(results, rule):
    """Background traffic is generated to stay clear of these scenarios."""
    alerts, truth = results
    suspicious = set().union(*truth.values())
    fp = alerts[rule] - suspicious
    assert not fp, f"{rule}: {len(fp)} unexpected alert(s), e.g. {sorted(fp)[:5]}"


def test_overall_false_positive_rate_is_low(results, dataset):
    alerts, truth = results
    suspicious = set().union(*truth.values())
    flagged = set().union(*alerts.values())
    fp = flagged - suspicious
    assert len(fp) / 5000 < 0.01, f"{len(fp)} clean accounts alerted"


def test_normalize_name_matches_plsql_behaviour():
    assert normalize_name("Halcyon Maritime Trading, L.L.C.") == "HALCYON MARITIME TRADING"
    assert normalize_name("  Taurus  Offshore Holdings Ltd ") == "TAURUS OFFSHORE HOLDINGS"
    assert normalize_name("Golden Crescent Exchange House") == "GOLDEN CRESCENT EXCHANGE HOUSE"
    assert normalize_name(None) is None


def test_jaro_winkler_reference_values():
    # Classic published examples (Winkler 1990)
    assert jaro_winkler("MARTHA", "MARHTA") == 96
    assert jaro_winkler("DWAYNE", "DUANE") == 84
    assert jaro_winkler("DIXON", "DICKSONX") == 81
    assert jaro_winkler("SAME", "SAME") == 100
    # A one-letter transposition in a watchlist name must still clear the 90 threshold
    assert jaro_winkler("HALCYON MARITME TRADING", "HALCYON MARITIME TRADING") >= 90
    # An unrelated name sharing the first letter must not
    assert jaro_winkler("HARBOR SUPPLIES", "HALCYON MARITIME TRADING") < 90
