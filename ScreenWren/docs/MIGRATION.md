# ScreenWren migration to mac-tools

ScreenWren was imported on October 10, 2026 from
[diamondplated/screenwren](https://github.com/diamondplated/screenwren), whose source
HEAD was `bd0f671d279f8e640d1191504693b08ac57fdf97`.

The import preserves the current working-tree changes and relevant untracked
source, tests, documentation, and scripts in the old standalone `screenwren` checkout.
The original checkout remains untouched. The consolidation commit also retains
the previous repository's complete Git history as a second merge parent, without
rewriting those commits. Continue development in `mac-tools/ScreenWren`.

Generated builds, archives, Git metadata, and nested GitHub workflows and issue
templates are excluded. The mac-tools root owns CI, releases, and issue tracking.
Local signing identity and timestamp preferences may be copied into their ignored
files in `ScreenWren/`; these values and private keys are not committed.

ScreenWren's existing app code, version, bundle identifier, login item, and
preferences were preserved by the import. The integrated version adds a validated
settings bridge and a menu link to the manager. Run ScreenWren's individual build and
QA scripts from this directory, or use the suite commands at the mac-tools root.
