name: 🐛 Bug Report
description: Report a reproducible bug or unexpected behavior
labels: [fix]
body:
  - type: input
    id: title
    attributes:
      label: Short Title
      description: E.g. `[fix] error when parsing blank config file`
      placeholder: "[fix] error when parsing blank config file"
    validations:
      required: true
  - type: textarea
    id: steps
    attributes:
      label: Steps to Reproduce
      description: Provide the steps needed to reproduce the issue.
    validations:
      required: true
  - type: textarea
    id: expected
    attributes:
      label: Expected Behavior
      description: Describe what you expected to happen.
    validations:
      required: true
  - type: textarea
    id: actual
    attributes:
      label: Actual Behavior
      description: What actually happened?
  - type: textarea
    id: context
    attributes:
      label: Additional Context
      description: Include version info, logs, screenshots, etc.
