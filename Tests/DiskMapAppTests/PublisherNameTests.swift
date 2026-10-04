import Testing
@testable import DiskMapApp

/// Applications shows a bundle's copyright line as its publisher; strip the
/// year and the boilerplate so the row reads "Docker Inc.".
@Suite("Publisher names")
struct PublisherNameTests {
    @Test func copyrightBoilerplateIsRemoved() {
        #expect(AppsView.publisherName("© 2026 Docker Inc. All Rights Reserved") == "Docker Inc.")
        #expect(AppsView.publisherName("Copyright © 2008–2024 Apple Inc. All rights reserved.") == "Apple Inc.")
        #expect(AppsView.publisherName("Google LLC. All rights reserved") == "Google LLC")
        #expect(AppsView.publisherName("CodeWeavers, Inc") == "CodeWeavers, Inc")
        #expect(AppsView.publisherName("2025 Anthropic PBC") == "Anthropic PBC")
        #expect(AppsView.publisherName("   ") == nil)
        #expect(AppsView.publisherName(nil) == nil)
    }
}
