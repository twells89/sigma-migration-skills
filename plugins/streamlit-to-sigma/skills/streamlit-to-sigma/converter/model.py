"""Serializable intermediate representation for Streamlit projects."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


IR_VERSION = 1


@dataclass
class Provenance:
    file: str
    line: int


@dataclass
class Query:
    id: str
    function: str
    sql: str
    columns: list[str]
    dynamic: bool
    provenance: Provenance


@dataclass
class Dataframe:
    name: str
    root_query: str | None
    operations: list[str]
    expression: str
    provenance: Provenance


@dataclass
class Control:
    id: str
    control_type: str
    selection_mode: str
    label: str
    variable: str | None
    dataframe: str | None
    column: str | None
    default: Any
    sidebar: bool
    page: str
    provenance: Provenance
    context: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class Element:
    id: str
    kind: str
    label: str
    page: str
    dataframe: str | None
    bindings: dict[str, Any]
    expression: str | None
    context: list[dict[str, Any]]
    provenance: Provenance


@dataclass
class Page:
    id: str
    name: str
    file: str
    order: int


@dataclass
class Gap:
    code: str
    severity: str
    message: str
    feature: str
    provenance: Provenance
    affected: list[str] = field(default_factory=list)
    resolved: bool = False
    resolution: str | None = None


@dataclass
class SecurityFinding:
    code: str
    message: str
    provenance: Provenance


@dataclass
class ProjectIR:
    source_root: str
    main_file: str
    project_name: str
    pages: list[Page] = field(default_factory=list)
    queries: list[Query] = field(default_factory=list)
    dataframes: list[Dataframe] = field(default_factory=list)
    controls: list[Control] = field(default_factory=list)
    elements: list[Element] = field(default_factory=list)
    gaps: list[Gap] = field(default_factory=list)
    security: list[SecurityFinding] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {"irVersion": IR_VERSION, **asdict(self)}
