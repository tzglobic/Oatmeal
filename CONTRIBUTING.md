# Contributing

Start with the [development guide](docs/development.md). Keep changes focused and
preserve compatibility with existing local meeting data. This project currently
targets native macOS; discuss platform or storage redesigns before implementing them.

For a bug, provide reproducible steps, expected and actual results, macOS version,
app commit/version, and relevant redacted errors. Use fictional meeting content.
Never attach private recordings, databases, API keys, or attendee information.

For a pull request:

- Explain the user-visible problem and resulting behavior.
- Add meaningful regression coverage for behavior changes.
- Run the documented checks and report limitations or untested hardware paths.
- Update documentation when controls, storage, permissions, or build behavior change.
- Avoid machine-specific paths, certificate names, account details, and real meeting fixtures.

Do not use public issues for credentials or exploitable security details; see
[security reporting](SECURITY.md). Contributions are made under the project’s [MIT license](LICENSE).
