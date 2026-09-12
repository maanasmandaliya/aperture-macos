//
//  AppleScriptRunner.swift
//  Aperture
//

import Foundation

/// Executes AppleScript off the main thread on a private serial queue.
///
/// Scripts are compiled per execution rather than cached. Caching them was
/// tried and measured: it saved 0.2% of a core and held 14.7 MB of compiled
/// script objects, which is a bad trade for an app that is meant to disappear
/// into the menu bar. The Apple event round trip dominates either way.
///
/// `NSAppleScript` is not thread-safe, so each instance is created, used and
/// discarded inside one queue hop. Compilation is cheap next to the Apple event
/// round trip, which can stall for seconds if the target app is busy — which is
/// exactly why this must never run on the main thread. The result descriptor is
/// also non-`Sendable`, so it is reduced to a plain value *on the queue* and
/// only that value crosses back.
final class AppleScriptRunner: Sendable {

    struct ScriptError: Error, Sendable {
        var code: Int
        var message: String

        /// -1743 is `errAEEventNotPermitted`; -1744 means the user has not been
        /// asked yet. Both mean "no Automation permission".
        var isAuthorizationFailure: Bool { code == -1743 || code == -1744 }
    }

    private let queue = DispatchQueue(label: "com.aperture.applescript", qos: .utility)

    func runReturningString(_ source: String) async -> Result<String, ScriptError> {
        await run(source) { $0.stringValue ?? "" }
    }

    func runReturningData(_ source: String) async -> Result<Data?, ScriptError> {
        await run(source) { descriptor in
            guard descriptor.descriptorType != typeNull else { return nil }
            let data = descriptor.data
            return data.isEmpty ? nil : data
        }
    }

    private func run<T: Sendable>(
        _ source: String,
        reduce: @escaping @Sendable (NSAppleEventDescriptor) -> T
    ) async -> Result<T, ScriptError> {
        await withCheckedContinuation { continuation in
            queue.async {
                // Everything a script execution touches is autoreleased —
                // descriptors, the error dictionary, OpenScripting's own
                // temporaries — and a dispatch queue makes no promise about
                // when it drains. Left to itself this process grew about 20 MB
                // an hour, all of it live allocations under `OSACompile`.
                // Draining per execution keeps the footprint flat.
                autoreleasepool {
                    guard let script = NSAppleScript(source: source) else {
                        continuation.resume(returning: .failure(
                            ScriptError(code: -1, message: "Could not compile script")
                        ))
                        return
                    }
                    var errorInfo: NSDictionary?
                    let descriptor = script.executeAndReturnError(&errorInfo)
                    if let errorInfo {
                        let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? -1
                        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown scripting error"
                        continuation.resume(returning: .failure(ScriptError(code: code, message: message)))
                    } else {
                        continuation.resume(returning: .success(reduce(descriptor)))
                    }
                }
            }
        }
    }
}
