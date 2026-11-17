## Summary

<!-- What changed and why. Link related issues (e.g. "Fixes #123"). -->

## Type of change

<!-- Check one: -->
- [ ] Bug fix (`fix:`)
- [ ] New feature (`feat:`)
- [ ] Protocol / golden-vector change
- [ ] Documentation (`docs:`)
- [ ] Chore / tooling (`chore:`, `ci:`)

## Checklist

- [ ] `flutter analyze` clean in every touched package (warnings are fatal in CI)
- [ ] `flutter test` passing in every touched package
- [ ] UI strings added to **both** `app_zh.arb` (template) and `app_en.arb`,
      followed by `flutter gen-l10n` — no hardcoded copy
- [ ] Colors/styles go through design tokens (`context.nl.*`), not raw values
- [ ] Tests added or updated for behavior changes
- [ ] Commit messages follow Conventional Commits
