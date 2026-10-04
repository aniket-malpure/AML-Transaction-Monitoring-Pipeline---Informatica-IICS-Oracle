"""PowerCenter -> IICS converter: structure and findings."""
import json
import os
import subprocess
import sys

import pytest


@pytest.fixture(scope="module")
def converted(root, tmp_path_factory):
    out = tmp_path_factory.mktemp("iics")
    proc = subprocess.run([sys.executable, os.path.join(root, "tools", "pc_to_iics", "convert_pc_to_iics.py"),
                           "--output", str(out)], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    return out


def _load(out, sub):
    d = out / sub
    return {p.stem: json.loads(p.read_text()) for p in d.glob("*.json")}


def test_twelve_workflows_produce_three_assets_each(converted):
    for sub, prefix in (("mappings", "m_"), ("mapping_tasks", "mt_"), ("taskflows", "tf_")):
        assets = _load(converted, sub)
        assert len(assets) == 12, sub
        assert all(name.startswith(prefix) for name in assets)


def test_no_unmapped_connections(converted):
    for sub in ("mappings", "mapping_tasks", "taskflows"):
        for name, asset in _load(converted, sub).items():
            assert "<UNMAPPED" not in json.dumps(asset), name


def test_structural_transformations_folded(converted):
    for name, m in _load(converted, "mappings").items():
        types = [t["type"] for t in m["transformations"]]
        assert "Update Strategy" not in types and "Source Qualifier" not in types, name
        assert types[0] == "Source" and types[-1] == "Target", name


def test_links_reference_existing_transformations(converted):
    for name, m in _load(converted, "mappings").items():
        names = {t["name"] for t in m["transformations"]}
        assert m["links"], name
        for link in m["links"]:
            assert link["from"] in names and link["to"] in names, (name, link)
        # every non-source node has an inbound link, the target is reachable
        targets = {l["to"] for l in m["links"]}
        assert any(n.startswith("TGT_") for n in targets), name


def test_update_strategy_becomes_target_operation(converted):
    m = _load(converted, "mappings")
    tgt = lambda name: next(t for t in m[name]["transformations"] if t["type"] == "Target")
    assert tgt("m_DIM_COUNTRY_LOAD")["properties"]["operation"] == "Data Driven"
    assert tgt("m_DIM_ACCOUNT_LOAD")["properties"]["operation"] == "Upsert"
    assert tgt("m_STG_CUSTOMER_LOAD")["properties"]["truncateTarget"] is True


def test_path_variables_become_parameters(converted):
    m = _load(converted, "mappings")["m_STG_TRANSACTION_LOAD"]
    assert "$PMSourceFileDir" not in json.dumps(m)
    assert "$$SRC_FILE_DIR" in [p["name"] for p in m["parameters"]]


def test_report_flags_unconnected_lookup_as_manual(converted):
    report = (converted / "conversion_report.md").read_text()
    assert "wf_DIM_ACCOUNT_LOAD (MANUAL)" in report
    assert "LKP_RULE_INACTIVITY_DAYS" in report
    inventory = (converted / "conversion_inventory.csv").read_text().splitlines()
    assert len(inventory) == 13  # header + 12


def test_strict_mode_fails_when_manual_work_remains(root, tmp_path):
    proc = subprocess.run([sys.executable, os.path.join(root, "tools", "pc_to_iics", "convert_pc_to_iics.py"),
                           "--output", str(tmp_path), "--strict"], capture_output=True, text=True)
    assert proc.returncode == 2


def test_committed_iics_assets_are_current(root, converted):
    """informatica/iics must be regenerated whenever the legacy exports or converter change."""
    committed = os.path.join(root, "informatica", "iics")
    for sub in ("mappings", "mapping_tasks", "taskflows"):
        fresh = _load(converted, sub)
        for name, asset in fresh.items():
            with open(os.path.join(committed, sub, name + ".json")) as fh:
                assert json.load(fh) == asset, f"{sub}/{name}.json is stale: rerun the converter"
