# How to add built-in Health Tests

## Step 1, Write a custom Health tests first and verify it's working

Read `how-to-add-custom-tests.md`

## Step 2, add the required help-block

Every built-in `HealthTest-*` function must include an **in-function** comment-based help block immediately after the opening `{`.

```powershell
function HealthTest-Example {
<#
.SYNOPSIS
Checks if foo is of type bar

.DESCRIPTION
AppliesTo: DC
Scope: Computer
Category: Availability / Server Down Signals, Security & Stability Risks.
Impact: Medium(Time), High(Network)
Uses: Get-FooType
#>
  # ...
}
```

- `.SYNOPSIS` is mandatory and must be **<= 320 characters**. It must explain what the test detects/checks, and the key signal logic used to decide healthy vs unhealthy.
- `.DESCRIPTION` is mandatory and must be **<= 900 characters**.
- Do not add any other help sections (e.g. `.PARAMETER`, `.OUTPUTS`, `.EXAMPLE`).
  
For the `.DESCRIPTION` use plain text with one field per line in this exact order, so it is easy to lint with regex:

1. `AppliesTo:` Type of computer (One of: `All`, `VM`, `Mobile`, `DomainJoined`, `Server`, `Workstation`, `DC`, `PDC` ). The test will only run if it applies.
2. `Scope:` `Computer`, `Domain`, `Forest`. The scope that is being tested/verified. i.e. if Scope=Domain you only need to run the test from one computer of the domain.
3. `Category:` Primary + optional Secondary (see below for list). Informational.
4. `Impact:` `Medium` or `High`, and include resource dimension only if not low (`CPU`, `Disk`, `Network`, `Time`).
5. `Uses:` List of up to three essential for the test external cmdlets/executables. E.g. Get-Services, Get-ADComputer,.... Informational.
  > This field is intended for essential dependency metadata, not implementation details. Include only essential external commands (e.g., `ipconfig.exe`, `Get-DnsServerZone`) that are both required to execute the test and return the core information that determines if the test passes. Do not list a) a function defined within this repository b) helper calls c) broad commands like `Get-Service`, or `Get-ADUser` unless they represent the **sole** essential dependency of the test. Avoid descriptive sentences. Use `Uses: None.` for empty dependencies.
6. `FalsePositives:` short note. Optional. Informational.

Allowed values for `Category`:
- `Availability / Server Down Signals`
- `Security & Stability Risks`
- `Configuration Hygiene & Best Practices`
- `Audit / Compliance / Informational`

## Step 3, Consider the optional features below

If your function fits the Policy Inventory description make sure to tag it. You'll make the life of users much easier.

Consider any other optional feature.

## Step 4, place in the proper file -- done.

Chose the most suitable `ht-*.ps1` file to append your function. They have a short description at their top.

## Optional Features for Health Tests

### Tags in test names

You can attach tags directly in the test function name by adding `__` and one or more letters or digits after the base name.

Example:
- `HealthTest-SomeName__SP` (a Slow & Policy test)

Currently supported tags:
- `S`: Slow test (skiped when using `-SkipSlowTests`)
- `E`: Quick & Essential test (the only tests to be executed when using `-Quick`)
- `P`: Policy Inventory test 
- `D`: Domain-wide test (reserved, not yet in use)

### More about the S(Slow) Tag
If your function takes a lot of time (e.g. more than 5sec) and you want it to be skipped when the user includes the `-SkipSlowTests` switch on invocation, tag it with `S`.

Example:
```powershell
function HealthTest-LargeDirectories__S {}
```

### More about the P(Policy Inventory) Tag

These are tests that report a finding for every item of a particular aspect of the current system state which, depending on policy, might be either benign or not. Examples: open ports, installed SW, enabled services.

So these tests help you define a "Baseline Inventory" or "Expected Surface" and then detect drift/deviations.

Special handling on first run:

- The first time a `P` test runs, and only if `-DontAutosetPolicy` was **not** used, code emits and then automatically suppresses every `[warning]` and `[notice]` finding from that policy test (but **not** `[failure]` findings).
- On that first run, code appends a marker line to `Get-ComputerHealth.sigs-to-suppress.txt` in this format:
  - `POLICY_TEST_WAS_RUN: HealthTest-PolicyOpenPorts`
- This marker lets the code distinguish the first execution from all later executions.
- After that first run, the automatic suppression is not performed again for that policy test.

This "first run only" behavior allows you to add new policy inventory tests without immediately creating noisy findings for users. The current policy state on that first run is treated as the accepted baseline.

