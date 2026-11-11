# Arcane Derivation Codex

An iPad-first application for studying machine learning through source papers, mathematical derivations, computation, and implementation. The repository snapshot contains application source, tests, selected design documents, model-conversion code, and Xcode project configuration.

## Scope of this snapshot

This is a source-only portfolio snapshot taken from the committed DevOps revision. Training datasets, checkpoints, model weights, compiled Core ML packages, generated evaluation output, build caches, and credentials are excluded to keep the repository small. As a result, a complete app build or on-device inference requires the corresponding model assets to be supplied separately; this snapshot does not claim those assets are present or that the app builds from this export alone.

## Main areas

- `Sources/`: Swift application implementation
- `Tests/`, `iOSAppUITests/`: test source
- `ModelConversion/`: model conversion and analysis source code
- `Design/`: selected product and model design documents
- `ArcaneDerivation.xcodeproj/`, `project.yml`: project configuration

No license is declared in this snapshot.

## Snapshot synchronization

Synchronized from Azure DevOps commit `a70e1436` on 2026-11-12. Training runs, checkpoints, model weights, compiled Core ML packages, generated evaluation output, release media, and credentials are excluded.
