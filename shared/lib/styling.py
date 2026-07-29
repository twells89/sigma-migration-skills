"""styling.py — Python twin of shared/lib/styling.rb. Spec-authorable dashboard
styling helpers that decorate Composition output: theme (palette), chart color,
KPI accent, number format, header/section container. Byte-identical output.
"""
import base64
import copy
import composition  # sibling module in shared/lib; caller must have this dir on sys.path (see test_styling.py)

# One professional, host-agnostic palette. No branding.
DEFAULT_THEME = {
    "categorical": ["#2563EB", "#0EA5E9", "#14B8A6", "#F59E0B", "#8B5CF6", "#EF4444", "#10B981", "#64748B"],
    "ink": "#0F172A", "muted": "#64748B",
    # Task-1 verified: field is borderRadius ("round"), borderColor/borderWidth;
    # do NOT put padding alongside border fields (POST 400).
    "card": {"backgroundColor": "#FFFFFF", "borderColor": "#E2E8F0",
              "borderWidth": 1, "borderRadius": "round"},
    "header": {"backgroundColor": "#0F172A", "borderRadius": "round"},
    "accent": "#2563EB",
    # WS4 Task 2: neutral 3-stop gradient (dark slate -> navy -> accent blue)
    # for gradient_header(). NOT red -- red is a caller override, same
    # discipline as theme(accent=) tinting the flat palette above.
    "header_gradient": ["#0F172A", "#1E3A8A", "#2563EB"],
}

def theme(accent=None):
    """Returns a theme; an accent override tints categorical slot 0 + accent."""
    if accent is None or str(accent) == "":
        return DEFAULT_THEME
    t = copy.deepcopy(DEFAULT_THEME)  # deep copy (stdlib)
    t["categorical"] = [str(accent)] + t["categorical"][1:]
    t["accent"] = str(accent)
    return t


# GO/NO-GO map, seeded from the live Task-1 probe
# (.superpowers/sdd/styling-task-1-report.md, workbook
# e0586f0d-a2cd-431c-b495-555acf3ccae0): every surface below survived
# GET-spec readback AND rendered a real pixel hit. All 6 are GO today, but
# gating every helper through this map (instead of hardcoding True at each
# call site) means a future regression/deprecation can flip one surface off
# in one place -- the gated helper then returns an empty patch instead of
# emitting an unverified (or 400-rejected) shape.
SURFACES = {
    "kpi_name_color": True,      # name:{text,color} on a kpi-chart (value.color bonus also GO, not emitted here)
    "chart_color_by": True,      # color:{by:"single",value:"#hex"} on a chart element
    "categorical_scheme": True,  # workbook-level themeOverrides:{categoricalScheme:[...]}
    "format_string": True,       # format:{kind:"number",formatString:<d3>} -- Excel-style formatString is 400-rejected, never emitted
    "container_style": True,     # container style:{backgroundColor,borderRadius,borderColor,borderWidth} (borderRadius, NOT cornerRadius; never combine with padding)
    "typography": True,          # themeOverrides.titleFont + per-element name:{fontSize} -- GO, but no helper below emits it (out of this task's scope); kept for a complete surface map
    # WS4 Task 2 (build-plugs-command-center.rb HDRBG probe): container
    # backgroundImage:{url:"data:image/svg+xml;base64,...",style:{fit:"cover"}}
    # carrying a composed <linearGradient>+motif SVG survived readback + a
    # real render. Two independent gates: gradient_header (the whole surface;
    # NO-GO falls back to the flat header() band) and motif (the optional
    # decorative <g> layered on top of a *menu-key* motif; NO-GO degrades
    # that case to a plain gradient with no motif, never a broken shape. It
    # does NOT touch a bring-your-own image URL -- that path has nothing to
    # do with the decorative SVG-fragment library this gate protects, so it
    # is honored unconditionally).
    "gradient_header": True,
    "motif": True,
    # WS4 Task 3 (build-plugs-command-center.rb card(...)/_spark(...) probe):
    # a gradient backgroundImage CARD container (gradient_card(), wrapping a
    # caller-built kpi-chart with a white-text patch) and a separate
    # borderless line-chart composite sparkline (sparkline()) both survived
    # readback + a real render. NO-GO gradient_card -> the empty
    # {"element":[],"child_layout":"","patch":{}} marker (graceful -- never
    # mutates or half-decorates the caller's kpi_element). NO-GO sparkline ->
    # {"opt_in":True,"id":} (never a faked chart shape).
    "gradient_card": True,
    "sparkline": True,
}

