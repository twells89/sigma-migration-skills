#!/usr/bin/env python3
"""Focused, offline tests for the Spotfire extraction/manifest slice."""

import ast
import copy
import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
import zipfile


HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCRIPTS = os.path.join(SKILL, "scripts")
REFS = os.path.join(SKILL, "refs")
FIXTURES = os.path.join(HERE, "fixtures")


def _load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPTS, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validate_manifest = _load_module("spotfire_validate_manifest", "validate_manifest.py")
inspect_dxp = _load_module("spotfire_inspect_dxp", "inspect_dxp.py")
exporter = _load_module("spotfire_exporter", "export_spotfire_manifest.py")


def _json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


class Bag:
    def __init__(self, **values):
        self.__dict__.update(values)


class Properties:
    def __init__(self, values):
        self.values = values

    def GetPropertyNames(self):
        return list(self.values)

    def __getitem__(self, name):
        return self.values[name]

    def __getattr__(self, name):
        try:
            return self.values[name]
        except KeyError:
            raise AttributeError(name)


class ScriptManager:
    def __init__(self, scripts):
        self._scripts = scripts

    def GetScripts(self):
        return self._scripts


class BookmarkManager:
    def __init__(self, bookmarks):
        self._bookmarks = bookmarks

    def GetBookmarks(self):
        return self._bookmarks


class SourceView:
    def __init__(self, operations):
        self._operations = operations
        self.LastOperation = operations[-1] if operations else None


class Table(Bag):
    def __init__(self, operations, **values):
        super().__init__(**values)
        self._operations = operations

    def GenerateSourceView(self):
        return SourceView(self._operations)


def _fake_document():
    revenue = Bag(
        Id="revenue",
        Name="Revenue",
        DataType=Bag(DisplayName="Real"),
        ExternalName="REVENUE",
        IsCalculated=False,
        Properties=Properties({"ExternalName": "REVENUE"}),
    )
    margin = Bag(
        Id="margin",
        Name="Margin",
        DataType=Bag(DisplayName="Real"),
        ExternalName="MARGIN",
        IsCalculated=True,
        Expression="[Revenue] - [Cost]",
        Properties=Properties({"ExternalName": "MARGIN"}),
    )
    operation = Bag(
        Id="load-sales", Name="Load Sales", Provider="Snowflake", Inputs=[]
    )
    table = Table(
        [operation],
        Id="sales",
        Name="Sales",
        Columns=[revenue, margin],
        DataSource=Bag(Provider="Snowflake", Server="acme.example", Database="ANALYTICS"),
    )
    axis = Bag(Id="x", Name="XAxis", Expression="[Region]", SortMode="Descending")
    visual_data = Bag(DataTableReference=table)
    content = Bag(XAxis=axis, Data=visual_data)
    bounds = Bag(X=10, Y=20, Width=600, Height=320)
    visual = Bag(
        Id="revenue-region",
        Title="Revenue by Region",
        TypeId="BarChart",
        Description=None,
        VisualContentObject=content,
        Bounds=bounds,
    )
    page = Bag(Id="overview", Title="Overview", Description=None, Visuals=[visual])
    script_source = 'raise RuntimeError("must never execute")'
    script = Bag(
        Id="reset",
        Name="Reset",
        Language="IronPython",
        ScriptCode=script_source,
        Enabled=True,
    )
    data_function = Bag(
        Id="forecast",
        Name="Forecast",
        Definition=Bag(Language="R", Script="stop('must never execute')"),
        Inputs=[],
        Outputs=[],
    )
    bookmark = Bag(Id="default", Name="Default", Description=None)
    return (
        Bag(
            Id="commerce",
            Name="Commerce",
            Data=Bag(Tables=[table], Relations=[], DataFunctions=[data_function]),
            Pages=[page],
            FilteringSchemes=[],
            Properties=Properties({"Region": "All", "DbPassword": "super-secret"}),
            ScriptManager=ScriptManager([script]),
            BookmarkManager=BookmarkManager([bookmark]),
        ),
        script_source,
    )


