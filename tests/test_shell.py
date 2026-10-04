"""Shell layer checks that run without Oracle or IICS."""
import glob
import os
import shutil
import subprocess

import pytest

SCRIPTS = ["scripts/run_aml_batch.sh", "scripts/check_ctl_file.sh", "scripts/archive_files.sh",
           "scripts/setup_db.sh", "scripts/lib/common.sh", "scripts/lib/iics.sh"]


def _env(root, tmp_path):
    env = dict(os.environ)
    env.update(AML_HOME=root, AML_LOG_DIR=str(tmp_path / "logs"), AML_RUN_DIR=str(tmp_path / "run"),
               AML_ENV_FILE="/nonexistent", STABLE_WAIT_SECONDS="0", AML_MAILER="none")
    return env


@pytest.mark.parametrize("script", SCRIPTS)
def test_bash_syntax(root, script):
    subprocess.run(["bash", "-n", os.path.join(root, script)], check=True)


@pytest.mark.skipif(not shutil.which("shellcheck"), reason="shellcheck not installed")
def test_shellcheck(root):
    subprocess.run(["shellcheck", "-x", "-S", "warning", *[os.path.join(root, s) for s in SCRIPTS]],
                   check=True, cwd=os.path.join(root, "scripts"))


def test_list_steps_without_database(root, tmp_path):
    out = subprocess.run([os.path.join(root, "scripts", "run_aml_batch.sh"), "-l"],
                         capture_output=True, text=True, env=_env(root, tmp_path), check=True).stdout
    assert "RUN_AML_RULES" in out and "STAGE_TRANSACTIONS" in out
    assert len(out.strip().splitlines()) == 16


def test_rejects_bad_date(root, tmp_path):
    proc = subprocess.run([os.path.join(root, "scripts", "run_aml_batch.sh"), "-d", "2026-13-45"],
                          capture_output=True, text=True, env=_env(root, tmp_path))
    assert proc.returncode == 2


def test_check_ctl_file_accepts_generated_files(root, dataset, tmp_path):
    files = [f"{dataset['dir']}/{n}_{dataset['tag']}.dat"
             for n in ("customers", "accounts", "transactions", "sanctions_list", "country_risk")]
    proc = subprocess.run([os.path.join(root, "scripts", "check_ctl_file.sh"), *files],
                          capture_output=True, text=True, env=_env(root, tmp_path))
    assert proc.returncode == 0, proc.stderr
    records = [l for l in proc.stdout.splitlines() if l.count("|") == 2 and not l[0].isdigit()]
    assert len(records) == 5


def test_check_ctl_file_rejects_truncated_file(root, dataset, tmp_path):
    src = f"{dataset['dir']}/country_risk_{dataset['tag']}.dat"
    bad = tmp_path / "country_risk_bad.dat"
    lines = open(src).read().splitlines(keepends=True)
    bad.write_text("".join(lines[:-2]))                 # drop rows, keep original control file
    shutil.copy(src + ".ctl", str(bad) + ".ctl")
    proc = subprocess.run([os.path.join(root, "scripts", "check_ctl_file.sh"), str(bad)],
                          capture_output=True, text=True, env=_env(root, tmp_path))
    assert proc.returncode == 1
    assert "row count" in proc.stderr


def test_check_ctl_file_rejects_missing_control(root, dataset, tmp_path):
    src = f"{dataset['dir']}/accounts_{dataset['tag']}.dat"
    lonely = tmp_path / "accounts_x.dat"
    shutil.copy(src, lonely)
    proc = subprocess.run([os.path.join(root, "scripts", "check_ctl_file.sh"), str(lonely)],
                          capture_output=True, text=True, env=_env(root, tmp_path))
    assert proc.returncode == 1 and "control file" in proc.stderr


def test_archive_moves_and_compresses(root, tmp_path):
    inbound, archive = tmp_path / "in", tmp_path / "arch"
    inbound.mkdir()
    for n in ("customers_20260930.dat", "customers_20260930.dat.ctl", "other_20260929.dat"):
        (inbound / n).write_text("x\n")
    env = _env(root, tmp_path)
    env.update(AML_INBOUND_DIR=str(inbound), AML_ARCHIVE_DIR=str(archive))
    subprocess.run([os.path.join(root, "scripts", "archive_files.sh"), "20260930"], check=True,
                   capture_output=True, env=env)
    assert sorted(os.listdir(inbound)) == ["other_20260929.dat"]
    assert len(glob.glob(str(archive / "2026" / "20260930" / "*.gz"))) == 2
