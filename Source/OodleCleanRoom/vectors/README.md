# Local test vectors

The public repository intentionally excludes raw `.oodle` and `.expected`
files derived from game saves. They may contain Steam account identifiers,
entitlements, and personal progress.

To run the full decoder regression suite, place private fixtures in this
directory using matching names:

```text
sample-name.oodle
sample-name.expected
```

Generate them with `tools/extract_vectors.py` from saves that you are permitted
to process. Do not commit generated fixtures or `manifest.json` unless every
identifying field has been removed and redistribution is permitted.
