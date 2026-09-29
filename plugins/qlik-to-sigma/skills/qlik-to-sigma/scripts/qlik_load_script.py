#!/usr/bin/env python3
"""Parse Qlik LOAD/SQL table blocks into final warehouse-backed tables."""
import copy
import re

from qlik_load_expr import referenced_columns


LABEL = re.compile(
    r"(?im)^[ \t]*(?:(?P<no_concatenate>NOCONCATENATE)[ \t]*(?:\r?\n[ \t]*)?)?"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)[ \t]*:[ \t]*(?:\r?\n|$)"
)
DROP_TABLE = re.compile(r"(?im)^\s*DROP\s+TABLE\s+([A-Za-z_][A-Za-z0-9_]*)\s*;")
SQL_SELECT = re.compile(
    r'\b(?:SQL\s+)?SELECT\b(.*?)\bFROM\s+([A-Za-z0-9_."`]+)', re.IGNORECASE | re.DOTALL)


def split_fields(text):
    parts, current, depth, quote = [], [], 0, None
    for char in text:
        if quote:
            current.append(char)
            if char == quote:
                quote = None
        elif char in "'\"`":
            quote = char
            current.append(char)
        elif char in "([":
            depth += 1
            current.append(char)
        elif char in ")]":
            depth = max(0, depth - 1)
            current.append(char)
        elif char == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
    if current:
        parts.append("".join(current))
    return parts


def clean_source(source):
    return ".".join(part.strip('"`[]') for part in source.split("."))


def field_record(token, sql=False):
    token = token.strip().strip(";").strip()
    token = re.sub(r"^DISTINCT\s+", "", token, flags=re.IGNORECASE)
    if not token:
        return None
    alias = re.search(
        r'^(.*?)\s+AS\s+["`]?([A-Za-z_][A-Za-z0-9_$]*)["`]?$',
        token,
        re.IGNORECASE | re.DOTALL,
    )
    real = alias.group(1).strip() if alias else token
    qlik = alias.group(2) if alias else None
    identifier = re.fullmatch(
        r'(?:["`\[]?[A-Za-z_][A-Za-z0-9_$]*["`\]]?\.)*["`\[]?([A-Za-z_][A-Za-z0-9_$]*|\*)["`\]]?',
        real,
    )
    if identifier:
        physical = identifier.group(1)
        qlik = qlik or physical
        return {
            "qlikField": qlik,
            "realColumn": physical,
            "renamed": physical.upper() != qlik.upper(),
            "isExpression": False,
        }
    if sql or not qlik:
        return None
    dual = re.match(
        r'^Dual\s*\(\s*"?([A-Za-z0-9_]+)"?\s*,\s*"?([A-Za-z0-9_]+)"?\s*\)$',
        real,
        re.IGNORECASE,
    )
    if dual:
        physical = dual.group(2)
        return {
            "qlikField": qlik,
            "realColumn": physical,
            "renamed": physical.upper() != qlik.upper(),
            "isExpression": False,
        }
    return {
        "qlikField": qlik,
        "realColumn": real.strip('"'),
        "renamed": True,
        "isExpression": True,
        "loadExpression": real.strip('"'),
        "expressionColumns": referenced_columns(real),
    }


def mask_comments(qvs):
    """Blank out // and /* */ comments, preserving offsets. `lib://` is kept."""
    def blank(match):
        return re.sub(r"[^\n]", " ", match.group(0))
    qvs = re.sub(r"/\*.*?\*/", blank, qvs, flags=re.DOTALL)
    return re.sub(r"(?m)(?<![:A-Za-z0-9])//[^\n]*", blank, qvs)


def statement_ends(qvs):
    """Offsets just past each top-level `;` (outside quotes/brackets)."""
    ends, depth, quote = [], 0, None
    for index, char in enumerate(qvs):
        if quote:
            if char == quote:
                quote = None
        elif char in "'\"`":
            quote = char
        elif char in "([":
            depth += 1
        elif char in ")]":
            depth = max(0, depth - 1)
        elif char == ";" and depth == 0:
            ends.append(index + 1)
    return ends


# A table-creating statement with no label. JOIN/KEEP/CONCATENATE/MAPPING
# prefixes are excluded: they extend an existing table or build a map.
UNLABELED_START = re.compile(
    r"(?:(?<=;)|^)(\s*)(?:(NOCONCATENATE)\s+)?"
    r"(LOAD|SQL\s+SELECT|SELECT)\b",
    re.IGNORECASE,
)


def unlabeled_name(statement):
    lib_file = re.search(r"\bFROM\s+\[lib://[^/]+/([^]]+)\]", statement, re.IGNORECASE)
    if lib_file:
        return re.sub(r"\.(qvd|qvx|csv|txt|xlsx?)$", "", lib_file.group(1).split("/")[-1],
                      flags=re.IGNORECASE)
    sql = SQL_SELECT.search(statement)
    if sql:
        return clean_source(sql.group(2)).split(".")[-1]
    return None


