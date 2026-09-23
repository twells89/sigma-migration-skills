#!/usr/bin/env python3
"""batch-migrate — migrate many Qlik apps to Sigma workbooks in one pass.

    python3 batch-migrate.py --apps apps.txt --out-layout-dir /tmp/lay
      apps.txt: one "appId|App Name" per line

For each app, builds a Sigma workbook (reusing an existing data model) with an Overview page
(KPIs + bar/line charts), auto-lays-it-out via the layout heuristic, and prints the URL.
Demonstrates tenant-scale migration. Reuses DM/denorm element (set below) since the demo apps
share data; for distinct apps, discover per-app and build per-app specs.

Includes `auto_layout()` — the reusable layout heuristic (header band + KPI band + chart
rows, each a canonical <Container> band per layout-playbook.md) returning (24-col grid
XML, container/header spec elements). The spec elements MUST be in the POSTed spec or
the containers are silently dropped.
"""
import json, os, sys, urllib.request, subprocess, re, argparse
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import code_rep  # workbook code-rep document-wrapper adapter (nested POST shape)

BASE=os.environ["SIGMA_BASE_URL"]; TOK=os.environ["SIGMA_API_TOKEN"]
# Reuse an existing Sigma data model: set these to YOUR ids (from the data-model build
# step or the Sigma UI), or pass --data-model / --denorm-element / --folder. No real ids baked in.
DM=os.environ.get("SIGMA_DM_ID",""); DENORM=os.environ.get("SIGMA_DENORM_ELEMENT_ID",""); FOLDER=os.environ.get("SIGMA_FOLDER_ID","")
PUTLAYOUT=os.path.join(os.path.dirname(os.path.abspath(__file__)),"put_layout.py")
def post(p,b):
    r=urllib.request.Request(BASE+p,data=json.dumps(b).encode(),method="POST",headers={"Authorization":"Bearer "+TOK,"Content-Type":"application/json"})
    try: return urllib.request.urlopen(r).read().decode()
    except urllib.error.HTTPError as e: print("HTTP",e.code,e.read().decode()[:400],file=sys.stderr); return None
N=lambda f:{"kind":"number","formatString":f}

def auto_layout(page_id, elems, title="Overview"):
    """elems: ordered list of {id, kind}. Header band + KPI band + chart rows, each a
    full-width Container (children container-relative). Returns (xml, extra_spec_elements)."""
    kpis=[e for e in elems if e["kind"]=="kpi-chart"]; charts=[e for e in elems if e["kind"]!="kpi-chart"]
    def le(eid,c0,c1,r0,r1): return f'  <Element elementId="{eid}" gridColumn="{c0} / {c1}" gridRow="{r0} / {r1}"/>'
    def gc(cid,r0,r1,inner):
        return (f'<Container elementId="{cid}" type="grid" gridColumn="1 / 25" gridRow="{r0} / {r1}" '
                f'gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">\n{inner}\n</Container>')
    extra=[{"id":"band-hdr","kind":"container","style":{"backgroundColor":"#0F172A","borderRadius":"round"}},
           {"id":"band-hdrtext","kind":"text","body":f'# <span style="color: #FFFFFF">{title}</span>'}]
    bands=[gc("band-hdr",1,4,le("band-hdrtext",1,25,1,4))]
    row=4
    if kpis:
        w=24//len(kpis); inner=[]
        for i,e in enumerate(kpis):
            c0=1+i*w; c1=(c0+w) if i<len(kpis)-1 else 25
            inner.append(le(e["id"],c0,c1,1,6))
        extra.append({"id":"band-kpi","kind":"container"})
        bands.append(gc("band-kpi",row,row+5,"\n".join(inner))); row+=5
    for n,i in enumerate(range(0,len(charts),2),1):
        pair=charts[i:i+2]; inner=[]
        for j,e in enumerate(pair):
            c0=1 if j==0 else 13; c1=13 if (j==0 and len(pair)>1) else 25
            inner.append(le(e["id"],c0,c1,1,12))
        cid=f"band-row-{n}"; extra.append({"id":cid,"kind":"container"})
        bands.append(gc(cid,row,row+11,"\n".join(inner))); row+=11
    xml=(f'<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="{page_id}">\n'
         +"\n".join(bands)+'\n</Page>')
    return '<?xml version="1.0" encoding="utf-8"?>\n'+xml, extra

