#!/usr/bin/env python3
"""
PowerCenter -> IICS (Cloud Data Integration) conversion assistant.

Reads PowerCenter workflow XML exports (pmrep objectexport / Repository
Manager export) and produces, per workflow:

  mappings/m_<name>.json        IICS mapping definition (Source/Target merged
                                with their qualifiers, Update Strategy folded
                                into the target operation)
  mapping_tasks/mt_<name>.json  mapping task: connections, parameter file,
                                pre/post SQL, file locations, commands
  taskflows/tf_<name>.json      taskflow equivalent of the workflow

plus conversion_report.md and conversion_inventory.csv describing what was
converted automatically and what needs a developer's attention.

The JSON files are a readable, diffable specification of the IICS assets.
They are used to (a) review the conversion in a pull request and (b) drive
the build in IICS, either by hand in the Mapping Designer or by templating
them into an IICS export package.

Usage:
  python convert_pc_to_iics.py --input ../../informatica/powercenter_legacy \
      --output ../../informatica/iics --conn-map connection_map.json [--strict]

Exit codes: 0 ok, 1 bad input, 2 --strict and at least one MANUAL item.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import datetime, timezone

# --------------------------------------------------------------------------- rules
AUTO, WARN, MANUAL = "AUTO", "AUTO_WITH_WARNINGS", "MANUAL"
_SEVERITY = {AUTO: 0, WARN: 1, MANUAL: 2}

# PowerCenter transformation type -> IICS transformation type
TRANSFORM_MAP = {
    "Expression": "Expression",
    "Filter": "Filter",
    "Lookup Procedure": "Lookup",
    "Router": "Router",
    "Aggregator": "Aggregator",
    "Joiner": "Joiner",
    "Sorter": "Sorter",
    "Sequence": "Sequence",
    "Union Transformation": "Union",
    "Normalizer": "Normalizer",
    "Rank": "Rank",
    "Stored Procedure": "SQL",
}
# Handled structurally rather than copied 1:1
STRUCTURAL = {"Source Qualifier", "Update Strategy", "Source Definition", "Target Definition"}

# PowerCenter port datatypes -> IICS field types
DATATYPE_MAP = {
    "string": "string", "nstring": "string", "text": "string", "ntext": "string",
    "decimal": "decimal", "double": "double", "integer": "integer", "small integer": "integer",
    "bigint": "bigint", "date/time": "date/time", "binary": "binary",
}

# PowerCenter functions with no IICS equivalent or different semantics
UNSUPPORTED_FUNCTIONS = {"SETVARIABLE": "Use an in-out parameter with Aggregation type instead",
                         "SETMAXVARIABLE": "Use an in-out parameter (Aggregation=Max)",
                         "SETMINVARIABLE": "Use an in-out parameter (Aggregation=Min)",
                         "SETCOUNTVARIABLE": "Use an in-out parameter (Aggregation=Count)"}


@dataclass
class Finding:
    level: str
    obj: str
    message: str


@dataclass
class ConversionResult:
    workflow: str
    source_file: str
    mapping: str = ""
    session: str = ""
    transformations: int = 0
    expressions: int = 0
    findings: list[Finding] = field(default_factory=list)

    @property
    def status(self) -> str:
        worst = max((_SEVERITY[f.level] for f in self.findings), default=0)
        return [AUTO, WARN, MANUAL][worst]

    def add(self, level: str, obj: str, msg: str) -> None:
        self.findings.append(Finding(level, obj, msg))


# --------------------------------------------------------------------- helpers
def attrs(el: ET.Element, tag: str = "TABLEATTRIBUTE") -> dict[str, str]:
    return {a.get("NAME"): a.get("VALUE", "") for a in el.findall(tag)}


def ports(el: ET.Element, tag: str) -> list[dict]:
    out = []
    for f in el.findall(tag):
        d = {"name": f.get("NAME"),
             "type": DATATYPE_MAP.get((f.get("DATATYPE") or "").lower(), (f.get("DATATYPE") or "").lower()),
             "precision": int(f.get("PRECISION") or 0),
             "scale": int(f.get("SCALE") or 0)}
        if f.get("PORTTYPE"):
            d["portType"] = f.get("PORTTYPE")
        if f.get("EXPRESSION") is not None:
            d["expression"] = f.get("EXPRESSION")
        out.append(d)
    return out


def replace_path_vars(text: str, path_vars: dict[str, str]) -> str:
    # longest first so "$PMRootDir/Scripts" wins over "$PMRootDir"
    for k in sorted(path_vars, key=len, reverse=True):
        text = text.replace(k, path_vars[k])
    return text


def convert_expression(expr: str, obj: str, res: ConversionResult) -> str:
    """Translate a PowerCenter expression to IICS syntax and record findings."""
    res.expressions += 1
    new = expr

    for fn, advice in UNSUPPORTED_FUNCTIONS.items():
        if re.search(rf"\b{fn}\s*\(", new, re.I):
            res.add(MANUAL, obj, f"{fn}() is not supported in IICS. {advice}.")

    if ":LKP." in new.upper():
        names = sorted(set(re.findall(r":LKP\.(\w+)", new, re.I)))
        res.add(MANUAL, obj, f"Unconnected lookup call {', '.join(names)}: create an unconnected Lookup "
                             "transformation with a return field in the IICS mapping; the :LKP. syntax is kept.")
    if ":SP." in new.upper():
        res.add(MANUAL, obj, "Unconnected stored procedure call (:SP.) must be rebuilt as a SQL transformation.")

    if "SESSSTARTTIME" in new.upper():
        res.add(WARN, obj, "SESSSTARTTIME is evaluated on the Secure Agent clock in IICS; confirm time zone (UTC vs EST).")

    # Session-state variables are not available in CDI expressions
    if re.search(r"\$PM\w+@\w+", new):
        res.add(MANUAL, obj, "Session/task variable reference ($PMxxx@yyy) has no CDI equivalent.")
    return new


def update_strategy_to_operation(expr: str, session_attrs: dict[str, str]) -> tuple[str, str | None]:
    """Fold an Update Strategy expression into an IICS target operation."""
    e = re.sub(r"\s+", "", expr.upper())
    upsert = session_attrs.get("Update else Insert", "").upper() == "YES"
    if e in ("DD_INSERT", "0"):
        return "Insert", None
    if e in ("DD_UPDATE", "1"):
        return ("Upsert" if upsert else "Update"), None
    if e in ("DD_DELETE", "2"):
        return "Delete", None
    if e in ("DD_REJECT", "3"):
        return "None", None
    return "Data Driven", expr


# --------------------------------------------------------------------- convert
def convert_file(path: str, cfg: dict) -> tuple[ConversionResult, dict, dict, dict] | None:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        print(f"ERROR: cannot parse {path}: {exc}", file=sys.stderr)
        return None

    folder = root.find(".//FOLDER")
    wf_el = folder.find("WORKFLOW") if folder is not None else None
    map_el = folder.find("MAPPING") if folder is not None else None
    ses_el = folder.find("SESSION") if folder is not None else None
    if wf_el is None or map_el is None or ses_el is None:
        print(f"ERROR: {path} must contain one WORKFLOW, MAPPING and SESSION", file=sys.stderr)
        return None

    conn_map: dict = cfg["connections"]
    path_vars: dict = cfg["path_variables"]
    res = ConversionResult(workflow=wf_el.get("NAME"), source_file=os.path.basename(path),
                           mapping=map_el.get("NAME"), session=ses_el.get("NAME"))
    ses_attrs = attrs(ses_el, "ATTRIBUTE")

    sources = {s.get("NAME"): s for s in folder.findall("SOURCE")}
    targets = {t.get("NAME"): t for t in folder.findall("TARGET")}
    trans = {t.get("NAME"): t for t in map_el.findall("TRANSFORMATION")}
    instances = {i.get("NAME"): i for i in map_el.findall("INSTANCE")}

    # instances referenced but not defined in the export (e.g. reusable/unconnected)
    for name, inst in instances.items():
        if inst.get("TYPE") == "TRANSFORMATION" and name not in trans:
            res.add(MANUAL, name, f"{inst.get('TRANSFORMATION_TYPE')} '{name}' is referenced but not in the export "
                                  "(reusable or unconnected). Export it with dependencies or rebuild it in IICS.")

    # ---- instance-level graph from connectors
    edges: list[tuple[str, str]] = []
    field_links: list[dict] = []
    for c in map_el.findall("CONNECTOR"):
        e = (c.get("FROMINSTANCE"), c.get("TOINSTANCE"))
        if e not in edges:
            edges.append(e)
        field_links.append({"from": c.get("FROMINSTANCE"), "fromField": c.get("FROMFIELD"),
                            "to": c.get("TOINSTANCE"), "toField": c.get("TOFIELD")})

    rename: dict[str, str] = {}      # PC instance -> IICS transformation name
    dropped: set[str] = set()
    iics_trans: list[dict] = []
    target_operation, dd_condition = "Insert", None

    # ---- sources (merge Source Qualifier properties into the IICS Source)
    for sname, sel in sources.items():
        is_file = sel.get("DATABASETYPE") == "Flat File"
        sq_name = next((b for a, b in edges if a == sname and instances.get(b, {}).get("TRANSFORMATION_TYPE") == "Source Qualifier"), None)
        sq_attrs = attrs(trans[sq_name]) if sq_name in trans else {}
        props: dict = {}
        if is_file:
            ff = sel.find("FLATFILE")
            props["format"] = {"type": "Delimited", "delimiter": ff.get("DELIMITERS") if ff is not None else ",",
                               "headerLines": int(ff.get("SKIPROWS", "0")) if ff is not None else 0,
                               "textQualifier": "None"}
            props["fileDirectory"] = replace_path_vars(ses_attrs.get("Source file directory", ""), path_vars)
            props["fileName"] = ses_attrs.get("Source filename", sname)
            if "$PMSourceFileDir" in ses_attrs.get("Source file directory", ""):
                res.add(WARN, sname, "Source directory used $PMSourceFileDir; mapped to in-out parameter $$SRC_FILE_DIR "
                                     "(set in the parameter file / flat-file connection).")
        else:
            props["object"] = sname
        if sq_attrs.get("Sql Query"):
            props["sourceType"] = "Query"
            props["query"] = sq_attrs["Sql Query"]
            res.add(WARN, sq_name, "SQL override carried over as a Query source. Re-validate the field order "
                                   "against the query's select list in the Mapping Designer.")
        elif sq_attrs.get("Source Filter"):
            props["filter"] = sq_attrs["Source Filter"]
        src_conn = next((cr.get("CONNECTIONNAME") for ext in ses_el.findall("SESSIONEXTENSION")
                         if ext.get("TYPE") == "READER" for cr in ext.findall("CONNECTIONREFERENCE")), None)
        if src_conn not in conn_map:
            res.add(MANUAL, sname, f"No IICS connection mapped for PowerCenter connection '{src_conn}'.")
        iics_name = "SRC_" + sname
        iics_trans.append({"name": iics_name, "type": "Source",
                           "connection": conn_map.get(src_conn, f"<UNMAPPED:{src_conn}>"),
                           "properties": props,
                           "fields": ports(sel, "SOURCEFIELD") if not sq_name else ports(trans[sq_name], "TRANSFORMFIELD")})
        rename[sname] = iics_name
        if sq_name:
            rename[sq_name] = iics_name
            dropped.add(sq_name)

    # ---- mid-stream transformations
    for tname, tel in trans.items():
        ttype = tel.get("TYPE")
        if ttype == "Source Qualifier":
            continue
        tattrs = attrs(tel)
        if ttype == "Update Strategy":
            target_operation, dd_condition = update_strategy_to_operation(
                tattrs.get("Update Strategy Expression", "DD_INSERT"), ses_attrs)
            dropped.add(tname)
            if dd_condition:
                res.add(WARN, tname, "Conditional Update Strategy folded into target operation 'Data Driven' "
                                     f"with condition: {dd_condition}")
            continue
        iics_type = TRANSFORM_MAP.get(ttype)
        if not iics_type:
            res.add(MANUAL, tname, f"No automatic conversion for transformation type '{ttype}'.")
            iics_type = f"<UNSUPPORTED:{ttype}>"
        res.transformations += 1

        fields = ports(tel, "TRANSFORMFIELD")
        for f in fields:
            if "expression" in f:
                f["expression"] = convert_expression(f["expression"], f"{tname}.{f['name']}", res)
                if f.get("portType") == "LOCAL VARIABLE":
                    f["portType"] = "VARIABLE"

        props: dict = {}
        if ttype == "Filter":
            props["filterCondition"] = convert_expression(tattrs.get("Filter Condition", "TRUE"), tname, res)
        elif ttype == "Lookup Procedure":
            props = {"lookupObject": tattrs.get("Lookup table name"),
                     "lookupCondition": tattrs.get("Lookup condition"),
                     "multipleMatches": tattrs.get("Lookup policy on multiple match", "Return Any"),
                     "cache": tattrs.get("Lookup caching enabled", "YES") == "YES",
                     "connection": conn_map.get("ORA_AML_DW")}
            if tattrs.get("Lookup Sql Override"):
                props["lookupSqlOverride"] = tattrs["Lookup Sql Override"]
                res.add(WARN, tname, "Lookup SQL override kept; IICS requires override columns to match lookup field names.")
        elif ttype == "Router":
            props["outputGroups"] = [{"name": g.get("NAME"), "condition": convert_expression(g.get("EXPRESSION", ""), tname, res)}
                                     for g in tel.findall("GROUP")] + [{"name": "DEFAULT", "condition": None}]
        elif ttype == "Sorter":
            props["sortKeys"] = [{"field": k.split()[0], "order": (k.split() + ["ASC"])[1].upper()}
                                 for k in tattrs.get("Sorter Key", "").split(",") if k.strip()]
            props["distinct"] = tattrs.get("Distinct", "NO") == "YES"
        elif ttype == "Sequence":
            props = {"initialValue": int(tattrs.get("Start Value", "1")), "incrementBy": int(tattrs.get("Increment By", "1")),
                     "cycle": False}
            res.add(WARN, tname, "Sequence state does not migrate. Set the initial value to MAX(key)+1 from the "
                                 "target table, or switch to an Oracle identity column.")
        elif ttype == "Stored Procedure":
            props = {"sqlType": "Stored Procedure", "storedProcedure": tattrs.get("Stored Procedure Name"),
                     "connection": conn_map.get(tattrs.get("Connection Information", "ORA_AML_DW"))}
            res.add(WARN, tname, "Stored Procedure transformation converted to a SQL transformation "
                                 f"calling {tattrs.get('Stored Procedure Name')}. Verify parameter binding.")
        elif ttype == "Expression":
            pass
        else:
            props = tattrs

        if tname in [i for i, inst in instances.items() if inst.get("ISUNCONNECTED") == "YES"]:
            props["unconnected"] = True
        iics_trans.append({"name": tname, "type": iics_type, "properties": props, "fields": fields})
        rename[tname] = tname

    # ---- target
    tgt_conn = next((cr.get("CONNECTIONNAME") for ext in ses_el.findall("SESSIONEXTENSION")
                     if ext.get("TYPE") == "WRITER" for cr in ext.findall("CONNECTIONREFERENCE")), None)
    if tgt_conn not in conn_map:
        res.add(MANUAL, "target", f"No IICS connection mapped for PowerCenter connection '{tgt_conn}'.")
    for tname, tel in targets.items():
        is_file = tel.get("DATABASETYPE") == "Flat File"
        tprops: dict = {"operation": "Insert" if is_file else target_operation}
        if dd_condition:
            tprops["dataDrivenCondition"] = dd_condition
        if is_file:
            tprops["fileDirectory"] = replace_path_vars(ses_attrs.get("Output file directory", ""), path_vars)
            tprops["fileName"] = ses_attrs.get("Output filename", tname)
            tprops["header"] = ses_attrs.get("Header Options", "") == "Output Field Names"
        else:
            tprops["object"] = tname
            tprops["truncateTarget"] = ses_attrs.get("Truncate target table option", "NO") == "YES"
            if ses_attrs.get("Target load type") == "Bulk":
                tprops["advanced"] = {"loadMode": "Bulk"}
                res.add(WARN, tname, "Bulk load mode: confirm the Oracle connector bulk option is licensed/enabled "
                                     "and that no indexes/triggers on the target block direct-path load.")
        iics_trans.append({"name": "TGT_" + tname, "type": "Target",
                           "connection": conn_map.get(tgt_conn, f"<UNMAPPED:{tgt_conn}>"),
                           "properties": tprops, "fields": ports(tel, "TARGETFIELD")})
        rename[tname] = "TGT_" + tname

    # ---- rewire links around dropped nodes (SQ merged, Update Strategy folded)
    def resolve_forward(node: str) -> list[str]:
        if node not in dropped or rename.get(node, node).startswith("SRC_"):
            return [rename.get(node, node)]
        outs = [b for a, b in edges if a == node]
        return [r for b in outs for r in resolve_forward(b)]

    links = []
    for a, b in edges:
        if a in dropped and not rename.get(a, "").startswith("SRC_"):
            continue  # its outbound edges are re-attached from its predecessor
        for tgt in resolve_forward(b):
            pair = {"from": rename.get(a, a), "to": tgt}
            if pair["from"] != pair["to"] and pair not in links:
                links.append(pair)

    # field rules for the target: incoming field -> target field
    target_fields = [fl for fl in field_links if fl["to"] in targets]
    for fl in target_fields:
        fl["from"] = rename.get(fl["from"], fl["from"])
        fl["to"] = rename.get(fl["to"], fl["to"])

    params = [{"name": v.get("NAME"), "type": DATATYPE_MAP.get(v.get("DATATYPE"), v.get("DATATYPE")),
               "usage": "In-Out", "defaultValue": v.get("DEFAULTVALUE", "")}
              for v in map_el.findall("MAPPINGVARIABLE") if v.get("ISPARAM") == "YES"]
    # path variables we introduced become parameters too
    introduced = sorted({pv for pv in path_vars.values()
                         if any(pv in json.dumps(t["properties"]) for t in iics_trans)})
    params += [{"name": p, "type": "string", "usage": "In-Out", "defaultValue": ""} for p in introduced
               if p not in [x["name"] for x in params]]

    base = res.mapping[2:] if res.mapping.startswith("m_") else res.mapping
    mapping_json = {
        "assetType": "MAPPING",
        "name": res.mapping,
        "projectFolder": f"{cfg['project_folder']}/Mappings",
        "description": f"Converted from PowerCenter {res.source_file} ({res.mapping})",
        "parameters": params,
        "transformations": iics_trans,
        "links": links,
        "targetFieldMapping": [{"from": f"{fl['from']}.{fl['fromField']}", "to": fl["toField"]} for fl in target_fields],
    }

    # ---- mapping task
    pre_sql = ses_attrs.get("Pre SQL", "")
    post_sql = ses_attrs.get("Post SQL", "")
    post_cmd = replace_path_vars(ses_attrs.get("Post-session success command", ""), path_vars)
    if post_cmd:
        res.add(WARN, res.session, "Post-session command moved to the mapping task postprocessing command; "
                                   "the script must exist on the Secure Agent host.")
    mt_json = {
        "assetType": "MTT",
        "name": f"mt_{base}",
        "projectFolder": f"{cfg['project_folder']}/MappingTasks",
        "mapping": res.mapping,
        "runtimeEnvironment": cfg["runtime_environment"],
        "parameterFile": cfg["parameter_file"],
        "sessionProperties": {
            "stopOnErrors": int(ses_attrs.get("Stop on errors", "0")),
            "commitInterval": int(ses_attrs.get("Commit Interval", "10000")),
            "preSql": pre_sql,
            "postSql": post_sql,
            "postProcessingCommand": post_cmd,
        },
        "schedule": None,
    }
    if ses_attrs.get("Enable high precision") == "YES":
        mt_json["sessionProperties"]["enableHighPrecision"] = True

    # ---- taskflow
    steps = []
    for t in wf_el.findall("TASK"):
        if t.get("TYPE") == "Command":
            cmds = [replace_path_vars(v.get("VALUE", ""), path_vars) for v in t.findall("VALUEPAIR")]
            steps.append({"name": t.get("NAME"), "type": "CommandTask",
                          "runtimeEnvironment": cfg["runtime_environment"], "commands": cmds, "onError": "Fail"})
            res.add(WARN, t.get("NAME"), "Command task converted to a taskflow Command Task; it runs on the "
                                         "Secure Agent, so script paths and permissions must be redeployed there.")
    steps.append({"name": f"DT_{base}", "type": "DataTask", "task": mt_json["name"], "onError": "Fail",
                  "inputParameters": {p["name"]: f"{{{{{p['name'].strip('$')}}}}}" for p in params}})
    for wl in wf_el.findall("WORKFLOWLINK"):
        cond = wl.get("CONDITION", "")
        if cond and "Status = SUCCEEDED" not in cond:
            res.add(MANUAL, wf_el.get("NAME"), f"Custom link condition '{cond}' needs a Decision step.")
    tf_json = {
        "assetType": "TASKFLOW",
        "name": "tf_" + (res.workflow[3:] if res.workflow.startswith("wf_") else res.workflow),
        "projectFolder": f"{cfg['project_folder']}/Taskflows",
        "description": f"Converted from PowerCenter workflow {res.workflow}",
        "inputParameters": [{"name": p["name"].strip("$"), "type": "text"} for p in params],
        "steps": steps,
    }
    return res, mapping_json, mt_json, tf_json


# ---------------------------------------------------------------------- report
def write_report(results: list[ConversionResult], out_dir: str) -> None:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    counts = {s: sum(1 for r in results if r.status == s) for s in (AUTO, WARN, MANUAL)}
    lines = [
        "# PowerCenter to IICS conversion report", "",
        f"Generated {now} by `tools/pc_to_iics/convert_pc_to_iics.py`.", "",
        "| Workflows | Auto | Auto with warnings | Manual follow-up | Transformations | Expressions |",
        "|---|---|---|---|---|---|",
        f"| {len(results)} | {counts[AUTO]} | {counts[WARN]} | {counts[MANUAL]} | "
        f"{sum(r.transformations for r in results)} | {sum(r.expressions for r in results)} |", "",
        "## By workflow", "",
        "| PowerCenter workflow | IICS mapping | Status | Findings |", "|---|---|---|---|",
    ]
    for r in results:
        lines.append(f"| {r.workflow} | {r.mapping} | {r.status} | {len(r.findings)} |")
    lines += ["", "## Findings", ""]
    for r in results:
        if not r.findings:
            continue
        lines.append(f"### {r.workflow} ({r.status})")
        lines.append("")
        for f in sorted(r.findings, key=lambda x: -_SEVERITY[x.level]):
            lines.append(f"- **{f.level}** `{f.obj}`: {f.message}")
        lines.append("")
    with open(os.path.join(out_dir, "conversion_report.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    with open(os.path.join(out_dir, "conversion_inventory.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["pc_workflow", "pc_mapping", "pc_session", "iics_mapping", "iics_mapping_task", "iics_taskflow",
                    "status", "transformations", "expressions", "warnings", "manual_items"])
        for r in results:
            base = r.mapping[2:]
            w.writerow([r.workflow, r.mapping, r.session, r.mapping, f"mt_{base}", "tf_" + r.workflow[3:], r.status,
                        r.transformations, r.expressions,
                        sum(1 for f in r.findings if f.level == WARN),
                        sum(1 for f in r.findings if f.level == MANUAL)])


def main(argv=None) -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", default=os.path.join(here, "..", "..", "informatica", "powercenter_legacy"))
    p.add_argument("--output", default=os.path.join(here, "..", "..", "informatica", "iics"))
    p.add_argument("--conn-map", default=os.path.join(here, "connection_map.json"))
    p.add_argument("--strict", action="store_true", help="exit 2 if any workflow needs manual work")
    args = p.parse_args(argv)

    with open(args.conn_map, encoding="utf-8") as fh:
        cfg = json.load(fh)

    xmls = sorted(f for f in os.listdir(args.input) if f.lower().endswith(".xml"))
    if not xmls:
        print(f"ERROR: no .xml exports in {args.input}", file=sys.stderr)
        return 1

    for sub in ("mappings", "mapping_tasks", "taskflows"):
        os.makedirs(os.path.join(args.output, sub), exist_ok=True)

    results = []
    for x in xmls:
        conv = convert_file(os.path.join(args.input, x), cfg)
        if conv is None:
            return 1
        res, m, mt, tf = conv
        for sub, obj in (("mappings", m), ("mapping_tasks", mt), ("taskflows", tf)):
            with open(os.path.join(args.output, sub, obj["name"] + ".json"), "w", encoding="utf-8") as fh:
                json.dump(obj, fh, indent=2)
                fh.write("\n")
        results.append(res)
        print(f"{res.status:20s} {res.workflow:34s} -> {m['name']}, {mt['name']}, {tf['name']}")

    write_report(results, args.output)
    manual = sum(1 for r in results if r.status == MANUAL)
    print(f"\n{len(results)} workflow(s) converted; {manual} need manual follow-up. "
          f"See {os.path.normpath(os.path.join(args.output, 'conversion_report.md'))}")
    return 2 if (args.strict and manual) else 0


if __name__ == "__main__":
    sys.exit(main())
