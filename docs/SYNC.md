# Updating this Iris from Friday's

Iris keeps growing inside Friday first. To bring her latest app code here:

```sh
python3 tools/sync_from_friday.py ~/Desktop/github/Friday/Friday/iris
cd app && swift build -c release
git diff                      # read every change before committing
```

The sync copies her Sources, Package.swift, Info.plist and catalog.json, then re-applies the edits that make her
nobody's in particular (bundle id, permission texts, wake words / agent name / port / data folder from `Config`,
no personal names in her recognizer, the first-run welcome, comments without dated diary tags). It stops and names
the edit if one no longer applies, and refuses to finish if a personal name is left. The names it checks for are
read from `tools/private_words.txt`, one per line. That file is untracked on purpose: a public list of private words
would publish them. Art is not synced (see [ART.md](ART.md)).
