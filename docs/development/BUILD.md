# Build isolation

Xcode GUI and CLI builds must not share a DerivedData directory or `XCBuildData/build.db`.

- Xcode GUI uses Xcode's default DerivedData location.
- CLI builds use `/private/tmp/inf6-cli-derived-data` through `scripts/build-inf6-cli.sh`.
- The CLI entry point rejects a concurrent CLI build instead of sharing its database.
- The project-local `build/` directory is not a data store and must not be used as a build destination.

For a Designed for iPad build:

```sh
./scripts/build-inf6-cli.sh CODE_SIGNING_ALLOWED=NO build
```

The application User Setting Root, paper files, PDFs, metadata, crops, and indexes are outside these build paths and must not be deleted as build cleanup.