def table_blocks(qvs):
    masked = mask_comments(qvs)
    labels = list(LABEL.finditer(masked))
    ends = statement_ends(masked)
    unlabeled = []
    for match in UNLABELED_START.finditer(masked):
        start = match.start(3)
        if any(
            label.end() <= start
            and re.fullmatch(
                r"\s*(?:NOCONCATENATE\s+)?",
                masked[label.end():start],
                re.IGNORECASE,
            )
            for label in labels
        ):
            continue  # the labeled table's own first statement
        if match.group(3).upper() != "LOAD":
            prior_ends = [end for end in ends if end <= start]
            previous = masked[(prior_ends[-2] if len(prior_ends) > 1 else 0):prior_ends[-1]] \
                if prior_ends else ""
            if re.search(r"\bLOAD\b", previous, re.IGNORECASE) and not re.search(
                    r"\b(FROM|RESIDENT|INLINE|AUTOGENERATE)\b", previous, re.IGNORECASE):
                continue  # the source of a preceding load, not a table of its own
        stop = next((end for end in ends if end > start), len(masked))
        statement = masked[start:stop]
        if match.group(3).upper() == "LOAD" and not re.search(
                r"\b(FROM|RESIDENT|INLINE|AUTOGENERATE)\b", statement, re.IGNORECASE):
            # Preceding load: the table's source is the SQL SELECT that follows.
            stop = next((end for end in ends if end > stop), len(masked))
            statement = masked[start:stop]
        name = unlabeled_name(statement)
        if name:
            unlabeled.append(
                (start, stop, name, bool(match.group(2)))
            )

    blocks = [
        (
            match.start(),
            match.end(),
            match.group("name"),
            True,
            bool(match.group("no_concatenate")),
        )
        for match in labels
    ]
    blocks += [
        (start, start, name, False, no_concatenate)
        for start, _stop, name, no_concatenate in unlabeled
    ]
    blocks.sort()
    for index, (begin, body_start, name, labeled, no_concatenate) in enumerate(blocks):
        end = blocks[index + 1][0] if index + 1 < len(blocks) else len(masked)
        body = masked[body_start:end]
        if labeled:
            no_concatenate = no_concatenate or bool(
                re.match(r"\s*NOCONCATENATE\b", body, re.IGNORECASE)
            )
        yield name, body, labeled, no_concatenate


def apply_auto_concatenate(records):
    """Mirror Qlik auto-concatenation across labeled and unlabeled loads."""
    kept, seen = [], set()
    for record in records:
        signature = frozenset(field["qlikField"].upper() for field in record["fields"])
        if signature in seen and not record["_no_concatenate"]:
            continue
        if signature not in seen:
            seen.add(signature)
        kept.append(record)
    return kept


def parse_raw(qvs):
    records = []
    for name, block, labeled, no_concatenate in table_blocks(qvs):
        sql_match = SQL_SELECT.search(block)
        load_match = re.search(
            r'^\s*(?:NOCONCATENATE\s+)?LOAD\b'
            r'(.*?)(?=\bRESIDENT\b|\bFROM\s+\[|\bAUTOGENERATE\b|\bINLINE\b|;)',
            block,
            re.IGNORECASE | re.DOTALL,
        )
        if load_match:
            fields = [field_record(token) for token in split_fields(load_match.group(1))]
            resident = re.search(r"\bRESIDENT\s+([A-Za-z_][A-Za-z0-9_]*)", block, re.IGNORECASE)
            lib_file = re.search(r"\bFROM\s+\[lib://[^/]+/([^]]+)\]", block, re.IGNORECASE)
            special = re.search(r"\b(INLINE|AUTOGENERATE)\b", block, re.IGNORECASE)
            if sql_match:
                source = clean_source(sql_match.group(2))
            elif resident:
                source = f"RESIDENT {resident.group(1)}"
            elif lib_file:
                source = re.sub(
                    r"\.(qvd|qvx|csv|txt|xlsx?)$", "", lib_file.group(1).split("/")[-1], flags=re.IGNORECASE)
            else:
                source = special.group(1).upper() if special else "?"
        elif sql_match and not block[:sql_match.start()].strip():
            fields = [field_record(token, sql=True) for token in split_fields(sql_match.group(1))]
            source = clean_source(sql_match.group(2))
        else:
            continue
        fields = [field for field in fields if field]
        if fields:
            records.append({"qlikTable": name, "sourceTable": source, "fields": fields,
                            "_labeled": labeled, "_no_concatenate": no_concatenate})
    records = apply_auto_concatenate(records)
    for record in records:
        record.pop("_labeled", None)
        record.pop("_no_concatenate", None)
    return records


def parse_reconcile(qvs):
    raw = parse_raw(qvs)
    by_name = {record["qlikTable"].upper(): record for record in raw}

    def resolve(record, seen=None):
        result = copy.deepcopy(record)
        match = re.match(r"^RESIDENT\s+(.+)$", result["sourceTable"], re.IGNORECASE)
        if not match:
            return result
        seen = set(seen or ())
        source_name = match.group(1).upper()
        if source_name in seen or source_name not in by_name:
            return result
        seen.add(source_name)
        base = resolve(by_name[source_name], seen)
        base_fields = {field["qlikField"].upper(): field for field in base["fields"]}
        result["sourceTable"] = base["sourceTable"]
        for field in result["fields"]:
            if field["isExpression"]:
                continue
            inherited = base_fields.get(field["realColumn"].upper())
            if not inherited:
                continue
            field["realColumn"] = inherited["realColumn"]
            field["renamed"] = field["realColumn"].upper() != field["qlikField"].upper()
            if inherited["isExpression"]:
                field["isExpression"] = True
                field["loadExpression"] = inherited["loadExpression"]
                field["expressionColumns"] = inherited["expressionColumns"]
        return result

    dropped = {name.upper() for name in DROP_TABLE.findall(qvs)}
    return [resolve(record) for record in raw if record["qlikTable"].upper() not in dropped]


def parse_tables(qvs):
    return [
        {
            "name": record["qlikTable"],
            "noOfRows": 0,
            "fields": [{"name": field["qlikField"]} for field in record["fields"]],
        }
        for record in parse_reconcile(qvs)
    ]
