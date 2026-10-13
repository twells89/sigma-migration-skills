#!/usr/bin/env python3
"""Produce a safe, non-authoritative inventory of a Spotfire DXP ZIP.

DXP internals are an undocumented, versioned object graph. This fallback only
counts archive/XML structure for triage. It never extracts files, imports code,
evaluates expressions, deserializes objects, or emits XML text/attribute values.
Its output is not a conversion-grade Spotfire manifest.
"""

import argparse
import collections
import datetime
import hashlib
import io
import json
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET


INVENTORY_VERSION = "1.0"
DEFAULT_MAX_ENTRIES = 10000
DEFAULT_MAX_TOTAL_BYTES = 256 * 1024 * 1024
DEFAULT_MAX_XML_BYTES = 16 * 1024 * 1024
DEFAULT_MAX_COMPRESSION_RATIO = 1000.0
SECRET_ASSIGNMENT_RE = re.compile(
    r"(?i)\b(password|passwd|pwd|token|client[_-]?secret|api[_-]?key)\s*[:=]\s*[^;,\s]+"
)
URI_USERINFO_RE = re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@")


def _utc_now():
    if hasattr(datetime, "timezone"):
        return (
            datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
        )
    return datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def _sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def _redact_text(value):
    value = str(value)
    value = URI_USERINFO_RE.sub(r"\1<redacted>@", value)
    value = SECRET_ASSIGNMENT_RE.sub(lambda match: match.group(1) + "=<redacted>", value)
    return value


def _safe_entry_name(name):
    # Names are metadata only and are never used as output paths.
    return _redact_text(name).replace("\x00", "\ufffd")


def _local_name(tag):
    if not isinstance(tag, str):
        return "<non-string-tag>"
    if tag.startswith("{") and "}" in tag:
        return tag.split("}", 1)[1]
    if ":" in tag:
        return tag.rsplit(":", 1)[1]
    return tag


def _looks_like_xml(info):
    name = info.filename.lower()
    return name.endswith((".xml", ".xaml", ".config", ".rels")) or name in (
        "content.xml",
        "document.xml",
    )


def _blocked_xml_reason(payload):
    prefix = payload[:65536].upper()
    if b"<!DOCTYPE" in prefix:
        return "DOCTYPE is not parsed"
    if b"<!ENTITY" in prefix:
        return "entity declarations are not parsed"
    return None


def _xml_inventory(zf, info, max_xml_bytes):
    result = {
        "entry": _safe_entry_name(info.filename),
        "size": info.file_size,
        "sha256": None,
        "parse_status": "skipped",
        "root_tag": None,
        "element_count": 0,
        "tags": [],
        "attribute_names": [],
        "warning": None,
    }
    if info.file_size > max_xml_bytes:
        result["warning"] = "declared XML size exceeds --max-xml-bytes"
        return result
    try:
        with zf.open(info, "r") as handle:
            payload = handle.read(max_xml_bytes + 1)
    except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
        result["parse_status"] = "error"
        result["warning"] = _redact_text("ZIP read failed: %s" % exc)
        return result
    if len(payload) > max_xml_bytes:
        result["warning"] = "expanded XML exceeds --max-xml-bytes"
        return result
    result["sha256"] = _sha256_bytes(payload)
    blocked = _blocked_xml_reason(payload)
    if blocked:
        result["parse_status"] = "blocked"
        result["warning"] = blocked
        return result
    try:
        root = ET.fromstring(payload)
    except (ET.ParseError, ValueError) as exc:
        result["parse_status"] = "error"
        result["warning"] = _redact_text("XML parse failed: %s" % exc)
        return result

    tags = collections.Counter()
    attribute_names = set()
    element_count = 0
    for element in root.iter():
        element_count += 1
        tags[_local_name(element.tag)] += 1
        for attribute_name in element.attrib:
            attribute_names.add(_local_name(attribute_name))
    result["parse_status"] = "parsed"
    result["root_tag"] = _local_name(root.tag)
    result["element_count"] = element_count
    result["tags"] = [
        {"name": name, "count": count}
        for name, count in sorted(tags.items(), key=lambda pair: (-pair[1], pair[0]))
    ]
    # Values and text are intentionally excluded. Attribute names alone are
    # sufficient to identify likely object families without leaking settings.
    result["attribute_names"] = sorted(attribute_names)
    return result


