import Foundation
import LocalisModels

/// `DiscoveredHost` satisfies `HostAdvertisement` as declared — the four
/// property names and types already line up, so the conformance is empty.
///
/// It is a separate file, and a deliberate one. Without it `LocalisHost(
/// adopting:)` was a rule that nothing on the network could be fed into: every
/// symbol involved was public and referenced, and the path from "a Mac appeared
/// on the LAN" to "we have a record of it" still did not exist. That is the
/// shape of defect this project keeps finding — a check that asks "is the
/// symbol used" answers yes the whole time.
///
/// Nothing is added here on purpose. Adoption reads exactly the four claims the
/// bridge broadcasts, and `source` stays behind: how a machine came to our
/// attention is presentation, and a manually typed address is neither more nor
/// less trusted than a broadcast one.
extension DiscoveredHost: HostAdvertisement {}
