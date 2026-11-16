import UIKit
import Photos
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Preview sheet shown right after the shutter

final class PhotoPreviewViewController: UIViewController {
    private let image: UIImage
    private let promo = "RoloPro easylandx.github.io/rolopro"       // same line the web app appends to WhatsApp shares
    private let toast = UILabel()

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: 0xFBF0C4)

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.layer.cornerRadius = 12
        iv.layer.masksToBounds = true

        let save = button("Save to Photos", "square.and.arrow.down", #selector(saveToPhotos), primary: true)
        let share = button("Share", "square.and.arrow.up", #selector(shareTapped), primary: false)
        let retake = button("Retake", "arrow.uturn.backward", #selector(retake), primary: false)
        let row = UIStackView(arrangedSubviews: [save, share])
        row.spacing = 10; row.distribution = .fillEqually

        toast.textAlignment = .center
        toast.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        toast.textColor = UIColor(hex: 0x2B2418)

        let col = UIStackView(arrangedSubviews: [iv, toast, row, retake])
        col.axis = .vertical; col.spacing = 12
        col.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(col)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),       // comfortable side margins
            col.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            col.topAnchor.constraint(equalTo: g.topAnchor, constant: 20),
            col.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
        ])
    }

    private func button(_ title: String, _ symbol: String, _ action: Selector, primary: Bool) -> UIButton {
        var c = UIButton.Configuration.filled()
        c.title = title
        c.image = UIImage(systemName: symbol)
        c.imagePadding = 6
        c.cornerStyle = .large
        c.baseBackgroundColor = primary ? CardSpec.gold : CardSpec.buttonFill
        c.baseForegroundColor = CardSpec.ink
        c.background.strokeColor = CardSpec.goldEdge
        c.background.strokeWidth = 2
        let b = UIButton(configuration: c)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    // Needs NSPhotoLibraryAddUsageDescription in Info.plist (add-only access: no full library permission).
    @objc private func saveToPhotos() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.toast.text = "Allow Photos access in Settings to save" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: self.image)
            }) { ok, _ in
                DispatchQueue.main.async {
                    self.toast.text = ok ? "Saved to Photos" : "Could not save the photo"
                    if ok { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                }
            }
        }
    }

    /// The system share sheet lists WhatsApp, Messages, Instagram, Mail, AirDrop... for whatever is installed.
    @objc private func shareTapped(_ sender: UIButton) {
        let vc = UIActivityViewController(activityItems: [image, promo], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = sender
        present(vc, animated: true)
    }

    @objc private func retake() { dismiss(animated: true) }
}

// MARK: - SwiftUI entry point

struct ARDeskView: UIViewControllerRepresentable {
    let contacts: [RoloContact]
    var defaultCountryCode = ""
    var onLaterChanged: (([String]) -> Void)?

    func makeUIViewController(context: Context) -> ARDeskViewController {
        let vc = ARDeskViewController(contacts: contacts)
        vc.defaultCC = defaultCountryCode
        vc.onLaterChanged = onLaterChanged
        return vc
    }
    func updateUIViewController(_ vc: ARDeskViewController, context: Context) {}
}

/// Minimal host screen: import a RoloPro backup (.json) or vCard (.vcf), then open the AR desk.
struct RoloHomeView: View {
    @State private var contacts = RoloStore.load()
    @State private var importing = false
    @State private var showDesk = false
    @State private var message = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("RoloPro").font(.custom("SpecialElite-Regular", size: 34)).foregroundColor(Color(UIColor(hex: 0x1D5FD1)))
            Text("\(contacts.count) cards").font(.footnote)
            Button("Import RoloPro backup (.json / .vcf)") { importing = true }
            Button("Open AR Desk") { showDesk = true }.disabled(contacts.isEmpty).buttonStyle(.borderedProminent).tint(Color(UIColor(hex: 0xF0B823)))
            if !message.isEmpty { Text(message).font(.footnote) }
        }
        .padding(24)                                           // side margins
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor(hex: 0xFBF0C4)).ignoresSafeArea())
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, UTType(filenameExtension: "vcf") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            do {
                let list = try RoloImporter.contacts(from: url)
                contacts = list
                RoloStore.save(list)
                message = "Imported \(list.count) cards"
            } catch { message = "Could not read that file" }
        }
        .fullScreenCover(isPresented: $showDesk) {
            ARDeskView(contacts: contacts, defaultCountryCode: UserDefaults.standard.string(forKey: "rc.cc") ?? "")
                .ignoresSafeArea()
        }
    }
}

@main
struct RoloProARApp: App {
    var body: some Scene { WindowGroup { RoloHomeView() } }
}
