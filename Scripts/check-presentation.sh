#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc Sources/Oatmeal/NoteCheckbox.swift Sources/Oatmeal/NotesDocument.swift \
    Sources/Oatmeal/MeetingTimeline.swift Tests/PresentationChecks.swift \
    -o .build/checks/presentation
.build/checks/presentation
