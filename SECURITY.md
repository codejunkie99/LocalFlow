# Security and privacy

## Supported version

Security and privacy fixes are applied to the latest revision on the default branch.

## Reporting a problem

Please use GitHub’s private security-advisory workflow instead of opening a public issue. Include the affected revision, macOS version, reproduction steps, and impact. Do not include real transcripts, clipboard contents, or recordings.

## Trust boundaries

LocalFlow is designed to keep speech and text on the Mac:

- Microphone buffers are processed in memory and are not written to disk.
- Transcripts and Foundation Models prompts are not persisted.
- Application logs contain timing and state only.
- No network client is used by LocalFlow.
- macOS owns the Microphone, Speech Recognition, and Accessibility permission decisions.

Apple may download system-managed speech or language-model assets. That operating-system behavior is outside LocalFlow’s process and storage boundary.
