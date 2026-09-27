import SwiftUI
import EC20BridgeProtocol

@MainActor
public struct MobileContactsView: View {
    @ObservedObject var appState = MobileAppState.shared
    @ObservedObject var client = MobileGatewayClient.shared

    @State private var searchText: String = ""

    public init() {}

    private var filteredContacts: [BridgeContactDTO] {
        if searchText.isEmpty {
            return appState.contacts
        }
        return appState.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.phoneNumber.contains(searchText)
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(filteredContacts) { contact in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.15))
                                .frame(width: 40, height: 40)
                            Text(String(contact.name.first ?? "?"))
                                .font(.headline)
                                .foregroundColor(.orange)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(contact.name)
                                .font(.headline)

                            HStack(spacing: 6) {
                                Text(contact.phoneNumber)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                if let attr = contact.attribution, !attr.isEmpty, attr != "未知" {
                                    Text("• \(attr)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if !contact.notes.isEmpty {
                                Text(contact.notes)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Button(action: {
                            client.dial(number: contact.phoneNumber)
                        }) {
                            Image(systemName: "phone.circle.fill")
                                .font(.title2)
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            .searchable(text: $searchText, prompt: "搜索联系人姓名或号码")
            .listStyle(.plain)
            .navigationTitle("通讯录")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        client.requestSync()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}