def inspect_dxp(
    path,
    max_entries=DEFAULT_MAX_ENTRIES,
    max_total_bytes=DEFAULT_MAX_TOTAL_BYTES,
    max_xml_bytes=DEFAULT_MAX_XML_BYTES,
    max_compression_ratio=DEFAULT_MAX_COMPRESSION_RATIO,
):
    """Return a non-authoritative structural inventory for one local DXP."""
    result = {
        "inventory_type": "spotfire_dxp_raw_inventory",
        "inventory_version": INVENTORY_VERSION,
        "authoritative": False,
        "conversion_grade": False,
        "warning": (
            "NON-AUTHORITATIVE: DXP is an undocumented, versioned object graph. "
            "Use the customer-side public Application API exporter for conversion."
        ),
        "generated_at_utc": _utc_now(),
        "source": {
            "name": _safe_entry_name(os.path.basename(path)),
            "size": os.path.getsize(path),
            "sha256": _sha256_file(path),
        },
        "archive": {
            "entry_count": 0,
            "declared_uncompressed_bytes": 0,
            "declared_compressed_bytes": 0,
            "encrypted_entries": 0,
            "limits": {
                "max_entries": max_entries,
                "max_total_uncompressed_bytes": max_total_bytes,
                "max_xml_bytes": max_xml_bytes,
                "max_compression_ratio": max_compression_ratio,
            },
        },
        "xml_inventory": [],
        "non_xml_entries": [],
        "errors": [],
    }
    if not zipfile.is_zipfile(path):
        result["errors"].append("input is not a readable ZIP container")
        return result

    try:
        with zipfile.ZipFile(path, "r") as zf:
            infos = zf.infolist()
            result["archive"]["entry_count"] = len(infos)
            result["archive"]["declared_uncompressed_bytes"] = sum(info.file_size for info in infos)
            result["archive"]["declared_compressed_bytes"] = sum(info.compress_size for info in infos)
            result["archive"]["encrypted_entries"] = sum(1 for info in infos if info.flag_bits & 0x1)

            if len(infos) > max_entries:
                result["errors"].append("archive entry count exceeds --max-entries; entries were not inspected")
                return result
            if result["archive"]["declared_uncompressed_bytes"] > max_total_bytes:
                result["errors"].append(
                    "declared uncompressed size exceeds --max-total-bytes; entries were not inspected"
                )
                return result

            for info in sorted(infos, key=lambda item: item.filename):
                entry_name = _safe_entry_name(info.filename)
                if info.is_dir():
                    result["non_xml_entries"].append(
                        {
                            "entry": entry_name,
                            "kind": "directory",
                            "size": 0,
                            "compressed_size": 0,
                            "content_inspected": False,
                        }
                    )
                    continue
                if info.flag_bits & 0x1:
                    result["non_xml_entries"].append(
                        {
                            "entry": entry_name,
                            "kind": "encrypted",
                            "size": info.file_size,
                            "compressed_size": info.compress_size,
                            "content_inspected": False,
                        }
                    )
                    continue
                ratio = float(info.file_size) / max(1, info.compress_size)
                if ratio > max_compression_ratio:
                    result["errors"].append(
                        "entry %r exceeds the compression-ratio limit and was not read" % entry_name
                    )
                    continue
                if _looks_like_xml(info):
                    result["xml_inventory"].append(_xml_inventory(zf, info, max_xml_bytes))
                else:
                    result["non_xml_entries"].append(
                        {
                            "entry": entry_name,
                            "kind": "opaque",
                            "size": info.file_size,
                            "compressed_size": info.compress_size,
                            "content_inspected": False,
                        }
                    )
    except (OSError, RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile) as exc:
        result["errors"].append(_redact_text("ZIP inspection failed: %s" % exc))
    return result


def _write_json(data, output):
    text = json.dumps(data, indent=2, sort_keys=True) + "\n"
    if output == "-":
        sys.stdout.write(text)
        return
    with io.open(output, "w", encoding="utf-8") as handle:
        handle.write(text)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dxp", help="local .dxp ZIP to inventory")
    parser.add_argument("-o", "--output", default="-", help="output JSON path (default: stdout)")
    parser.add_argument("--max-entries", type=int, default=DEFAULT_MAX_ENTRIES)
    parser.add_argument("--max-total-bytes", type=int, default=DEFAULT_MAX_TOTAL_BYTES)
    parser.add_argument("--max-xml-bytes", type=int, default=DEFAULT_MAX_XML_BYTES)
    parser.add_argument("--max-compression-ratio", type=float, default=DEFAULT_MAX_COMPRESSION_RATIO)
    args = parser.parse_args(argv)

    if min(args.max_entries, args.max_total_bytes, args.max_xml_bytes) <= 0:
        parser.error("size and entry limits must be positive")
    if args.max_compression_ratio <= 0:
        parser.error("--max-compression-ratio must be positive")
    try:
        result = inspect_dxp(
            args.dxp,
            max_entries=args.max_entries,
            max_total_bytes=args.max_total_bytes,
            max_xml_bytes=args.max_xml_bytes,
            max_compression_ratio=args.max_compression_ratio,
        )
        _write_json(result, args.output)
    except OSError as exc:
        print("ERROR: %s" % _redact_text(exc), file=sys.stderr)
        return 2
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
