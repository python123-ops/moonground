# MoonGround development

Use MoonBit 0.10.18. The reusable library uses the four stable targets; the
streaming command is native and the browser bridge is JavaScript.

Keep package boundaries shallow. Public concrete types belong to their public
package. Use typed errors, `///|` blocks, explicit trait extensions, checked
finite arithmetic and focused black-box tests. Never replace missing measurements
with zero speed or label a filtered polyline as actual travelled distance.

Before committing, run `moon fmt`, `moon info`, and strict checks for changed
packages. Before delivery, run the all-target suite, independent numerical
reference, CLI/browser parity and packaged consumer. Record actual results;
reference-source inspection alone is not a test result.

Do not change any sibling project. Keep external datasets under ignored
`validation/data/`; do not put downloaded research data in the release archive.
