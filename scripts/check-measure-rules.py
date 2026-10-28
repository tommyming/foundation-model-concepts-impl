#!/usr/bin/env python3
"""Fails if the two measurement rules leave AppModel.perform."""

from pathlib import Path

text = Path("app/Sources/AppModel.swift").read_text()
perform = text.split("private func perform", 1)[1].split("private func prepareRun", 1)[0]
fail = text.split("private func fail", 1)[1].split("private func secondsString", 1)[0]

assert perform.index("rebuildSessions()") < perform.index("prepareRun(")
assert perform.index('fail("Cancelled")') < perform.index("lastMetrics =")
assert "lastMetrics = nil" in fail
session = text.split("private func makeSession", 1)[1].split("private func fail", 1)[0]
assert '["enable_thinking": false]' in session
failed_load = text.split("if let error = box.error", 1)[1].split("throw error", 1)[0]
assert "activeAdapter = nil" in failed_load
print("measure rules ok")
