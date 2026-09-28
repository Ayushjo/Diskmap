import SwiftUI

/// Attaches a screen to its lazily built catalog (TASK-043): requests the
/// build when the screen appears and again whenever the catalogs go stale,
/// and shows a loading state until the catalog is ready — not a misleading
/// "nothing found".
struct CatalogGate: ViewModifier {
    @ObservedObject var model: ScanModel
    let catalog: ScanModel.Catalog
    let title: String

    func body(content: Content) -> some View {
        content
            .overlay {
                if model.tree != nil && !model.isCatalogReady(catalog) {
                    DiskMapLoadingState(title: title, detail: "Working from the scan you already ran — nothing is read from disk again.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DiskMapTheme.cream)
                        .accessibilityIdentifier("catalog-loading")
                }
            }
            .task(id: model.catalogGeneration) {
                await model.ensureCatalog(catalog)
            }
    }
}

extension View {
    func catalogGate(_ catalog: ScanModel.Catalog, model: ScanModel, title: String) -> some View {
        modifier(CatalogGate(model: model, catalog: catalog, title: title))
    }
}
