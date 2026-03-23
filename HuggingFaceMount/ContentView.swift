//
//  ContentView.swift
//  HuggingFaceMount
//
//  Created by Mattt Zmuda on 3/23/26.
//

import SwiftUI

struct ContentView: View {
    @State private var auth = HuggingFaceAuth()

    var body: some View {
        @Bindable var auth = auth
        VStack(alignment: .leading, spacing: 12) {
            Text("Hugging Face Token")
                .font(.title3)
                .bold()

            Text("OAuth Client ID: \(auth.clientID)")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox("OAuth Flow") {
                HStack {
                    Button("Sign In with Hugging Face") {
                        auth.startOAuthSignIn()
                    }
                    .disabled(auth.isAuthenticating)

                    if auth.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            GroupBox("Manual Token") {
                SecureField("HF Token (hf_...)", text: $auth.manualToken)
                    .textFieldStyle(.roundedBorder)
            }

            GroupBox("Mount Volume") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Repo path (e.g. gpt2 or datasets/user/repo)", text: $auth.repoPath)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        TextField("Revision", text: $auth.revision)
                            .textFieldStyle(.roundedBorder)
                        TextField("Mount point", text: $auth.mountPoint)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button("Mount") {
                            auth.mountVolume()
                        }
                        Button("Unmount") {
                            auth.unmountVolume()
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Save Token") {
                    auth.saveManualToken()
                }

                Button("Check Token") {
                    auth.refreshStatus()
                }

                Button("Clear Token") {
                    auth.clearToken()
                }
            }

            Text(auth.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 220)
        .task {
            auth.refreshStatus()
        }
    }
}

#Preview {
    ContentView()
}