# d3-format grammar (NOT Excel) -- Task-1 verified surviving strings.
D3_FORMATS = {
    "currency": "$,.0f",
    "integer": ",.0f",
    "percent": ".1%",
    "decimal": ",.2f",
}

# Motif menu for gradient_header() (WS4 Task 2, design doc "Component B" +
# the live-verified HDRBG concentric-ring <g> in
# build-plugs-command-center.rb). Each fragment is a fixed, deterministic SVG
# string local to its own origin (0,0) -- gradient_header wraps it in a
# positioning <g transform="translate(x,86)"> per motif_side, so the
# fragments themselves never hardcode a page position. All geometric,
# trademark-free, white low-opacity strokes/fills. "none" is the
# empty-string identity (no motif layered on the gradient).
GLOW_MOTIF_FRAGMENT = ('<defs><radialGradient id="motif-glow" cx="0.5" cy="0.5" r="0.6">'
                       '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.2"/>'
                       '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient></defs>'
                       '<rect x="-260" y="-105" width="520" height="210" fill="url(#motif-glow)"/>')
RINGS_MOTIF_FRAGMENT = ('<g fill="none" stroke="#FFFFFF" stroke-opacity="0.12" stroke-width="1.4">'
                        '<circle r="40"/><circle r="74"/><circle r="108"/>'
                        '<line x1="-130" y1="0" x2="130" y2="0"/><line x1="0" y1="-130" x2="0" y2="130"/></g>')
GRID_MOTIF_FRAGMENT = ('<defs><pattern id="motif-grid" width="40" height="40" patternUnits="userSpaceOnUse">'
                       '<path d="M 40 0 L 0 0 0 40" fill="none" stroke="#FFFFFF" stroke-opacity="0.12" stroke-width="1"/>'
                       '</pattern></defs><rect x="-260" y="-105" width="520" height="210" fill="url(#motif-grid)"/>')
WAVES_MOTIF_FRAGMENT = ('<g fill="none" stroke="#FFFFFF" stroke-opacity="0.14" stroke-width="2">'
                        '<path d="M -150 0 A 150 150 0 0 1 150 0"/>'
                        '<path d="M -110 0 A 110 110 0 0 1 110 0"/>'
                        '<path d="M -70 0 A 70 70 0 0 1 70 0"/></g>')
DOTS_MOTIF_FRAGMENT = ('<defs><pattern id="motif-dots" width="24" height="24" patternUnits="userSpaceOnUse">'
                       '<circle cx="4" cy="4" r="2" fill="#FFFFFF" fill-opacity="0.16"/></pattern></defs>'
                       '<rect x="-260" y="-105" width="520" height="210" fill="url(#motif-dots)"/>')

MOTIFS = {
    "glow": lambda: GLOW_MOTIF_FRAGMENT,
    "rings": lambda: RINGS_MOTIF_FRAGMENT,
    "grid": lambda: GRID_MOTIF_FRAGMENT,
    "waves": lambda: WAVES_MOTIF_FRAGMENT,
    "dots": lambda: DOTS_MOTIF_FRAGMENT,
    "none": lambda: "",
}

# motif_side -> x translate (page-space, viewBox 0 0 1600 210); y is fixed
# at 86 for every side (matches the HDRBG reference's vertical placement).
GRADIENT_MOTIF_X = {"right": 1440, "left": 160, "center": 800}


def chart_color(theme, categorical=False, surfaces=None):
    """Chart color patch: single-series color:{by:"single",value:} (categorical
    slot 0) by default, or the workbook-level categorical-scheme patch when
    categorical=True. NO-GO surface -> {} (nothing emitted).
    """
    s = SURFACES if surfaces is None else surfaces
    if categorical:
        if not s["categorical_scheme"]:
            return {}
        return {"themeOverrides": {"categoricalScheme": theme["categorical"]}}
    if not s["chart_color_by"]:
        return {}
    return {"color": {"by": "single", "value": theme["categorical"][0]}}


def kpi_accent(theme, surfaces=None):
    """Fragment to merge into a KPI element's `name` object: name:{text:,color:}.
    NO-GO surface -> {} (nothing to merge).
    """
    s = SURFACES if surfaces is None else surfaces
    if not s["kpi_name_color"]:
        return {}
    return {"color": theme["accent"]}


