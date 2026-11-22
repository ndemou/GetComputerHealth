<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:42:47.136Z","completions":[]} -->

GitHub source: [#138](https://github.com/ndemou/GetComputerHealth/issues/138)

A nice classification of health test function in categories will be nice to have.

Is this classification of `HealthTest-*` functions good or should I tweak definition of classes or add/subtract some?
 1. (Security) Attack Surface Reduction: detect deviations from widely accepted design rules, build standards and minimal hardening rules.
 2. (Security) List security related system state to detect deviations from custom security/hardening rules.
 3. (Functionality) Check if a component is failing or degraded (e.g. low or out of resources, failing to communicate, etc).
 4. (Functionality) List non-security related system state to detect deviations from custom configurations.

Any other classifications we should have?
