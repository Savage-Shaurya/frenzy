import Darwin
import Foundation
import Testing
import HaloCore
@testable import HaloWorkerKit

/// The self-test's new probes (security review, Nov 2026), checked from the unsandboxed test runner: each one must tell
/// "allowed" from "denied", so the same probe inside the worker means something. The in-sandbox answers come from
/// `Frenzy --worker-self-test` on a built app.
@Suite struct LaunchServicesProbeTests {
    @Test func resolverSocketProbeReachesTheResolverOutsideTheSandbox() {
        // Unsandboxed, the socket is reachable, so EPERM inside the worker can only be the sandbox.
        let result = SandboxProbe.unixConnect("/private/var/run/mDNSResponder")
        #expect(result.errno == nil, "\(result.detail)")
        let missing = SandboxProbe.unixConnect("/private/var/run/halo-no-such-socket-\(UUID().uuidString.prefix(8))")
        #expect(missing.errno == ENOENT)
    }

    @Test func kernelVerdictSaysAllowedOutsideTheSandbox() {
        let verdict = SandboxProbe.sandboxVerdict("lsopen")
        #expect(verdict.allowed == true, "\(verdict.observed)")
    }

    @Test func machLookupTellsAKnownServiceFromAnUnknownOne() {
        #expect(SandboxProbe.machLookup("com.apple.CoreServices.coreservicesd").ok)
        let unknown = SandboxProbe.machLookup("com.snappycrew.halo.no-such-service")
        #expect(!unknown.ok)
        #expect(!unknown.observed.contains("NOT_PRIVILEGED"), "an unknown name is not a sandbox denial: \(unknown.observed)")
    }

    @Test func selfTestListsTheLaunchServicesAndDNSProbes() {
        let names = SandboxProbe.launchServicesProbes().map(\.name)
        #expect(names.contains { $0.contains("lsopen") })
        #expect(names.contains { $0.contains("LaunchServices") })
        #expect(names.contains { $0.contains("pasteboard") })
        // What PRIVACY.md documents is what an unsandboxed process sees too, so all pass here.
        #expect(SandboxProbe.launchServicesProbes().allSatisfy { $0.pass })
    }
}
