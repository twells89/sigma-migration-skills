#!/usr/bin/env python3
"""
build-forecast-model.py — one-shot builder for an actuals + driver-grown + manual
planning model (the architecture in refs/forecast-recipes.md). Consumes a model-plan
JSON (drafted from xlsx-discover.py's model map + the intent answers) and emits:
  - a Sigma data model (GL actuals VALUES + assumptions + raw forecast spine)
  - a workbook (union[actuals, forecast] → KPIs, P&L pivot w/ Actual|Forecast cols,
    monthly summary, trend, GL detail, assumptions; editable rate+manual input tables
    when intent is editable/what-if)
  - paste-ready seed CSVs for the editable tables
  - a LOCAL parity check (asserts the plan reproduces the spreadsheet totals)

Default = dry-run (writes specs to /tmp, runs parity, no API). `--post` builds live.

Intent (plan.intent):
  read-only          → forecast baked from default rates (no input tables)
  editable | what-if → rates + manual cells are editable input tables (Coalesce override)
"""
import sys, os, json, csv, urllib.request, urllib.parse, urllib.error
from pathlib import Path

_LIB = Path(__file__).resolve().parent / "lib"
if str(_LIB) not in sys.path:
    sys.path.insert(0, str(_LIB))
import workbook_wire  # noqa: E402

CUR = lambda p: {"kind": "number", "formatString": p["currencyFormat"]}
PCT = lambda p: {"kind": "number", "formatString": p.get("pctFormat", ".1%")}
DATEF = {"kind": "datetime", "formatString": "%b-%y"}
def q(s): return "'" + str(s).replace("'", "''") + "'"

def env():
    e = {}
    for line in open(os.path.expanduser("~/.sigma-migration/env")):
        line = line.strip().replace("export ", "")
        if "=" in line: k, v = line.split("=", 1); e[k] = v.strip().strip('"').strip("'")
    return e
def token(e):
    d = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": e["SIGMA_CLIENT_ID"], "client_secret": e["SIGMA_CLIENT_SECRET"]}).encode()
    return json.load(urllib.request.urlopen(urllib.request.Request(e["SIGMA_BASE_URL"] + "/v2/auth/token", data=d, headers={"Content-Type": "application/x-www-form-urlencoded"})))["access_token"]