def format_for(semantic, surfaces=None):
    """Number-format fragment for a column's `format` field.
    semantic: "currency" / "integer" / "percent" / "decimal".
    """
    s = SURFACES if surfaces is None else surfaces
    if not s["format_string"]:
        return {}
    d3 = D3_FORMATS.get(str(semantic))
    if d3 is None:
        raise ValueError("format_for: unknown semantic %r" % (semantic,))
    return {"kind": "number", "formatString": d3}


def header(id, title, theme, page_cols=24, surfaces=None):
    """Thin full-width header band (rows 1..3): a styled kind:container + a
    separate kind:text title child (containers have no title-rendering field
    of their own -- see reference/specification/layout.md Recipe 1), plus the
    <GridContainer> layout fragment wrapping the title <LayoutElement>. If
    container-style is NO-GO, returns the header as a plain text element with
    no wrapping container (a bare <LayoutElement>).
    """
    s = SURFACES if surfaces is None else surfaces
    title_id = "%s-title" % id
    text_el = {"id": title_id, "kind": "text",
               "body": '# <span style="color: #FFFFFF">%s</span>' % title}
    r0, r1 = 1, 3
    if not s["container_style"]:
        layout = '  <LayoutElement elementId="%s" gridColumn="1 / %d" gridRow="%d / %d"/>' % (
            title_id, page_cols + 1, r0, r1)
        return {"element": [text_el], "layout": layout}
    container_id = "%s-bg" % id
    container_el = {"id": container_id, "kind": "container", "style": theme["header"]}
    layout = "\n".join([
        '<GridContainer elementId="%s" type="grid" gridColumn="1 / %d" gridRow="%d / %d" '
        'gridTemplateColumns="repeat(%d, 1fr)" gridTemplateRows="auto">' % (
            container_id, page_cols + 1, r0, r1, page_cols),
        '  <LayoutElement elementId="%s" gridColumn="1 / %d" gridRow="%d / %d"/>' % (
            title_id, page_cols + 1, r0, r1),
        '</GridContainer>',
    ])
    return {"element": [container_el, text_el], "layout": layout}


def section_card(id, band, theme, page_cols=24, surfaces=None):
    """Wraps one composition.bands()-style band ({"role":,"ids":,"r0":,"r1":})
    in a styled card container: a kind:container (theme["card"]) at the
    band's page-level rect, with its ids tiled side-by-side inside (same even
    column split composition._band uses, on the container's own relative row
    range). If container-style is NO-GO, returns the band's bare (unwrapped)
    <LayoutElement> render, matching plain composition output.
    """
    s = SURFACES if surfaces is None else surfaces
    ids = band["ids"]
    height = band["r1"] - band["r0"]
    if not s["container_style"]:
        wrap = "\n".join(composition._band([{"id": i} for i in ids], band["r0"], band["r1"], page_cols))
        return {"element": None, "wrap": wrap}
    container_el = {"id": id, "kind": "container", "style": theme["card"]}
    children = "\n".join(composition._band([{"id": i} for i in ids], 1, 1 + height, page_cols))
    wrap = "\n".join([
        '<GridContainer elementId="%s" type="grid" gridColumn="1 / %d" gridRow="%d / %d" '
        'gridTemplateColumns="repeat(%d, 1fr)" gridTemplateRows="auto">' % (
            id, page_cols + 1, band["r0"], band["r1"], page_cols),
        children,
        '</GridContainer>',
    ])
    return {"element": container_el, "wrap": wrap}


def bring_your_own_motif(motif):
    """True when `motif` is a caller-supplied image reference (bring-your-own),
    not a MOTIFS menu key.
    """
    return isinstance(motif, str) and (motif.startswith("http") or motif.startswith("data:"))


def svg_data_uri(svg):
    """data:image/svg+xml;base64,... URI for an inline SVG string."""
    return "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode()


def compose_gradient_svg(gradient, motif, motif_side):
    """Composes the gradient_header background SVG: viewBox 0 0 1600 210, a
    linearGradient from `gradient`'s 2-3 hex stops, plus an optional motif
    <g> positioned per motif_side. `motif` here is always a MOTIFS key
    (bring-your-own URLs are handled by the caller before this is reached --
    see gradient_header).
    """
    if not isinstance(gradient, list) or len(gradient) not in (2, 3):
        raise ValueError("compose_gradient_svg: gradient must be a list of 2-3 hex stops (got %r)" % (gradient,))
    offsets = ["0", "1"] if len(gradient) == 2 else ["0", "0.5", "1"]
    stops = "".join('<stop offset="%s" stop-color="%s"/>' % (offsets[i], hex_) for i, hex_ in enumerate(gradient))
    motif_fn = MOTIFS.get(motif)
    if motif_fn is None:
        raise ValueError("compose_gradient_svg: unknown motif %r" % (motif,))
    frag = motif_fn()
    tx = GRADIENT_MOTIF_X.get(motif_side, GRADIENT_MOTIF_X["right"])
    motif_group = "" if frag == "" else '<g transform="translate(%d,86)">%s</g>' % (tx, frag)
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1600 210" preserveAspectRatio="xMidYMid slice">'
            '<defs><linearGradient id="hg" x1="0" y1="0" x2="1" y2="0.45">%s</linearGradient></defs>'
            '<rect width="1600" height="210" fill="url(#hg)"/>%s</svg>') % (stops, motif_group)


