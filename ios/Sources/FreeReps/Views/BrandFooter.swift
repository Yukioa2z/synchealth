import SwiftUI

struct BrandFooter: View {
    var body: some View {
        Section {
            Text("SyncHealth · based on FreeReps")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            .listRowBackground(Color.clear)
        }
    }
}
