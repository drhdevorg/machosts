import HostsCore
import HostsServices
import SwiftUI

/// Creates an inactive remote profile and starts its first download. The download only
/// fills the local draft; enabling and applying stay separate, explicit steps.
struct AddRemoteProfileView: View {
  let editor: ProfileWorkspaceModel
  let remote: RemoteRefreshModel
  let created: (UUID) -> Void
  let cancel: () -> Void
  @State private var name = ""
  @State private var url = "https://"

  private var urlIsValid: Bool { (try? RemoteSource.validatedURL(url)) != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New remote profile").font(.headline)
      TextField("Profile name", text: $name)
        .accessibilityIdentifier("remoteProfileName")
      TextField("HTTPS address", text: $url)
        .accessibilityIdentifier("remoteProfileURL")
        .onSubmit(add)
      if !url.isEmpty && url != "https://" && !urlIsValid {
        Text("Enter an HTTPS address without user name or password.")
          .foregroundStyle(.red)
      }
      Text(
        "Remote content is downloaded into a read-only profile. It is not enabled and never changes the system file without a preview and authorization."
      )
      .font(.caption)
      HStack {
        Spacer()
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        Button("Add and download", action: add)
          .keyboardShortcut(.defaultAction)
          .disabled(!urlIsValid || !Workspace.validName(name))
      }
    }
    .padding(20)
    .frame(width: 480)
  }

  private func add() {
    guard urlIsValid, let id = editor.addRemote(name: name, url: url) else { return }
    remote.refresh(id, editor: editor)
    created(id)
  }
}

/// Origin, refresh state and URL editing for one remote profile.
struct RemoteSourceSection: View {
  let editor: ProfileWorkspaceModel
  let remote: RemoteRefreshModel
  let profile: Profile
  let source: RemoteSource
  @State private var url = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField("HTTPS address", text: $url)
          .onSubmit(changeURL)
          .accessibilityIdentifier("remoteSourceURL")
        Button("Change address", action: changeURL)
          .disabled(url == source.url.absoluteString || editor.isReadOnly)
        Button {
          remote.refresh(profile.id, editor: editor)
        } label: {
          if remote.inFlight.contains(profile.id) {
            ProgressView().controlSize(.small)
          } else {
            Text("Refresh")
          }
        }
        .disabled(editor.isReadOnly || remote.inFlight.contains(profile.id))
        .accessibilityIdentifier("refreshRemoteProfile")
      }
      statusText
        .font(.caption)
        .accessibilityIdentifier("remoteRefreshStatus")
      Text(
        "Remote content is read-only. Duplicate it as a local profile to edit lines. Changing the address discards the cached content."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .onAppear { url = source.url.absoluteString }
    .onChange(of: source.url) { _, value in url = value.absoluteString }
  }

  private func changeURL() {
    guard url != source.url.absoluteString else { return }
    editor.setRemoteURL(profile.id, url: url)
    if editor.remoteTicket(profile.id)?.request.url.absoluteString != source.url.absoluteString {
      remote.refresh(profile.id, editor: editor)
    }
  }

  @ViewBuilder
  private var statusText: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let date = source.lastRefresh {
        Text("Last successful refresh: \(date.formatted(date: .abbreviated, time: .shortened))")
      } else {
        Text("Not downloaded yet.")
      }
      if let failure = source.lastFailure {
        Text(
          "Last refresh failed: \(remoteFailureText(failure)) The previous valid content was kept."
        )
        .foregroundStyle(.orange)
      }
      switch remote.lastRecords[profile.id] {
      case .updated?: Text("New content was saved as a draft. It is not applied to the system.")
      case .stale?: Text("The profile changed during the download. Refresh again.")
      case .rejected?:
        Text("The download could not be stored. The previous content was kept.")
          .foregroundStyle(.orange)
      default: EmptyView()
      }
    }
  }
}

func remoteFailureText(_ failure: RemoteFetchFailure) -> String {
  switch failure {
  case .offline: String(localized: "The server could not be reached.")
  case .timeout: String(localized: "The request timed out.")
  case .tls: String(localized: "The secure connection could not be verified.")
  case .httpStatus: String(localized: "The server returned an error status.")
  case .tooLarge: String(localized: "The download exceeds the 1 MiB profile limit.")
  case .unsupportedEncoding: String(localized: "The download is not UTF-8 text.")
  case .notHostsContent: String(localized: "The download does not look like a hosts file.")
  case .redirectRejected: String(localized: "A redirect to a non-HTTPS address was refused.")
  case .tooManyRedirects: String(localized: "The server redirected more than three times.")
  case .cancelled: String(localized: "The download was cancelled.")
  case .failed: String(localized: "The download failed.")
  }
}
