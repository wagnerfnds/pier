import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The paper clip of a box that starts an agent: a photo from the library or a file (an image, a PDF, a log). They go
/// into the worktree before the agent starts, their paths under the prompt (`ComposeModel.submit`).
struct ComposeAttachButton<Label: View>: View {
    let compose: ComposeModel
    @ViewBuilder var label: () -> Label

    @State private var picksPhotos = false
    @State private var picksFiles = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button { picksPhotos = true } label: { SwiftUI.Label("Foto", systemImage: "photo.on.rectangle.angled") }
            Button { picksFiles = true } label: { SwiftUI.Label("Arquivo", systemImage: "doc") }
        } label: { label() }
        .plainMenu()
        .accessibilityLabel("Anexar")
        .accessibilityIdentifier("compose-attach")
        .photosPicker(isPresented: $picksPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
        .fileImporter(isPresented: $picksFiles, allowedContentTypes: ComposeDrop.types, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await compose.addFiles(urls) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await compose.addPhotos(items); photoItems = [] }
        }
    }
}

/// What was attached, in a row: a photo's thumbnail, a file's name; each with its ×.
struct ComposeAttachmentStrip: View {
    let compose: ComposeModel
    var size: CGFloat = 56

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(compose.photos) { p in
                    tile(p)
                        .overlay(alignment: .topTrailing) {
                            Button { compose.photos.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.65))
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                            .accessibilityLabel("Remover anexo")
                        }
                }
            }
        }
    }

    @ViewBuilder private func tile(_ p: ComposePhoto) -> some View {
        if let thumb = p.thumb {
            Image(uiImage: thumb).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            VStack(spacing: 4) {
                Image(systemName: p.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                    .font(.system(size: size * 0.3)).foregroundStyle(Theme.textDim)
                Text(verbatim: p.name).font(.system(size: 10)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .frame(width: size * 1.6, height: size)
            .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

enum ComposeDrop {
    /// What the picker offers and a drop takes: what the box accepts (`AttachmentCheck`), checked again by the bytes.
    static let types: [UTType] = [.image, .pdf, .plainText, .text, .sourceCode, .json, .commaSeparatedText, .log, .data]
}

extension View {
    /// Files and images dropped on the box are attached; the box's border shows the drop while it hovers.
    func composeDropTarget(_ compose: ComposeModel, isTargeted: Binding<Bool>, enabled: Bool = true) -> some View {
        onDrop(of: enabled ? [.fileURL, .image, .pdf, .plainText] : [], isTargeted: isTargeted) { providers in
            compose.addDropped(providers)
            return true
        }
    }
}
