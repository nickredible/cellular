//
//  TrustedNetworksListView.swift
//  Cellular
//
//  Created by Xuan Han on 19/8/23.
//

import SwiftUI

extension List {
    @ViewBuilder
    func borderedListStyle(if flag: Bool) -> some View {
        if flag {
            self.listStyle(BorderedListStyle())
        } else {
            self     // implicit DefaultListStyle
        }
    }
}

struct TrustedNetworksListView: View {
    @Binding var useTrustedNetworks: Bool
    @State var isSetup = false
    
    @State private var trustedNetworkSSIDs: [String] = []
    @State private var trustedNetworkPasswords: [String] = []
    @State private var selectedNetworkIndex: Int?
    @State private var isAdding = false
    @State private var savedNetworkSSIDs: [String] = []
    @State private var searchText = ""
    @State private var selectedSavedNetworkSSID: String?
    
    let defaults = UserDefaults.standard
    
    /// The saved networks that can be added: not already trusted, not the phone's hotspot, and matching the search
    private var addableNetworkSSIDs: [String] {
        savedNetworkSSIDs.filter { ssid in
            ssid != wlanModel.ssid && !trustedNetworkSSIDs.contains(ssid) && (searchText.isEmpty || ssid.localizedCaseInsensitiveContains(searchText))
        }
    }
    
    var body: some View {
        List(selection: $selectedNetworkIndex) {
            ForEach(Array(trustedNetworkSSIDs.enumerated()), id: \.offset) { index, network in
                Text(network)
                    .foregroundColor(useTrustedNetworks ? .none : .gray)
                    .tag(index)
            }
        }
        .borderedListStyle(if: isSetup)
        .frame(minHeight: 100)
        .overlay {
            if useTrustedNetworks && !isAdding && trustedNetworkSSIDs.isEmpty {
                Text("No trusted networks added.\nClick Add (+) to add a network.")
                    .multilineTextAlignment(.center)
            }
        }
        .disabled(!useTrustedNetworks)
        HStack(spacing: 10) {
            Button {
                if !isAdding {
                    selectedNetworkIndex = nil
                    isAdding = true
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 13, height: 13)
            }
            .sheet(isPresented: $isAdding, content: {
                VStack(spacing: 0) {
                    VStack(spacing: 5) {
                        Text("Add trusted network")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Choose a network your Mac has joined before, and it will join it with the settings it has saved. To add another network, join it once from the Wi-Fi menu first.")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TextField("Search", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .padding(.top, 15)
                        List(addableNetworkSSIDs, id: \.self, selection: $selectedSavedNetworkSSID) { network in
                            Text(network)
                        }
                        .listStyle(BorderedListStyle())
                        .frame(height: 200)
                        .overlay {
                            if addableNetworkSSIDs.isEmpty {
                                Text(savedNetworkSSIDs.isEmpty ? "Your Mac has no saved networks." : "No networks found.")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.top, 5)
                    }
                    .padding(.all, 20)
                    Divider()
                    HStack(spacing: 10) {
                        Spacer()
                        Button("Cancel") {
                            isAdding = false
                        }
                        .keyboardShortcut(.cancelAction)
                        Button("Add") {
                            selectedNetworkIndex = nil
                            isAdding = false
                            
                            if let selectedSavedNetworkSSID {
                                trustedNetworkSSIDs.append(selectedSavedNetworkSSID)
                                // An empty password means the network is joined with the settings macOS has saved
                                trustedNetworkPasswords.append("")
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedSavedNetworkSSID == nil)
                    }.padding(.all, 20)
                }
                .frame(width: 400, alignment: .leading)
                .onAppear {
                    savedNetworkSSIDs = wlanModel.savedNetworkSSIDs
                    searchText = ""
                    selectedSavedNetworkSSID = nil
                }
            })
            .buttonStyle(.borderless)
            Button {
                let prevSelectedNetworkIndex = selectedNetworkIndex!
                selectedNetworkIndex = nil
                isAdding = false
                if prevSelectedNetworkIndex != -1 {
                    trustedNetworkSSIDs.remove(at: prevSelectedNetworkIndex)
                    trustedNetworkPasswords.remove(at: prevSelectedNetworkIndex)
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.borderless)
            .disabled(selectedNetworkIndex == nil)
            .keyboardShortcut(KeyEquivalent.delete, modifiers: [])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!useTrustedNetworks)
        .onAppear {
            trustedNetworkSSIDs = defaults.stringArray(forKey: "trustedNetworks") ?? []
            let storedPasswords = SecretStore.trustedNetworkPasswords
            trustedNetworkPasswords = trustedNetworkSSIDs.map { storedPasswords[$0] ?? "" }
        }
        .onChange(of: trustedNetworkSSIDs) { _, newValue in
            defaults.set(trustedNetworkSSIDs, forKey: "trustedNetworks")
            SecretStore.trustedNetworkPasswords = Dictionary(zip(trustedNetworkSSIDs, trustedNetworkPasswords), uniquingKeysWith: { _, last in last })
        }
        .onChange(of: useTrustedNetworks) { _, newValue in
            if !newValue {
                selectedNetworkIndex = nil
                isAdding = false
            }
        }
    }
}
