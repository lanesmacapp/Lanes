#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/test-module-cache
xcrun swiftc -swift-version 5 -module-cache-path build/test-module-cache Sources/Model.swift Tests/main.swift -o build/lanes-tests
build/lanes-tests

xcrun swiftc -swift-version 5 -module-cache-path build/test-module-cache Sources/Model.swift Sources/NativeResizeGrip.swift Tests/NativeGripTests.swift -o build/native-grip-tests -framework AppKit -framework SwiftUI
build/native-grip-tests

xcrun swiftc -swift-version 5 -module-cache-path build/test-module-cache Sources/Model.swift Sources/WindowManager.swift Tests/AppDiscoveryTests.swift -o build/app-discovery-tests -framework AppKit -framework ApplicationServices
build/app-discovery-tests

xcrun swiftc -swift-version 5 -module-cache-path build/test-module-cache Sources/Model.swift Sources/HoverScrollView.swift Tests/NativeHoverTests.swift -o build/native-hover-tests -framework AppKit -framework SwiftUI
build/native-hover-tests

xcrun swiftc -swift-version 5 -module-cache-path build/test-module-cache Sources/Model.swift Sources/WindowManager.swift Tests/WindowFocusTests.swift -o build/window-focus-tests -framework AppKit -framework ApplicationServices
build/window-focus-tests

# Every common display size, as main and second display. LANES_SWEEP_SHEET=build/display-sweep.png ./test.sh draws them all.
xcrun swiftc -swift-version 5 -module-cache-path build/test-module-cache Sources/Model.swift Sources/WindowManager.swift Tests/DisplaySweepTests.swift -o build/display-sweep-tests -framework AppKit -framework ApplicationServices
build/display-sweep-tests

# A real strip in an invisible off-screen window: hover ×, and rapid closing at one spot.
xcrun swiftc -swift-version 5 -module-cache-path build/test-module-cache Sources/Model.swift Sources/WindowManager.swift Sources/Views.swift Sources/Editor.swift Sources/NativeResizeGrip.swift Sources/LanePicker.swift Sources/HoverScrollView.swift Sources/Tour.swift Tests/StripCloseTests.swift -o build/strip-close-tests -framework AppKit -framework SwiftUI -framework ApplicationServices -framework Carbon -framework ServiceManagement
build/strip-close-tests

# The desktop row under the display dropdown: made-up Mission Control desktops, a grid per desktop, and the row's size.
# LANES_DESKTOP_ROW_PNG=/path/prefix ./test.sh also saves the row as PNGs.
xcrun swiftc -swift-version 5 -module-cache-path build/test-module-cache Sources/Model.swift Sources/WindowManager.swift Sources/Views.swift Sources/Editor.swift Sources/NativeResizeGrip.swift Sources/LanePicker.swift Sources/HoverScrollView.swift Sources/Tour.swift Tests/DesktopSwitcherTests.swift -o build/desktop-switcher-tests -framework AppKit -framework SwiftUI -framework ApplicationServices -framework Carbon -framework ServiceManagement
build/desktop-switcher-tests