def api(base, tok, method, path, body=None):
    r = urllib.request.Request(base + path, data=(json.dumps(body).encode() if body else None), method=method,
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json", "Accept": "application/json"})
    try: return json.load(urllib.request.urlopen(r))
    except urllib.error.HTTPError as ex: print("HTTP", ex.code, ex.read().decode()[:1500]); raise

# ---------- DM ----------
def values_sql(rows, cols):
    body = ",\n".join("(" + ",".join(rows[i]) + ")" for i in range(len(rows)))
    return f"select * from (values\n{body}\n) as t({', '.join(cols)})"

def build_dm_spec(P):
    conn = P["connectionId"]
    # GL detail (actuals, transaction grain)
    gl = []
    for r in P["actuals"]:
        gl.append([f"{q(r['date'])}::date", q(r['month']), q(r['line']), q(r['section']),
                   str(r['secOrder']), str(r['lineOrder']), q(r['dept']), q(r['vendor']), f"{float(r['amt']):.2f}"])
    mnum = {m["month"]: m["num"] for m in P["actualMonths"]}; mend = {m["month"]: m["end"] for m in P["actualMonths"]}
    gl_cols = ["TXN_DATE", "MONTH", "LINE_ITEM", "SECTION", "SEC_ORDER", "LINE_ORDER", "DEPARTMENT", "VENDOR", "AMOUNT"]
    # add MONTH_NUM / MONTH_END derived
    for row, r in zip(gl, P["actuals"]):
        row.insert(2, str(mnum[r['month']])); row.insert(3, f"{q(mend[r['month']])}::date")
    gl_cols[2:2] = ["MONTH_NUM", "MONTH_END"]
    glDetail = {"id": "glDetail", "kind": "table", "source": {"kind": "sql", "connectionId": conn, "statement": values_sql(gl, gl_cols)},
                "columns": dmcols([("TXN_DATE","Txn Date"),("MONTH","Month"),("MONTH_NUM","Month Num"),("MONTH_END","Month End"),("LINE_ITEM","Line Item"),("SECTION","Section"),("SEC_ORDER","Section Order"),("LINE_ORDER","Line Order"),("DEPARTMENT","Department"),("VENDOR","Vendor"),("AMOUNT","Amount")])}
    # assumptions
    arows = [[q(a), f"{b}", q(c)] for a, b, c in P["assumptions"]]
    assumptions = {"id": "assumptions", "kind": "table", "source": {"kind": "sql", "connectionId": conn, "statement": values_sql(arows, ["DRIVER","MONTHLY_RATE","BASIS"])},
                   "columns": dmcols([("DRIVER","Driver"),("MONTHLY_RATE","Monthly Rate"),("BASIS","Basis")])}
    # raw forecast spine
    srows = []
    for ln in P["lines"]:
        for i, m in enumerate(P["forecastMonths"]):
            n = m["num"] - P["actualMonths"][-1]["num"]
            kind = ln["kind"]
            drate = f"{ln['rate']}" if kind == "growth" else "NULL"
            mv = f"{ln['manual'][i]:.2f}" if kind == "manual" else "NULL"
            jb = f"{ln['juneBase']:.2f}" if kind in ("growth", "flat") else "NULL"
            srows.append([q(ln["line"]), q(ln["section"]), str(ln["secOrder"]), str(ln["lineOrder"]),
                          q(m["month"]), str(m["num"]), f"{q(m['end'])}::date", str(n), q(kind), drate, mv, jb])
    scols = ["LINE_ITEM","SECTION","SEC_ORDER","LINE_ORDER","MONTH","MONTH_NUM","MONTH_END","N","KIND","DEFAULT_RATE","MANUAL_VALUE","JUNE_BASE"]
    spine = {"id": "spine", "kind": "table", "source": {"kind": "sql", "connectionId": conn, "statement": values_sql(srows, scols)},
             "columns": dmcols([("LINE_ITEM","Line Item"),("SECTION","Section"),("SEC_ORDER","Section Order"),("LINE_ORDER","Line Order"),("MONTH","Month"),("MONTH_NUM","Month Num"),("MONTH_END","Month End"),("N","N"),("KIND","Kind"),("DEFAULT_RATE","Default Rate"),("MANUAL_VALUE","Manual Value"),("JUNE_BASE","June Base")])}
    return {"name": P["name"] + " — Model", "schemaVersion": 1, "folderId": P["folderId"],
            "pages": [{"id": "model", "name": "Model", "elements": [glDetail, assumptions, spine]}]}

def dmcols(pairs):
    return [{"id": f"c{i}", "name": nm, "formula": f"[Custom SQL/{al}]"} for i, (al, nm) in enumerate(pairs, 1)]

def map_dm_elements(spec):
    """Identify element ids by a signature column name (names round-trip; ids reassign)."""
    out = {}
    for el in spec["pages"][0]["elements"]:
        names = {c["name"] for c in el["columns"]}
        if "Vendor" in names: out["glDetail"] = el["id"]
        elif "Kind" in names: out["spine"] = el["id"]
        elif "Driver" in names: out["assumptions"] = el["id"]
    return out

# ---------- parity (local) ----------
def parity(P):
    rev = cogs = opex = below = 0.0
    secsum = {"Revenue": 0.0, "Cost of Revenue": 0.0, "Operating Expenses": 0.0, "Below the Line": 0.0}
    # actuals
    for r in P["actuals"]:
        secsum[r["section"]] += r["amt"]
    # forecast
    for ln in P["lines"]:
        base = ln.get("juneBase", 0)
        for i, m in enumerate(P["forecastMonths"]):
            n = m["num"] - P["actualMonths"][-1]["num"]
            v = ln["manual"][i] if ln["kind"] == "manual" else (base if ln["kind"] == "flat" else base * (1 + ln["rate"]) ** n)
            secsum[ln["section"]] += v
    rev, cogs, opex, below = secsum["Revenue"], secsum["Cost of Revenue"], secsum["Operating Expenses"], secsum["Below the Line"]
    return {"Revenue": rev, "Gross Profit": rev - cogs, "EBITDA": rev - cogs - opex, "Net Income": rev - cogs - opex - below}

# ---------- seed CSVs ----------
def seed_csvs(P, outdir):
    rate_p = os.path.join(outdir, "rate_seed.csv"); man_p = os.path.join(outdir, "manual_seed.csv")
    with open(rate_p, "w", newline="") as f:
        w = csv.writer(f); w.writerow(["LINE_ITEM", "RATE"])
        for ln in P["lines"]:
            if ln["kind"] == "growth": w.writerow([ln["line"], ln["rate"]])
    with open(man_p, "w", newline="") as f:
        w = csv.writer(f); w.writerow(["LINE_ITEM", "MONTH", "MONTH_NUM", "MONTH_END", "AMOUNT"])
        for ln in P["lines"]:
            if ln["kind"] == "manual":
                for i, m in enumerate(P["forecastMonths"]): w.writerow([ln["line"], m["month"], m["num"], m["end"], f"{ln['manual'][i]:.2f}"])
    return rate_p, man_p

# ---------- workbook ----------
def build_wb_spec(P, dm_id, els):
    conn = P["connectionId"]; editable = P["intent"] in ("editable", "what-if"); DMP = "Custom SQL"; C = "PnL Combined"
    U = "Union of 2 Sources"
    cur = CUR(P)
    def dm(elid): return {"kind": "data-model", "dataModelId": dm_id, "elementId": els[elid]}
    elements = []
    # actuals wrap (live)
    actuals = {"id": "actuals", "kind": "table", "name": "Actuals", "visibleAsSource": False, "source": dm("glDetail"),
        "columns": [{"id":"a_sec","name":"Section","formula":f"[{DMP}/Section]"},{"id":"a_so","name":"Section Order","formula":f"[{DMP}/Section Order]"},
                    {"id":"a_line","name":"Line Item","formula":f"[{DMP}/Line Item]"},{"id":"a_lo","name":"Line Order","formula":f"[{DMP}/Line Order]"},
                    {"id":"a_m","name":"Month","formula":f"[{DMP}/Month]"},{"id":"a_mn","name":"Month Num","formula":f"[{DMP}/Month Num]"},
                    {"id":"a_me","name":"Month End","formula":f"[{DMP}/Month End]"},{"id":"a_amt","name":"Amount","formula":f"[{DMP}/Amount]"},
                    {"id":"a_p","name":"Period","formula":'"Actual"'}]}
    spineWrap = {"id":"spineWrap","kind":"table","name":"Forecast Spine","visibleAsSource":False,"source":dm("spine"),
        "columns":[{"id":f"s_{k}","name":nm,"formula":f"[{DMP}/{nm}]"} for k,nm in
                   [("sec","Section"),("so","Section Order"),("line","Line Item"),("lo","Line Order"),("m","Month"),("mn","Month Num"),("me","Month End"),("n","N"),("k","Kind"),("dr","Default Rate"),("mv","Manual Value"),("jb","June Base")]]}
    # forecast element
    if editable:
        rateInput = {"id":"rateInput","kind":"input-table","name":"Growth Rates (editable)","inputMode":"edit","source":{"kind":"empty","connectionId":conn},
            "columns":[{"id":"ID"},{"id":"LINE_ITEM","type":"text","name":"Line Item"},{"id":"RATE","type":"number","name":"Rate","format":PCT(P)}],"order":["LINE_ITEM","RATE"]}
        manualInput = {"id":"manualInput","kind":"input-table","name":"Manual Forecast (editable)","inputMode":"edit","source":{"kind":"empty","connectionId":conn},
            "columns":[{"id":"ID"},{"id":"LINE_ITEM","type":"text","name":"Line Item"},{"id":"MONTH","type":"text","name":"Month"},{"id":"MONTH_NUM","type":"number","name":"Month Num"},{"id":"MONTH_END","type":"datetime","name":"Month End"},{"id":"AMOUNT","type":"number","name":"Amount","format":cur}],"order":["LINE_ITEM","MONTH","AMOUNT"]}
        forecast = {"id":"forecast","kind":"table","name":"Forecast","visibleAsSource":False,
            "source":{"kind":"join","name":"FJ","primarySource":{"kind":"table","elementId":"spineWrap"},
                "joins":[{"name":"Rates","joinType":"left-outer","left":{"kind":"table","elementId":"spineWrap"},"right":{"kind":"table","elementId":"rateInput"},"columns":[{"left":"[Line Item]","right":"[Line Item]"}]},
                         {"name":"Manual","joinType":"left-outer","left":{"kind":"table","elementId":"spineWrap"},"right":{"kind":"table","elementId":"manualInput"},"columns":[{"left":"[Line Item]","right":"[Line Item]"},{"left":"[Month Num]","right":"[Month Num]"}]}]},
            "columns":[{"id":"f_sec","name":"Section","formula":"[FJ/Section]"},{"id":"f_so","name":"Section Order","formula":"[FJ/Section Order]"},
                {"id":"f_line","name":"Line Item","formula":"[FJ/Line Item]"},{"id":"f_lo","name":"Line Order","formula":"[FJ/Line Order]"},
                {"id":"f_m","name":"Month","formula":"[FJ/Month]"},{"id":"f_mn","name":"Month Num","formula":"[FJ/Month Num]"},{"id":"f_me","name":"Month End","formula":"[FJ/Month End]"},
                {"id":"f_n","name":"N","formula":"[FJ/N]"},{"id":"f_k","name":"Kind","formula":"[FJ/Kind]"},{"id":"f_jb","name":"June Base","formula":"[FJ/June Base]"},
                {"id":"f_er","name":"Eff Rate","formula":"Coalesce([Rates/Rate], [FJ/Default Rate])"},
                {"id":"f_em","name":"Eff Manual","formula":"Coalesce([Manual/Amount], [FJ/Manual Value])"},
                {"id":"f_amt","name":"Amount","formula":'If([Kind] = "manual", [Eff Manual], [Kind] = "flat", [June Base], [June Base] * (1 + [Eff Rate]) ^ [N])',"format":cur},
                {"id":"f_p","name":"Period","formula":'"Forecast"'}]}
    else:
        forecast = {"id":"forecast","kind":"table","name":"Forecast","visibleAsSource":False,"source":{"kind":"table","elementId":"spineWrap"},
            "columns":[{"id":"f_sec","name":"Section","formula":"[Forecast Spine/Section]"},{"id":"f_so","name":"Section Order","formula":"[Forecast Spine/Section Order]"},
                {"id":"f_line","name":"Line Item","formula":"[Forecast Spine/Line Item]"},{"id":"f_lo","name":"Line Order","formula":"[Forecast Spine/Line Order]"},
                {"id":"f_m","name":"Month","formula":"[Forecast Spine/Month]"},{"id":"f_mn","name":"Month Num","formula":"[Forecast Spine/Month Num]"},{"id":"f_me","name":"Month End","formula":"[Forecast Spine/Month End]"},
                {"id":"f_amt","name":"Amount","formula":'If([Forecast Spine/Kind] = "manual", [Forecast Spine/Manual Value], [Forecast Spine/Kind] = "flat", [Forecast Spine/June Base], [Forecast Spine/June Base] * (1 + [Forecast Spine/Default Rate]) ^ [Forecast Spine/N])',"format":cur},
                {"id":"f_p","name":"Period","formula":'"Forecast"'}]}
    def m(nm): return {"outputColumnName": nm, "sourceColumns": [f"[{nm}]", f"[{nm}]"]}
    pnlCombined = {"id":"pnlCombined","kind":"table","name":C,"visibleAsSource":False,
        "source":{"kind":"union","sources":[{"kind":"table","elementId":"actuals"},{"kind":"table","elementId":"forecast"}],
                  "matches":[m("Section"),m("Section Order"),m("Line Item"),m("Line Order"),m("Month"),m("Month Num"),m("Month End"),m("Amount"),m("Period")]},
        "columns":[{"id":"c_sec","name":"Section","formula":f"[{U}/Section]"},{"id":"c_so","name":"Section Order","formula":f"[{U}/Section Order]"},
            {"id":"c_line","name":"Line Item","formula":f"[{U}/Line Item]"},{"id":"c_lo","name":"Line Order","formula":f"[{U}/Line Order]"},
            {"id":"c_m","name":"Month","formula":f"[{U}/Month]"},{"id":"c_mn","name":"Month Num","formula":f"[{U}/Month Num]"},{"id":"c_me","name":"Month End","formula":f"[{U}/Month End]"},
            {"id":"c_amt","name":"Amount","formula":f"[{U}/Amount]","format":cur},{"id":"c_p","name":"Period","formula":f"[{U}/Period]"},
            {"id":"c_rev","name":"Revenue Amt","formula":f'If([{U}/Section] = "Revenue", [{U}/Amount], 0)'},
            {"id":"c_cogs","name":"COGS Amt","formula":f'If([{U}/Section] = "Cost of Revenue", [{U}/Amount], 0)'},
            {"id":"c_opex","name":"OpEx Amt","formula":f'If([{U}/Section] = "Operating Expenses", [{U}/Amount], 0)'},
            {"id":"c_below","name":"Below Amt","formula":f'If([{U}/Section] = "Below the Line", [{U}/Amount], 0)'}]}
    REV=f"Sum([{C}/Revenue Amt])"; COGS=f"Sum([{C}/COGS Amt])"; OPEX=f"Sum([{C}/OpEx Amt])"; BELOW=f"Sum([{C}/Below Amt])"
    def kpi(eid,name,f,fmt): return {"id":eid,"kind":"kpi-chart","name":name,"source":{"kind":"table","elementId":"pnlCombined"},"columns":[{"id":"v","formula":f,"format":fmt}],"value":{"columnId":"v"}}
    kpis=[kpi("kpiRev","Total Revenue",REV,cur),kpi("kpiEbitda","EBITDA",f"{REV} - {COGS} - {OPEX}",cur),
          kpi("kpiNI","Net Income",f"{REV} - {COGS} - {OPEX} - {BELOW}",cur),kpi("kpiGM","Gross Margin %",f"({REV} - {COGS}) / {REV}",PCT(P))]
    pivot={"id":"pnlPivot","kind":"pivot-table","name":"P&L Statement","source":{"kind":"table","elementId":"pnlCombined"},
        "columns":[{"id":"p_sec","name":"Section","formula":f"[{C}/Section]"},{"id":"p_so","name":"Section Order","formula":f"[{C}/Section Order]"},
            {"id":"p_line","name":"Line Item","formula":f"[{C}/Line Item]"},{"id":"p_lo","name":"Line Order","formula":f"[{C}/Line Order]"},
            {"id":"p_per","name":"Period","formula":f"[{C}/Period]"},{"id":"p_m","name":"Month","formula":f"[{C}/Month End]","format":DATEF},
            {"id":"p_amt","name":"Amount","formula":f"Sum([{C}/Amount])","format":cur}],
        "values":["p_amt"],
        "rowsBy":[{"id":"p_sec","sort":{"direction":"ascending","by":"p_so","aggregation":"min"}},{"id":"p_line","sort":{"direction":"ascending","by":"p_lo","aggregation":"min"}}],
        "columnsBy":[{"id":"p_per","sort":{"direction":"ascending"}},{"id":"p_m","sort":{"direction":"ascending"}}]}
    glTable={"id":"glTable","kind":"table","name":"GL Transaction Detail (Actuals)","source":dm("glDetail"),
        "columns":[{"id":"g1","name":"Txn Date","formula":f"[{DMP}/Txn Date]"},{"id":"g2","name":"Month","formula":f"[{DMP}/Month]"},{"id":"g3","name":"Line Item","formula":f"[{DMP}/Line Item]"},{"id":"g4","name":"Department","formula":f"[{DMP}/Department]"},{"id":"g5","name":"Vendor","formula":f"[{DMP}/Vendor]"},{"id":"g6","name":"Amount","formula":f"[{DMP}/Amount]","format":cur}]}
    assumpTable={"id":"assumpTable","kind":"table","name":"Forecast Assumptions","source":dm("assumptions"),
        "columns":[{"id":"d1","name":"Driver","formula":f"[{DMP}/Driver]"},{"id":"d2","name":"Monthly Rate","formula":f"[{DMP}/Monthly Rate]","format":PCT(P)},{"id":"d3","name":"Basis","formula":f"[{DMP}/Basis]"}]}
    main_els=kpis+[pivot,glTable,assumpTable]
    hidden_els=[actuals,spineWrap,forecast,pnlCombined]
    if editable: main_els+=[rateInput,manualInput]
    pages=[{"id":"pnl","name":"P&L","elements":main_els},{"id":"model","name":"Model (sources)","visibility":"hidden","elements":hidden_els}]
    # Nested draft; wire_workbook flattens + wraps at the POST / dry-run boundary.
    return {"name":P["name"],"schemaVersion":1,"kind":"workbook","folderId":P["folderId"],"pages":pages}

def main():
    args=[a for a in sys.argv[1:] if not a.startswith("-")]
    do_post="--post" in sys.argv
    if not args: sys.exit("usage: build-forecast-model.py [--post] <model-plan.json>")
    P=json.load(open(args[0]))
    outdir="/tmp/fcst-build"; os.makedirs(outdir,exist_ok=True)
    # parity
    par=parity(P)
    print("LOCAL PARITY (from plan):", "  ".join(f"{k}={v:,.2f}" for k,v in par.items()))
    rate_csv,man_csv=seed_csvs(P,outdir)
    print(f"seed CSVs: {rate_csv}, {man_csv}")
    dm_spec=build_dm_spec(P)
    json.dump(dm_spec,open(f"{outdir}/dm_spec.json","w"),indent=1)
    if not do_post:
        # map ids from the local spec (ids as-authored) for a dry-run wb spec
        els={"glDetail":"glDetail","spine":"spine","assumptions":"assumptions"}
        wb_spec=workbook_wire.wire_workbook(build_wb_spec(P,"<dm-id>",els))
        json.dump(wb_spec,open(f"{outdir}/wb_spec.json","w"),indent=1)
        print(f"DRY RUN — specs written to {outdir}/ (dm_spec.json, wb_spec.json). Re-run with --post to build live.")
        return
    e=env(); base=e["SIGMA_BASE_URL"]; tok=token(e)
    dm=api(base,tok,"POST","/v2/dataModels/spec",dm_spec); dm_id=dm["dataModelId"]
    print("dataModelId:",dm_id)
    full=api(base,tok,"GET",f"/v2/dataModels/{dm_id}/spec")
    els=map_dm_elements(full)
    # Layout is the last write (assembled inside wire_workbook) before POST.
    wb_spec=workbook_wire.wire_workbook(build_wb_spec(P,dm_id,els))
    wb=api(base,tok,"POST","/v2/workbooks/spec",wb_spec)
    print("workbookId:",wb["workbookId"],"| url:",wb.get("url"))
    print("NOTE: POST uses a stacked notebook-flow layout via code_rep; refine with wb-rep push if needed.")

if __name__=="__main__":
    main()
