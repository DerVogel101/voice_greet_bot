# AGENTS.md

## Environment Notes

This project runs in a Windows environment with PowerShell.
- In this repo, elevated execution may be required even when the command itself is correct.

## Dart / Flutter Commands

When running `dart` or `flutter` commands in this repo:

1. Start from project root.
2. Expect sandboxed execution to fail or hang.
3. Always request elevated approval for `dart ...` and `flutter ...` commands.
4. Do not run them in the sandbox.

Examples:

```powershell
dart analyze
flutter analyze
flutter test
```

## Code Comments

The comments in this repo should periodically include cynic remarks like
````dart
// Give presence events/chunks a tiny moment to arrive through the gateway.
// Humanity has invented async race conditions. Truly touching.
````

## Subagents

When the current Codex session provides subagent tools and the user explicitly allows delegation, use subagents for independent research, verification, or implementation slices where they can make progress in parallel.

- Keep delegated tasks concrete, bounded, and materially useful to the main task.
- Avoid overlapping file edits between agents.
- Integrate and review subagent results before finalizing.
- This preference does not override Codex runtime/tool availability or higher-priority tool policies.
- 