import HostsServices
import HostsSystem
import Testing

@Test func unverifiedIntegrationCannotReportSuccess() {
  #expect(SystemApplyStatus.availability == .unavailable)
  #expect(throws: SystemWriter.Failure.integrationUnavailable) {
    try SystemWriter.apply()
  }
}
