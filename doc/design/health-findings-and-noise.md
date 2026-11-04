# Health Findings And Noise

## Decision

GetComputerHealth is an administrative health and configuration-review tool. It is not an endpoint detection and response product, an intrusion-detection system, or a replacement for security monitoring.

Some health tests can incidentally expose traces associated with malware or unauthorized activity. That is useful, but it is a secondary benefit rather than a primary design goal.

When broader attack detection would materially increase false positives or recurring operational noise, GetComputerHealth favors the lower-noise administrative signal. A finding should normally require administrator attention within the scope of routine computer health and configuration review.

## Consequences

- Do not interpret the absence of a GetComputerHealth finding as evidence that a computer is free of malware or unauthorized activity.
- Use Microsoft Defender for Endpoint, another EDR product, centralized event collection, and purpose-built security monitoring for threat detection.
- Prefer conservative, stable finding identities over volatile implementation details.
- Report useful low-confidence context as `INFO` when it is worth retaining but should not distract administrators in normal reports.
- Continue using `NOTICE`, `WARNING`, or `FAILURE` when evidence is sufficiently actionable for routine administration.
- Document deliberate cases where lowering noise means accepting reduced visibility of a possible attack technique.

## Scheduled Task Example

Short-lived one-shot scheduled tasks can be created by legitimate deployment and Group Policy mechanisms. Similar task structures can also be used by attackers.

`HealthTest-ListScheduledTasks` treats a task matching its transient-task criteria as informational. Its complete task definition remains available in the comments, but the inventory finding does not receive a policy fingerprint or a notable severity merely because the task was observed during its brief lifetime. If its non-empty `DeleteExpiredTaskAfter` value cannot be parsed, the inventory still treats the task as transient and emits a separate warning asking the administrator to check that value.

This inventory classification does not suppress independent operational findings from `HealthTest-ScheduledTasks`, such as a failed execution. See the [scheduled-task helpers](../../health-tests/helper-regarding-scheduled-tasks.ps1) and [inventory test](../../health-tests/HealthTest-ListScheduledTasks.ps1) for the current criteria and exclusions.

This accepts reduced visibility of malicious tasks that imitate the same lifecycle. The tradeoff is intentional: detecting that technique reliably belongs to EDR and security-event monitoring, while repeatedly alerting on legitimate transient deployment tasks would reduce the usefulness of routine health reports.
