import DesignKit
import LocalisModels
import SwiftUI
import TransportKit

/// Adding a Mac: what is on the network, what the user can type, and the
/// exchange that makes one of them usable.
///
/// **This screen is the visible half of B-2.** `BridgePairing` has been able to
/// pair for as long as it has existed and nothing called it, so every host the
/// app could produce was `.discovered` forever and the only "Paired" pill anyone
/// had seen came from `DemoSeed` writing the state directly. A pairing path with
/// no way in is indistinguishable from no pairing path: the suites are green,
/// the transport is correct, and the user cannot connect to anything.
///
/// **Why both fields are typed by hand, and why there is no scanner.** The Mac
/// prints two things at start-up — a `pin` line and a six-digit code — and they
/// come off its screen through the same out-of-band channel. That is what makes
/// the fingerprint a trust anchor rather than something the bridge asserts about
/// itself (Amendment E §3), and it is why the pairing request can go out already
/// pinned. A QR code would carry the same two values; it would also mean
/// changing what the bridge prints, which is not this change.
struct AddHostView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Built by the caller, so this screen holds no repository and cannot
    /// decide how one is made.
    @State private var model: HostPairingModel

    /// Which sighting the form is filled in for. Nil until one is chosen: the
    /// code and the fingerprint belong to a specific machine, and a form with no
    /// machine attached invites pairing whichever row happens to be first.
    @State private var selected: DiscoveredHost?
    @State private var code = ""
    @State private var fingerprint = ""
    @State private var typedAddress = ""
    /// A refusal from `addManualHost`, which throws where pairing does not —
    /// bad input is refused before anything is offered, and the two failures
    /// belong to different fields.
    @State private var addressError: String?

    init(model: HostPairingModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                discoveredSection
                manualSection
                if let selected {
                    pairingSection(for: selected)
                }
            }
            .navigationTitle(String(localized: "Add a Mac"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
        .task {
            model.startDiscovery()
        }
        .onDisappear {
            // The browse holds the radio awake. Nothing is reading this stream
            // once the sheet is gone.
            model.stopDiscovery()
        }
        .onChange(of: model.pairedHost) { _, paired in
            // Closes on success only. A failure keeps the sheet up with its
            // sentence on screen — dismissing would take away the one thing
            // that says what to do next.
            if paired != nil { dismiss() }
        }
    }

    // MARK: - Discovered

    @ViewBuilder
    private var discoveredSection: some View {
        Section(String(localized: "On this network")) {
            if model.discovered.isEmpty {
                // States that nothing has answered *yet* — not that there is
                // nothing there. Bonjour needs multicast, which a VPN and most
                // guest networks do not carry, so an empty list is as often
                // about the network as about the Macs on it; the manual field
                // below is the way through, and this says so.
                Text(String(localized: "Looking for Macs running Localis Bridge. If none appear, add the address below."))
                    .font(TypeScale.body)
                    .foregroundStyle(theme.neutrals.text2)
            } else {
                ForEach(model.discovered, id: \.identity) { host in
                    Button {
                        choose(host)
                    } label: {
                        row(host)
                    }
                    // Plain, so the row reads as content rather than as a link.
                    // The selected state is what tells the user which one they
                    // are pairing.
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ host: DiscoveredHost) -> some View {
        HStack(spacing: Space.gap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(host.displayName)
                    .font(TypeScale.title)
                    .foregroundStyle(theme.neutrals.text1)
                    .lineLimit(1)
                Text(host.endpoint.displayText)
                    .font(TypeScale.body)
                    .foregroundStyle(theme.neutrals.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected.map({ HostPairingModel.isSameMachine($0, as: host) }) == true {
                Image(systemName: "checkmark")
                    .foregroundStyle(theme.primary.primaryText)
            }
        }
    }

    // MARK: - Manual entry

    @ViewBuilder
    private var manualSection: some View {
        Section(String(localized: "Add by address")) {
            TextField(String(localized: "https://mac.local:8443"), text: $typedAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button(String(localized: "Add")) { addTypedAddress() }
                .disabled(typedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let addressError {
                Text(addressError)
                    .font(TypeScale.meta)
                    .foregroundStyle(theme.danger)
            }
        }
    }

    private func addTypedAddress() {
        do {
            let added = try model.addManualHost(address: typedAddress)
            addressError = nil
            typedAddress = ""
            // Selected straight away: the user typed exactly one machine, and
            // making them then find it in the list above is a step with no
            // decision in it.
            //
            // The model returns what it added rather than this reading
            // `discovered.last`. `addManualHost` merges, so a typed address that
            // matches a machine already listed *replaces* that row and appends
            // nothing — `.last` would then select whichever unrelated machine
            // happened to be at the end.
            selected = added
        } catch {
            // Never swallowed, and never rendered as "nothing happened" — an
            // address that was refused has to say so, or the row simply fails
            // to appear and reads as the button not working.
            addressError = (error as? LocalisError)?.userMessage
                ?? String(localized: "That address can't be used.")
        }
    }

    // MARK: - Pairing

    @ViewBuilder
    private func pairingSection(for host: DiscoveredHost) -> some View {
        Section {
            TextField(String(localized: "000000"), text: $code)
                .keyboardType(.numberPad)
                .font(TypeScale.num)
            TextField(String(localized: "Fingerprint from the Mac"), text: $fingerprint, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // Mono, because the value is compared by eye against what the
                // terminal printed, and a proportional face makes base64
                // characters that differ only in width look alike.
                .font(TypeScale.code)
                .lineLimit(2...4)

            Button {
                Task { await pair(with: host) }
            } label: {
                if model.pairingWith != nil {
                    // The exchange is one round trip to a machine that may be
                    // asleep. A button that stays idle-looking for ten seconds
                    // gets tapped again, and a second attempt spends one of the
                    // five that invalidate the code.
                    ProgressView()
                } else {
                    Text(String(localized: "Pair"))
                }
            }
            .disabled(model.pairingWith != nil)

            if let failure = model.failure {
                // The whole sentence, wrapped. These name an action — "check
                // the code on the Mac", "start pairing again on the Mac" — and
                // a truncated one names half of it.
                StatusPill(failure, tone: .danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(String(localized: "Pair with \(host.displayName)"))
        } footer: {
            // Says where both values come from. The fingerprint is only a trust
            // anchor because it arrived through the same out-of-band channel as
            // the code; a user who pastes it from somewhere else has pinned
            // whatever that source said.
            Text(String(localized: "Both values are printed on the Mac when Localis Bridge starts."))
        }
    }

    private func choose(_ host: DiscoveredHost) {
        selected = host
        // Cleared per machine. Carrying a code across would offer digits that
        // belong to a different Mac's pairing session, and the fingerprint is
        // per machine by definition.
        code = ""
        fingerprint = ""
    }

    private func pair(with host: DiscoveredHost) async {
        await model.pair(with: host, code: code, fingerprint: fingerprint)
    }
}
