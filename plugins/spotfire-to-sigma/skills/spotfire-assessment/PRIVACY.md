# Spotfire assessment privacy and read-only disclosure

Share this with the customer's security/privacy reviewer before live use.

## What the skill reads

Offline mode reads only the JSON file or committed synthetic fixture supplied
to it. Live mode reads Spotfire Library metadata with OAuth scope
`api.library.read`:

- Library root/type information (`GET /info`);
- accessible Library item metadata (`GET /items`);
- item IDs, titles, paths, types, owner/creator metadata and timestamps;
- favorites/access timestamps when exposed; and
- ACL counts when permissions are exposed.

It does not query warehouse rows, visualization result data, or SBDF data. It
does not download DXP content. Full manifests and normalized DXP inventories
can contain formulas, field/source names, scripts/data-function metadata, and
security mechanism descriptions because those are the migration specification.

## What it writes

Nothing is written to Spotfire or Sigma. Live Library calls are HTTP GETs. If
client credentials are supplied, the script may POST to
`/spotfire/oauth2/token`; that is an authentication exchange and does not
create or update Spotfire content.

All artifacts are local under the selected `--out` directory. No artifact is
uploaded automatically. Sharing is a deliberate user action.

## Credentials

`SPOTFIRE_ACCESS_TOKEN`, `SPOTFIRE_CLIENT_ID`, and
`SPOTFIRE_CLIENT_SECRET` are read from process memory. They are sent only to
the configured Spotfire host as required for OAuth/API authentication and are
never serialized to JSON/Markdown output or logged by the script. No Sigma
credential is read.

## Data exposed to the coding agent/model

When an agent runs or reasons over this skill, content shown to that agent can
be processed by the configured model provider. This can include:

- analysis titles and Library paths;
- owner display names when supplied;
- source/field names;
- formula text;
- security mechanism types and aggregate ACL counts;
- custom-script/data-function/mod names and languages;
- usage counts, favorites, access timestamps, and derived scores; and
- the generated readout.

OAuth secrets/tokens and underlying business rows must not be pasted into
prompts. The normal script does not print them.

Library ACL principal identities are intentionally minimized: normalization
keeps only entry counts and whether entries are explicit, not principal names
or permission lists. The unnormalized API response is held in process memory
and is not written by the assessment.

## Retention and deletion

Outputs remain wherever `--out` points. Use a fresh engagement-specific
directory, restrict its filesystem permissions as required, and delete it
according to the customer's retention policy. Fixture runs write only
synthetic outputs under `/tmp/spotfire-assessment-offline-*`.

## Deployment uncertainty

Spotfire Cloud API routing, tenant visibility, and data-processing terms are
not established by the Spotfire Server documentation. Confirm them with the
tenant administrator before live use. Prefer an approved offline export when
that review is incomplete.