class ManifestContractTests(unittest.TestCase):
    def setUp(self):
        self.valid = _json(os.path.join(FIXTURES, "valid_manifest.json"))

    def test_reference_schemas_and_examples_are_valid_json(self):
        manifest_schema = _json(os.path.join(REFS, "spotfire-manifest.schema.json"))
        provenance_schema = _json(os.path.join(
            REFS, "spotfire-manifest-provenance.schema.json"
        ))
        provenance = _json(os.path.join(
            REFS, "spotfire-manifest-provenance.example.json"
        ))
        warehouse_schema = _json(os.path.join(
            REFS, "spotfire-source-map.schema.json"
        ))
        warehouse_map = _json(os.path.join(
            REFS, "spotfire-source-map.example.json"
        ))
        self.assertEqual(manifest_schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertEqual(provenance_schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertEqual(warehouse_schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertIn("tables", warehouse_schema["required"])
        self.assertNotIn("mappings", warehouse_schema["required"])
        self.assertIn("tables", warehouse_map)
        errors, warnings = validate_manifest.validate_provenance_map(
            provenance, self.valid
        )
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_valid_fixture_passes_semantic_validator(self):
        errors, warnings = validate_manifest.validate_manifest(self.valid)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_raw_dxp_inventory_cannot_claim_manifest_authority(self):
        invalid = copy.deepcopy(self.valid)
        invalid["manifest_type"] = "spotfire_dxp_raw_inventory"
        invalid["authority"]["authoritative"] = False
        invalid["authority"]["dxp_raw_used"] = True
        errors, _ = validate_manifest.validate_manifest(invalid)
        joined = "\n".join(errors)
        self.assertIn("manifest_type", joined)
        self.assertIn("authoritative", joined)
        self.assertIn("raw DXP output is never authoritative", joined)

    def test_validator_rejects_duplicate_ids_and_credentials(self):
        invalid = copy.deepcopy(self.valid)
        invalid["bookmarks"][0]["source_id"] = invalid["source"]["source_id"]
        invalid["document_properties"][0]["value"] = (
            "Server=db.example;Password=hunter2;Database=analytics"
        )
        invalid["automation"]["scripts"][0]["script_body"] = "print('must not leave customer boundary')"
        errors, _ = validate_manifest.validate_manifest(invalid)
        joined = "\n".join(errors)
        self.assertIn("duplicates", joined)
        self.assertIn("assigned secret", joined)
        self.assertIn("executable source bodies must not be exported", joined)

    def test_unavailable_source_hash_is_loud_but_structurally_valid(self):
        manifest = copy.deepcopy(self.valid)
        manifest["source"]["artifact_hash"]["status"] = "unavailable"
        manifest["source"]["artifact_hash"]["value"] = None
        manifest["source"]["artifact_hash"]["reason"] = "path not supplied"
        errors, warnings = validate_manifest.validate_manifest(manifest)
        self.assertEqual(errors, [])
        self.assertTrue(any("hash is unavailable" in warning for warning in warnings))

    def test_malformed_manifest_returns_errors_instead_of_crashing(self):
        errors, warnings = validate_manifest.validate_manifest(
            {"manifest_type": "spotfire_neutral_manifest", "model": {"tables": "not-an-array"}}
        )
        self.assertTrue(errors)
        self.assertIsInstance(warnings, list)


class ExporterTests(unittest.TestCase):
    def test_exporter_builds_valid_manifest_without_executing_embedded_source(self):
        document, script_source = _fake_document()
        manifest, provenance_map = exporter.build_manifest(
            document, execution_context="analyst"
        )
        errors, warnings = validate_manifest.validate_manifest(manifest)
        self.assertEqual(errors, [])
        self.assertTrue(any("hash is unavailable" in warning for warning in warnings))
        serialized = json.dumps(manifest)
        self.assertNotIn("super-secret", serialized)
        self.assertNotIn(script_source, serialized)
        self.assertNotIn("must never execute", serialized)
        script = manifest["automation"]["scripts"][0]
        self.assertEqual(
            script["source_sha256"],
            hashlib.sha256(script_source.encode("utf-8")).hexdigest(),
        )
        self.assertFalse(script["source_included"])
        self.assertEqual(manifest["model"]["tables"][0]["columns"][1]["expression"], "[Revenue] - [Cost]")
        self.assertEqual(
            "REVENUE",
            manifest["model"]["tables"][0]["columns"][0]["external_name"],
        )
        self.assertEqual(
            1, len(manifest["model"]["tables"][0]["source_operations"])
        )
        self.assertEqual(
            manifest["presentation"]["pages"][0]["visuals"][0]["layout"]["status"],
            "available",
        )
        provenance_errors, _ = validate_manifest.validate_provenance_map(
            provenance_map, manifest
        )
        self.assertEqual(provenance_errors, [])

    def test_relation_parser_accepts_only_simple_qualified_equalities(self):
        self.assertEqual(
            [
                (("Orders", "Customer Id"), ("Customers", "Customer Id")),
                (("Orders", "Region"), ("Customers", "Region")),
            ],
            exporter._relation_pairs(
                "[Orders].[Customer Id] = [Customers].[Customer Id] "
                "and [Orders].[Region] = [Customers].[Region]"
            ),
        )
        self.assertEqual(
            [],
            exporter._relation_pairs(
                "[Orders].[Region] = Upper([Customers].[Region])"
            ),
        )

    def test_redaction_masks_uri_userinfo_and_assignments(self):
        value = "https://alice:open-sesame@example.test/x;Password=hunter2;Token=abc"
        redacted = exporter.redact_text(value)
        self.assertNotIn("open-sesame", redacted)
        self.assertNotIn("hunter2", redacted)
        self.assertNotIn("Token=abc", redacted)
        self.assertIn("<redacted>", redacted)

    def test_exporter_source_has_no_dynamic_execution_primitive(self):
        path = os.path.join(SCRIPTS, "export_spotfire_manifest.py")
        with open(path, "r", encoding="utf-8") as handle:
            tree = ast.parse(handle.read(), filename=path)
        forbidden = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                if node.func.id in ("eval", "exec", "compile", "__import__"):
                    forbidden.append(node.func.id)
        self.assertEqual(forbidden, [])


class DxpInspectorTests(unittest.TestCase):
    def _make_zip(self, path, include_doctype=False):
        xml_path = os.path.join(FIXTURES, "dxp", "AnalysisDocument.xml")
        payload_path = os.path.join(FIXTURES, "dxp", "embedded_payload.py")
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(xml_path, "AnalysisDocument.xml")
            archive.write(payload_path, "Scripts/embedded_payload.py")
            archive.writestr("Config/password=hunter2.txt", b"opaque")
            if include_doctype:
                archive.writestr(
                    "Unsafe.xml",
                    b'<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><x>&e;</x>',
                )

    def test_inventory_is_non_authoritative_and_never_reads_code(self):
        with tempfile.TemporaryDirectory() as temp:
            dxp = os.path.join(temp, "sample.dxp")
            self._make_zip(dxp)
            result = inspect_dxp.inspect_dxp(dxp)
        self.assertFalse(result["authoritative"])
        self.assertFalse(result["conversion_grade"])
        self.assertEqual(result["inventory_type"], "spotfire_dxp_raw_inventory")
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["xml_inventory"][0]["parse_status"], "parsed")
        serialized = json.dumps(result)
        self.assertNotIn("must never execute", serialized)
        self.assertNotIn("hunter2", serialized)
        payload = next(
            entry for entry in result["non_xml_entries"]
            if entry["entry"] == "Scripts/embedded_payload.py"
        )
        self.assertFalse(payload["content_inspected"])

    def test_doctype_is_blocked(self):
        with tempfile.TemporaryDirectory() as temp:
            dxp = os.path.join(temp, "unsafe.dxp")
            self._make_zip(dxp, include_doctype=True)
            result = inspect_dxp.inspect_dxp(dxp)
        unsafe = next(item for item in result["xml_inventory"] if item["entry"] == "Unsafe.xml")
        self.assertEqual(unsafe["parse_status"], "blocked")
        self.assertIn("DOCTYPE", unsafe["warning"])

    def test_archive_limits_stop_entry_inspection(self):
        with tempfile.TemporaryDirectory() as temp:
            dxp = os.path.join(temp, "limited.dxp")
            self._make_zip(dxp)
            result = inspect_dxp.inspect_dxp(dxp, max_entries=1)
        self.assertTrue(result["errors"])
        self.assertEqual(result["xml_inventory"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