def gradient_header(id, title, subtitle=None, gradient=None, motif="glow", motif_side="right",
                     logo_url=None, page_cols=24, surfaces=None):
    """Sleek gradient header band (rows 1..4): a container whose
    backgroundImage is a composed data-URI SVG (linearGradient + optional
    motif), an optional left-side logo image, a white title text element,
    and an optional subtitle text element. Same {"element":, "layout":}
    contract as header(). `motif` is a MOTIFS key (default "glow") or a
    bring-your-own `http`/`data:` URL string used verbatim as the background
    (SVG compose skipped). NO-GO gradient_header falls back to the existing
    flat header() band (graceful, never a broken/fake surface). NO-GO motif
    (gradient_header still GO) silently drops the motif <g> for a
    *menu-key* motif, keeping the plain gradient -- also graceful, never
    broken. A bring-your-own motif URL is checked FIRST and honored
    unconditionally, regardless of SURFACES["motif"] -- that gate exists
    only to protect the decorative SVG-fragment library, not the caller's
    own image (an arbitrary URL in backgroundImage.url either way).
    """
    s = SURFACES if surfaces is None else surfaces
    if not s["gradient_header"]:
        return header(id, title, DEFAULT_THEME, page_cols=page_cols, surfaces=surfaces)

    grad = DEFAULT_THEME["header_gradient"] if gradient is None else gradient
    if bring_your_own_motif(motif):
        bg_url = motif
    else:
        effective_motif = motif if s["motif"] else "none"
        bg_url = svg_data_uri(compose_gradient_svg(grad, effective_motif, motif_side))

    container_id = "%s-bg" % id
    logo_id = "%s-logo" % id
    title_id = "%s-title" % id
    subtitle_id = "%s-subtitle" % id

    container_el = {"id": container_id, "kind": "container", "style": {"borderRadius": "round"},
                     "backgroundImage": {"url": bg_url, "style": {"fit": "cover"}}}
    title_el = {"id": title_id, "kind": "text", "verticalAlign": "middle",
                "body": '# <span style="color: #FFFFFF">%s</span>' % title}

    elements = [container_el]
    if logo_url:
        elements.append({"id": logo_id, "kind": "image", "url": logo_url, "style": {"fit": "contain"}})
    elements.append(title_el)
    if subtitle:
        elements.append({"id": subtitle_id, "kind": "text", "verticalAlign": "middle",
                          "body": '<span style="color: #CBD5E1">%s</span>' % subtitle})

    r0, r1 = 1, 4
    title_r1 = 3 if subtitle else r1
    text_c0 = 3 if logo_url else 1
    lines = ['<GridContainer elementId="%s" type="grid" gridColumn="1 / %d" gridRow="%d / %d" '
             'gridTemplateColumns="repeat(%d, 1fr)" gridTemplateRows="auto">' % (
                 container_id, page_cols + 1, r0, r1, page_cols)]
    if logo_url:
        lines.append('  <LayoutElement elementId="%s" gridColumn="1 / 3" gridRow="%d / %d"/>' % (logo_id, r0, r1))
    lines.append('  <LayoutElement elementId="%s" gridColumn="%d / %d" gridRow="%d / %d"/>' % (
        title_id, text_c0, page_cols + 1, r0, title_r1))
    if subtitle:
        lines.append('  <LayoutElement elementId="%s" gridColumn="%d / %d" gridRow="%d / %d"/>' % (
            subtitle_id, text_c0, page_cols + 1, title_r1, r1))
    lines.append('</GridContainer>')

    return {"element": elements, "layout": "\n".join(lines)}


