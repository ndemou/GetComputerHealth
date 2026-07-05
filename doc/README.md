# Documentation Map

This page is the routing table for the repository documentation. It is meant for both humans and LLM agents that need to find the right source quickly.

## Start Here

| Need | Read |
| --- | --- |
| Install, run, configure daily checks, or understand available health tests | [`README.md`](../README.md) |
| Contribute code or docs to the repo | [`CONTRIBUTING.md`](../CONTRIBUTING.md) |
| Follow repo-specific coding, test, and release instructions as an agent | [`AGENTS.md`](../AGENTS.md) |
| Add local custom health tests without changing the repo | [`user/custom-tests.md`](./user/custom-tests.md) |
| Understand the test suite and choose validation commands | [`contributor/test-suite.md`](./contributor/test-suite.md) |
| Review current backlog and rough ideas | [`TODO.md`](../TODO.md) |

## User Guides

| File | Owner |
| --- | --- |
| [`README.md`](../README.md) | User-facing overview, installation, common operations, architecture summary, and generated built-in test catalog. |
| [`user/custom-tests.md`](./user/custom-tests.md) | User-facing guide for out-of-tree custom tests under `config\Custom-HealthTests`. |
| [`user/custom-test-helpers.md`](./user/custom-test-helpers.md) | Optional helper examples for custom health tests. |
| [`user/reporting.md`](./user/reporting.md) | Notes about reporting behavior and artifacts. |

## Contributor And Design Guides

| File | Owner |
| --- | --- |
| [`CONTRIBUTING.md`](../CONTRIBUTING.md) | Contributor workflow, repository layout, testing policy, and built-in health-test organization rules. |
| [`contributor/built-in-health-tests.md`](./contributor/built-in-health-tests.md) | Detailed conventions for built-in `HealthTest-*` functions and their help blocks. |
| [`contributor/test-suite.md`](./contributor/test-suite.md) | Detailed explanation of test runners and validation choices. |
| [`design/installation-migrations.md`](./design/installation-migrations.md) | On-disk format migration design and implementation rules. |
| [`design/invoke-getcomputerhealth-flow.md`](./design/invoke-getcomputerhealth-flow.md) | Execution flow for `Invoke-GetComputerHealth.ps1`. |
| [`../tests/testing-improvement-plan.md`](../tests/testing-improvement-plan.md) | Historical test-suite improvement plan. |

## Working Notes

| File | Owner |
| --- | --- |
| [`TODO.md`](../TODO.md) | Backlog, rough design notes, and untriaged ideas. Treat this as planning input, not stable documentation. |
| [`../tests/README.md`](../tests/README.md) | Lightweight pointer from the `tests` folder to the canonical testing docs. |

## Maintenance Rules

- Keep durable user instructions in `README.md` or focused files under `doc`.
- Keep contributor workflow and repo policy in `CONTRIBUTING.md`.
- Keep agent-specific instructions in `AGENTS.md`; do not duplicate them in general docs unless humans also need them.
- Keep exploratory notes in `TODO.md`; when an idea becomes policy or implementation guidance, move the stable part into `README.md`, `CONTRIBUTING.md`, or `doc`.
- Prefer one canonical document for each topic and link to it from other files instead of copying the same guidance.
- When adding a new Markdown file, add it to this map.

## LLM Routing Hints

- For code changes, read `AGENTS.md`, then `CONTRIBUTING.md`, then only the focused guide for the touched area.
- For health-test work, read `CONTRIBUTING.md` and `contributor/built-in-health-tests.md`.
- For custom-test help, read `user/custom-tests.md` before looking at built-in health-test internals.
- For test failures or validation planning, read `contributor/test-suite.md`.
- For updater, installer, or release-package layout changes, read `design/installation-migrations.md` and the release notes in `AGENTS.md`.