def build(app_name):
    O=lambda c:"[OFV/%s]"%c
    MCOLS=["Net Revenue","Net Profit","Order Id","Category","Month Number","Store Region"]
    master={"id":"m-ofv","name":"OFV","kind":"table","source":{"dataModelId":DM,"elementId":DENORM,"kind":"data-model"},
            "columns":[{"id":"o%d"%i,"formula":"[Custom SQL/%s]"%c,"name":c} for i,c in enumerate(MCOLS)]}
    def kpi(i,name,f,fmt): c="k%d"%i; return {"id":"ek%d"%i,"kind":"kpi-chart","name":name,"source":{"elementId":"m-ofv","kind":"table"},"columns":[{"id":c,"formula":f,"name":name,"format":N(fmt)}],"value":{"columnId":c}}
    def ch(i,kind,name,dimf,dimn,mf):
        x="x%d"%i; y="y%d"%i; return {"id":"ec%d"%i,"kind":kind,"name":name,"source":{"elementId":"m-ofv","kind":"table"},
          "columns":[{"id":x,"formula":dimf,"name":dimn},{"id":y,"formula":mf,"name":"Net Revenue","format":N("$,.0f")}],"xAxis":{"columnId":x},"yAxis":{"columnIds":[y]}}
    elems=[kpi(1,"Net Revenue","Sum(%s)"%O("Net Revenue"),"$,.0f"),kpi(2,"Orders","CountDistinct(%s)"%O("Order Id"),",.0f"),
           kpi(3,"Net Margin","Sum(%s)/Sum(%s)"%(O("Net Profit"),O("Net Revenue")),",.1%"),
           ch(1,"bar-chart","Net Revenue by Category",O("Category"),"Category","Sum(%s)"%O("Net Revenue")),
           ch(2,"line-chart","Net Revenue by Month",O("Month Number"),"Month","Sum(%s)"%O("Net Revenue")),
           ch(3,"bar-chart","Net Revenue by Region",O("Store Region"),"Region","Sum(%s)"%O("Net Revenue"))]
    xml,extra=auto_layout("pg-ov",[{"id":e["id"],"kind":e["kind"]} for e in elems],title=app_name)
    data_xml=('<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" '
              'gridTemplateRows="auto" id="pg-data">\n'
              '  <Element elementId="m-ofv" gridColumn="1 / 25" gridRow="1 / 15"/>\n'
              '</Page>')
    full_xml='<?xml version="1.0" encoding="utf-8"?>\n'+data_xml+'\n'+xml.split("\n",1)[1]
    # Canonical workbook-as-code shape: outer metadata plus a complete
    # document. Pages carry metadata only; elements are flat; layout places
    # every element exactly once. Data-model nesting is unrelated and unchanged.
    doc={"schemaVersion":1,"kind":"workbook",
         "pages":[{"id":"pg-data","name":"Data","visibility":"hidden"},
                  {"id":"pg-ov","name":"Overview"}],
         "elements":[master]+elems+extra,"layout":full_xml}
    post_body=code_rep.wrap(doc,{"name":f"{app_name} → Sigma","folderId":FOLDER})
    res=post("/v2/workbooks/spec",post_body)
    if not res: return None
    wb=re.search(r'workbookId:\s*(\S+)',res)
    wb=wb.group(1) if wb else None
    if wb:
        lf="/tmp/_lay_%s.xml"%wb; open(lf,"w").write(full_xml)
        subprocess.run([sys.executable,PUTLAYOUT,"--workbook",wb,"--layout",lf],capture_output=True)
    return wb

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--apps",required=True)
    ap.add_argument("--data-model",default=DM); ap.add_argument("--denorm-element",default=DENORM); ap.add_argument("--folder",default=FOLDER)
    a=ap.parse_args()
    if not (a.data_model and a.denorm_element and a.folder):
        sys.exit("set --data-model / --denorm-element / --folder (or env SIGMA_DM_ID / SIGMA_DENORM_ELEMENT_ID / SIGMA_FOLDER_ID)")
    DM=a.data_model; DENORM=a.denorm_element; FOLDER=a.folder
    for line in open(a.apps):
        line=line.strip()
        if not line: continue
        aid,name=line.split("|",1)
        wb=build(name)
        print(f"  {name:28} -> workbook {wb}")

if __name__=="__main__": main()