def gradient_card(id, kpi_element, gradient, page_cols=24, surfaces=None):
    """Wraps a caller-built kpi-chart element (a dict, e.g. from kpi_card.build)
    in a gradient backgroundImage CARD container (WS4 Task 3, design doc
    "Component B" + the live-verified card(...) shape in
    build-plugs-command-center.rb). Decorate-only, like section_card():
    kpi_element is READ ONLY here (its "id" is read to build child_layout) --
    it is never mutated, and kpi_card.py (WS1, fanned to converters) is never
    touched. Instead this returns a patch dict the caller merges onto their
    own copy of the kpi element's value/name objects to turn the value +
    title white (e.g. kpi_element["value"].update(patch["value"])) so they
    read against the gradient, matching card(...)'s native-white KPI text.
    gradient is required (one gradient per card -- distinct KPI cards
    typically carry distinct gradients, matching the reference build's
    per-KPI KG[i] array) and reuses compose_gradient_svg()/svg_data_uri()
    from Task 2 with motif="none" (a plain gradient, no decorative motif --
    a card this small has no room for one; motif_side is irrelevant when the
    motif is "none" so "right" is passed as an inert default). child_layout
    is only the inner <LayoutElement> fragment positioning kpi_element's id
    inside the container at the composition kpi-band height (rows 1..7,
    matching composition.bands()'s own "kpi" role height) -- placing the
    container itself on the page is the caller's job (same "decorate, don't
    own layout" contract as section_card()), so no outer <GridContainer> is
    returned here. NO-GO -> {"element":[],"child_layout":"","patch":{}}
    (graceful: nothing to merge, nothing to lay out, never a broken/
    half-decorated card).
    """
    s = SURFACES if surfaces is None else surfaces
    if not s["gradient_card"]:
        return {"element": [], "child_layout": "", "patch": {}}

    bg_url = svg_data_uri(compose_gradient_svg(gradient, "none", "right"))
    container_el = {"id": id, "kind": "container", "style": {"borderRadius": "round"},
                     "backgroundImage": {"url": bg_url, "style": {"fit": "cover"}}}
    child_layout = '<LayoutElement elementId="%s" gridColumn="1 / %d" gridRow="1 / 7"/>' % (
        kpi_element["id"], page_cols + 1)
    patch = {"value": {"color": "#FFFFFF"}, "name": {"color": "#FFFFFF"}}
    return {"element": [container_el], "child_layout": child_layout, "patch": patch}


def sparkline(id, source_element_id, period_ref, value_formula, period_format="%b %Y", surfaces=None):
    """Composite in-card sparkline (WS4 Task 3): a separate, borderless mini
    line-chart element meant to sit BELOW a kpi-chart inside the same
    gradient_card() container -- NOT a date column bound inside the
    kpi-chart itself (that in-kpi shape was the WS3 NO-GO; this standalone
    line-chart is the live-verified GO pattern, matching _spark(...) in
    build-plugs-command-center.rb). Two columns: a period dimension
    (period_ref's formula, formatted kind:"datetime"/period_format) and a
    value (value_formula's formula). Both axes hide their labels/marks so no
    chrome competes with the kpi above it; the y-axis scale is zero:False (a
    small trend doesn't get flattened against a forced-zero baseline) with
    hideZeroLine:True; name/legend are hidden (no title, no legend on a
    sparkline); the line uses a smooth monotone interpolation; the
    background is transparent so the chart blends into the gradient card
    above/around it. NO-GO -> {"opt_in":True,"id":id} (never a faked/broken
    chart shape).
    """
    s = SURFACES if surfaces is None else surfaces
    if not s["sparkline"]:
        return {"opt_in": True, "id": id}

    period_col_id = "%s-period" % id
    value_col_id = "%s-value" % id
    return {
        "id": id,
        "kind": "line-chart",
        "source": {"kind": "table", "elementId": source_element_id},
        "columns": [
            {"id": period_col_id, "formula": period_ref, "name": "Period",
             "format": {"kind": "datetime", "formatString": period_format}},
            {"id": value_col_id, "formula": value_formula, "name": "Value"},
        ],
        "xAxis": {"columnId": period_col_id, "format": {"marks": "none", "labels": "hidden"}},
        "yAxis": {"columnIds": [value_col_id],
                  "format": {"labels": "hidden", "marks": "none",
                             "scale": {"type": "linear", "zero": False, "hideZeroLine": True}}},
        "name": {"visibility": "hidden"},
        "legend": {"visibility": "hidden"},
        "lineAreaStyle": {"interpolation": "monotone"},
        "style": {"backgroundColor": "transparent", "padding": "none"},
    }
