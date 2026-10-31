# Assets

The Koi and Koid Icon Composer projects and their SVG/PNG layers are original
Koi project artwork, covered by the project's GPL-3.0-only license. Both app
icons are retained. The standalone wordmark has been removed.

Program logos retain their CC0-1.0 license. Their
[source manifest](../src/app/resources/programs/logos/sources.json) records
the Simple Icons repository revision and each local file's SHA-256. Source
paths are `icons/<filename>` at that revision, with per-file revision
overrides for OpenAI, OpenCode, Cursor, Qwen and Cline. All 71 logos were compared with those upstream sources:
70 preserve path geometry exactly; the OpenAI path has one coordinate rounded
from `1.1685` to `1.1686`. Fill colors, titles and other presentation attributes
may differ. These are verification revisions, not a claim about the original
download date. The [third-party notices](../THIRD_PARTY_NOTICES.md) include
the complete CC0 text.

Brand names and logos identify programs; their inclusion does not imply
affiliation or endorsement. CC0 does not grant trademark rights. Toolbar and
device icons use system SF Symbols at runtime; no SF Symbols font or installed
terminal font is redistributed in this repository.

When replacing artwork, record its source, license and local modifications
and update the source manifest and applicable notices with the change.

Program identity selects a bundled logo and color palette from
[`programs.json`](../src/app/resources/programs/programs.json). OpenCode is
included. Logos and failed lookups are cached for the app's lifetime; there
are no runtime icon downloads. Unknown applications use Koi's `>_` mark on
a neutral tile; an unavailable catalog logo also uses `>_`.
See [Program icons](development.md#program-icons) for the catalog format,
asset requirements and the Python-only contribution check.
