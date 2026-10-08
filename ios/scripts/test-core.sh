#!/bin/zsh
# Compile ios/PhoneTracker/Core with the unit tests and run them; needs only Xcode Command Line Tools.
set -euo pipefail
here=${0:A:h}; ios=${here:h}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
for f in "$ios"/PhoneTrackerTests/*.swift; do
  sed -e 's/^import XCTest$/import Foundation/' -e '/^@testable import/d' "$f" > "$work/${f:t}"
done
# Classes are discovered by their `static let allTests`.
{ echo 'import Foundation'; echo 'print("PhoneTracker core tests")'
  grep -ho 'final class [A-Za-z]*Tests' "$ios"/PhoneTrackerTests/*.swift | awk '{print "run(" $3 ".self, " $3 ".allTests)"}'
  echo 'print(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)"); exit(failures == 0 ? 0 : 1)'
} > "$work/main.swift"
flags=()
# Some Command Line Tools releases ship SwiftBridging twice; hide the duplicate for this compile only.
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap && ! -d /Applications/Xcode.app ]]; then
  : > "$work/empty.modulemap"
  print -r -- "{\"version\":0,\"roots\":[{\"type\":\"file\",\"name\":\"/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap\",\"external-contents\":\"$work/empty.modulemap\"}]}" > "$work/overlay.yaml"
  flags=(-vfsoverlay "$work/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$work/overlay.yaml")
fi
swiftc -O "${flags[@]}" -module-name PhoneTrackerCoreTests "$ios"/PhoneTracker/Core/*.swift "$here/XCTestShim.swift" "$work"/*.swift -o "$work/run"
"$work/run"
