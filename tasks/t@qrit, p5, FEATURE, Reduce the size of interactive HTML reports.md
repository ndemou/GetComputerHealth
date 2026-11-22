<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:08.095Z","completions":[]} -->

Instead of including the findings in this fat "fieldname:value" format:
```
[
  {"Computer":"TEST-SERVER","Suppressed":true,"Level":"warning","EffectiveLevel":"postponed","Message":"Disk free space is below the threshold","Comment":"...","Hash":"d4e5f6a7"},
  {"Computer":"TEST-SERVER","Suppressed":true,"Level":"warning","EffectiveLevel":"postponed","Message":"Certificate expires soon","Comment":"...","Hash":"e5f6a7b8"}
]
```
Prefer this lighter csv-like format:
```
[
  ["TEST-SERVER",true,"warning","postponed","Disk free space is below the threshold","...","d4e5f6a7"],
  ["TEST-SERVER",true,"warning","postponed","Certificate expires soon","...","e5f6a7b8"]
]
```
So every finding is represented by a list of ordered values and all these lists are also bundled in a list (so a list of lists).
