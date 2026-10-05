#!/usr/bin/env python3
"""Idempotently POST and read back a Sisense-generated Sigma specification.

The helper deliberately owns the resume boundary: once an id has been written,
it will GET that object and never silently create a replacement.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import sigma_rest  # noqa: E402


class PostError(Exception):
    pass


def yaml_scalar(value):
    value = value.strip()
    if not value:
        return None
    if value in ("null", "Null", "NULL", "~"):
        return None
    if value.lower() in ("true", "false"):
        return value.lower() == "true"
    if value[:1] in ("'", '"') and value[-1:] == value[:1]:
        return value[1:-1]
    if value[:1] in ("[", "{"):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            pass
    try:
        return int(value)
    except ValueError:
        try:
            return float(value)
        except ValueError:
            return value


def parse_simple_yaml(text):
    """Parse the ordinary mapping/list subset used by Sigma spec responses."""
    tokens = []
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("---") or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        tokens.append((indent, raw.strip()))
    if not tokens:
        raise PostError("empty YAML response")

    def block(index, indent):
        is_list = tokens[index][1].startswith("- ")
        output = [] if is_list else {}
        while index < len(tokens):
            current_indent, line = tokens[index]
            if current_indent < indent:
                break
            if current_indent > indent:
                raise PostError("invalid YAML indentation near %r" % line)
            if is_list:
                if not line.startswith("- "):
                    break
                item = line[2:].strip()
                if not item:
                    if index + 1 >= len(tokens) or tokens[index + 1][0] <= indent:
                        output.append(None)
                        index += 1
                    else:
                        value, index = block(index + 1, tokens[index + 1][0])
                        output.append(value)
                    continue
                if ":" in item:
                    key, raw_value = item.split(":", 1)
                    row = {key.strip(): yaml_scalar(raw_value)}
                    index += 1
                    while index < len(tokens) and tokens[index][0] > indent:
                        child_indent, child_line = tokens[index]
                        if child_line.startswith("- "):
                            value, index = block(index, child_indent)
                            previous = next(reversed(row))
                            row[previous] = value
                            continue
                        child_key, separator, child_raw = child_line.partition(":")
                        if not separator:
                            raise PostError("invalid YAML mapping line %r" % child_line)
                        if child_raw.strip():
                            row[child_key.strip()] = yaml_scalar(child_raw)
                            index += 1
                        elif index + 1 < len(tokens) and tokens[index + 1][0] > child_indent:
                            value, index = block(index + 1, tokens[index + 1][0])
                            row[child_key.strip()] = value
                        else:
                            row[child_key.strip()] = None
                            index += 1
                    output.append(row)
                else:
                    output.append(yaml_scalar(item))
                    index += 1
            else:
                if line.startswith("- "):
                    break
                key, separator, raw_value = line.partition(":")
                if not separator:
                    raise PostError("invalid YAML mapping line %r" % line)
                if raw_value.strip():
                    output[key.strip()] = yaml_scalar(raw_value)
                    index += 1
                elif index + 1 < len(tokens) and tokens[index + 1][0] > indent:
                    value, index = block(index + 1, tokens[index + 1][0])
                    output[key.strip()] = value
                else:
                    output[key.strip()] = None
                    index += 1
        return output, index

    parsed, consumed = block(0, tokens[0][0])
    if consumed != len(tokens):
        raise PostError("could not consume complete YAML response")
    return parsed


def parse_payload(text):
    text = text.decode("utf-8") if isinstance(text, bytes) else str(text or "")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    try:
        import yaml  # optional; the fallback below covers Sigma's id response
        value = yaml.safe_load(text)
        if isinstance(value, (dict, list)):
            return value
    except (ImportError, ValueError):
        pass
    except Exception:
        # PyYAML raises its own parser exception hierarchy. The dependency-free
        # parser below still gets a chance to produce a stable PostError.
        pass
    try:
        return parse_simple_yaml(text)
    except PostError as exc:
        raise PostError("Sigma response was neither JSON nor parseable YAML: %s" % exc) from exc


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


class Client:
    def __init__(self, base_url=None, token=None, transport=sigma_rest):
        if base_url:
            os.environ["SIGMA_BASE_URL"] = base_url
        if token:
            os.environ["SIGMA_API_TOKEN"] = token
        self.transport = transport
        try:
            self.base = transport.base_url().rstrip("/")
        except transport.SigmaError as exc:
            raise PostError(
                "%s; run scripts/browser-login.sh once or configure "
                "SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET for unattended auth" % exc
            ) from exc
        self.token = token

    def request(self, method, path, body=None):
        try:
            raw = self.transport.request(
                method.lower(),
                path,
                body=json.dumps(body) if body is not None else None,
                accept="application/json, application/yaml, text/yaml",
            )
            return parse_payload(raw)
        except (self.transport.SigmaError, SystemExit) as exc:
            raise PostError("Sigma %s %s failed: %s" % (method, path, exc)) from exc


def find_id(value, kind):
    keys = (
        ("dataModelId", "data_model_id", "id", "fileId")
        if kind == "dm" else
        ("workbookId", "workbook_id", "id", "fileId")
    )
    if isinstance(value, dict):
        for key in keys:
            candidate = value.get(key)
            if candidate not in (None, ""):
                return str(candidate)
        for nested in value.values():
            candidate = find_id(nested, kind)
            if candidate:
                return candidate
    return None


def element_ids(readback):
    root = readback.get("document", readback) if isinstance(readback, dict) else {}
    elements = list(root.get("elements") or [])
    for page in root.get("pages") or []:
        if isinstance(page, dict):
            elements.extend(page.get("elements") or [])
    return [
        {"id": row.get("id"), "name": row.get("name"),
         "source_path": (row.get("source") or {}).get("path")}
        for row in elements if isinstance(row, dict) and row.get("id")
    ]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("dm", "workbook"))
    parser.add_argument("--spec", required=True)
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--folder-id")
    parser.add_argument("--id", help="explicit existing object id (read back; never POST)")
    parser.add_argument("--base-url", default=os.environ.get("SIGMA_BASE_URL"))
    parser.add_argument("--token", default=os.environ.get("SIGMA_API_TOKEN"))
    args = parser.parse_args(argv)

    workdir = Path(args.workdir).expanduser().resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("SIGMA_WORKDIR", str(workdir))
    sigma_rest.bootstrap_credentials(cwd=str(workdir))
    spec_path = Path(args.spec).expanduser().resolve()
    if not spec_path.is_file():
        parser.error("--spec does not exist: %s" % spec_path)

    prefix = "dm" if args.kind == "dm" else "wb"
    ids_path = workdir / ("%s-ids.json" % prefix)
    readback_path = workdir / ("%s-readback.json" % prefix)
    id_key = "dataModelId" if args.kind == "dm" else "workbookId"
    object_id = args.id
    if ids_path.is_file():
        try:
            existing = json.loads(ids_path.read_text(encoding="utf-8"))
            persisted = find_id(existing, args.kind)
            if object_id and persisted and object_id != persisted:
                raise PostError("explicit --id differs from persisted %s" % ids_path)
            object_id = object_id or persisted
        except json.JSONDecodeError as exc:
            raise PostError("malformed resume id file %s: %s" % (ids_path, exc)) from exc

    if not object_id and readback_path.is_file():
        try:
            prior_readback = json.loads(readback_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise PostError("malformed resume readback %s: %s" %
                            (readback_path, exc)) from exc
        object_id = find_id(prior_readback, args.kind)
        if not object_id:
            raise PostError(
                "%s exists without a recoverable %s; refusing to blindly re-POST "
                "(restore %s or pass --id)" %
                (readback_path, id_key, ids_path)
            )

    client = Client(args.base_url, args.token)
    posted = False
    if not object_id:
        body = json.loads(spec_path.read_text(encoding="utf-8"))
        if args.folder_id and isinstance(body, dict) and "folderId" not in body:
            body["folderId"] = args.folder_id
        endpoint = "/v2/dataModels/spec" if args.kind == "dm" else "/v2/workbooks/spec"
        response = client.request("POST", endpoint, body)
        object_id = find_id(response, args.kind)
        if not object_id:
            raise PostError("Sigma POST response contained no %s: %r" % (id_key, response))
        write_json(ids_path, {id_key: object_id})
        posted = True

    read_path = (
        "/v2/dataModels/%s/spec" % object_id
        if args.kind == "dm" else
        "/v2/workbooks/%s/spec" % object_id
    )
    try:
        readback = client.request("GET", read_path)
    except PostError as exc:
        if object_id:
            raise PostError(
                "resume/readback failed for existing %s %s; refusing to re-POST: %s" %
                (args.kind, object_id, exc)
            ) from exc
        raise
    if not isinstance(readback, dict):
        raise PostError("Sigma readback must be an object")
    write_json(readback_path, readback)
    write_json(ids_path, {
        id_key: object_id,
        "elements": element_ids(readback),
        "readback": readback_path.name,
    })

    if args.kind == "workbook" and posted:
        log_path = workdir / "posted-workbooks.jsonl"
        prior = []
        if log_path.is_file():
            prior = [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines()
                     if line.strip()]
        if not any(str(row.get("id")) == object_id for row in prior):
            name = json.loads(spec_path.read_text(encoding="utf-8")).get("name")
            with log_path.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(json.dumps({"id": object_id, "name": name}) + "\n")
    print("%s %s %s; readback -> %s" %
          (args.kind, object_id, "POSTed" if posted else "resumed", readback_path))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PostError as error:
        print("post-sisense-spec: %s" % error, file=sys.stderr)
        sys.exit(2)
