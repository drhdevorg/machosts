# MacHosts JSON exchange, version 1

Implemented October 26, 2026. This portable source format is distinct from the
workspace persistence schema. It is neither a complete application backup nor a
system recovery artifact. No privileged operation or download occurs on import.

Open **Import / Export…** and choose **Review JSON import…** or **Export workspace
JSON…**. Export captures all live profiles and folders when the exchange sheet
opens. Later edits in another window do not change that export. Choose a new
filename; existing destinations, including links, are refused. A failed write may
leave a partial new file; retry with another name.

## Wire contract

UTF-8 JSON, `format` exactly `MacHosts`, integer `version` exactly `1`, and required
`folders` and `profiles` arrays. IDs are UUID strings. Optional parent/folder IDs may
be absent or null. All IDs share one namespace. Array order preserves folder order
and profile composition order. Example (synthetic documentation addresses):

```json
{
  "format": "MacHosts",
  "version": 1,
  "folders": [
    {"id": "00000000-0000-0000-0000-000000000001", "name": "Staging"}
  ],
  "profiles": [
    {
      "id": "00000000-0000-0000-0000-000000000002",
      "name": "Shop",
      "folderID": "00000000-0000-0000-0000-000000000001",
      "source": "# staging\r\n192.0.2.42 shop.example\r\n"
    }
  ]
}
```

Exports include only these fields. Activation, revisions, trash, receipts, pending
apply/recovery state and system contents are omitted. Remote profiles export their
cached source text as ordinary local copies; remote origin/refresh behavior is not
represented. Profile text itself is exported completely and may contain private
comments or URLs. This is an explicit user-selected export, not a redaction tool.

Unknown format/version values are rejected; this is not a SwitchHosts importer.
Extra object properties are ignored by the version-1 decoder and cannot set app or
system state. No compatibility with future versions is implied.

## Review, selection and append

Review shows counts, same-name profile counts against the current workspace,
folders with their immediate parent names, and every profile's complete selectable
read-only source. Select each profile to inspect it; parser diagnostics are shown
(up to 20 with an explicit notice). Invalid hosts syntax remains an editable draft.
Unsupported encoding, incomplete parser results and oversized inputs are rejected.
Cancel changes nothing.

All profiles and folders are selected initially. Use **Include this profile** while
reviewing each source, or select/deselect all profiles. The selected count and
same-name profile count reflect the current selection. **Include all folders,
including empty folders** preserves the complete folder tree by default. Turn it
off to import only folders required by selected profiles, including all their
ancestors. The folder disclosure lists the folders available in the file; it does
not change the selection. Deselecting every profile still permits a folders-only
import when all folders are included. An entirely empty selection cannot be
confirmed. Source review and inclusion are separate: inspecting a profile does
not toggle its inclusion.

Explicit append assigns fresh IDs to every selected profile/included folder, remaps references, and
creates inactive local profiles with revision zero. Existing objects, including
same-name folders/profiles, remain separate. Reimport intentionally creates another
set of independent copies. There is no merge/update-by-name or ID, deduplication,
replacement, network refresh or implicit activation. The append is one draft
revision and uses ordinary autosave; it does not establish applied state.

Names, unique IDs, complete folder references, acyclic hierarchy (at most 16
levels), 500 combined live/deleted profiles, 1 MiB per profile, 50,000 source lines
and the complete 32 MiB serialized workspace limit are validated. Reads also enforce
32 MiB while streaming, independent of file metadata. Budgets apply to the selected subset together with existing
profiles/trash at confirmation time. The complete input file must still pass format,
source and size validation before selection; excluded malformed objects do not bypass
validation. Unknown selection IDs are rejected. All-or-nothing failure preserves the current
draft and reviewed import. Nothing is silently truncated.

Gate 7 remains open. Workspace replacement requires a separate explicit review and
prior local backup; that flow, SwitchHosts formats, remote profiles and native
file-panel/accessibility acceptance remain outstanding. Verification is recorded in
[phase 7](verification/phase-7.md).
