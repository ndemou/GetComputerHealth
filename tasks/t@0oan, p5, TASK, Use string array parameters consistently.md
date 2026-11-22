<!-- tat-metadata: {"version":2,"created_at":"2026-11-22T17:37:08.302Z","completions":[]} -->

This style works like this:
```
 -Arg1 test,foo,bar             --> @("test","foo","bar")
-Arg1 @("test","foo","bar")    --> @("test","foo","bar")
-Arg1 "test,foo,bar"           --> "test,foo,bar"
-Arg1 "test foo bar"           --> "test foo bar"
```
  If I do not expect the values to contain spaces or commas, I could fix the last two cases manually.
