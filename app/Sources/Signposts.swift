// Lifecycle signposts: these appear in Instruments' Points of Interest track.

import Foundation
import os

enum DemoSignposts {
    static let poster = OSSignposter(subsystem: "com.iosconf.aimemorylab", category: "ModelManager")

    /// Marks an interval; returns the state to end it with.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        poster.beginInterval(name, id: poster.makeSignpostID())
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        poster.endInterval(name, state)
    }

    static func event(_ name: StaticString) {
        poster.emitEvent(name)
    }
}
