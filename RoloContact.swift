import Foundation
import Contacts

// MARK: - Model (mirrors the card object RoloPro keeps in localStorage "rolodexchat.v1")

struct RoloContact: Identifiable, Hashable, Codable {
    var id: String
    var name = ""
    var company = ""
    var title = ""
    var phone = ""
    var wa = ""
    var email = ""
    var addr = ""
    var notes = ""
    var cat = "Other"

    private enum CodingKeys: String, CodingKey { case id, name, company, title, phone, wa, email, addr, notes, cat }

    init(id: String = UUID().uuidString, name: String = "") {
        self.id = id
        self.name = name
    }

    // Lenient on purpose: backups from older RoloPro versions may miss fields or store numbers as numbers.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else if let i = try? c.decode(Int.self, forKey: .id) { id = String(i) }
        else { id = UUID().uuidString }
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        name = s(.name); company = s(.company); title = s(.title)
        phone = s(.phone); wa = s(.wa); email = s(.email)
        addr = s(.addr); notes = s(.notes)
        let category = s(.cat); cat = category.isEmpty ? "Other" : category
    }
}

// MARK: - Same phone / vCard logic as the web app (waNum, vcard(c, fix, lite))

extension RoloContact {
    /// Port of waNum() in RoloPro. `cc` is the "Default country code" field (digits only, e.g. "34").
    static func waNum(_ raw: String, cc: String) -> String {
        let n = raw.trimmingCharacters(in: .whitespaces)
        var d = String(n.unicodeScalars.filter { ("0"..."9").contains($0) })
        if d.isEmpty { return "" }
        if n.hasPrefix("+") { return d }
        if d.hasPrefix("00") { return String(d.dropFirst(2)) }
        if !cc.isEmpty && !d.hasPrefix(cc) {
            d = String(d.drop(while: { $0 == "0" }))
            return cc + d
        }
        return d
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: ";", with: "\\;")
         .replacingOccurrences(of: ",", with: "\\,")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// The compact vCard 3.0 the web QR dialog encodes (no notes / categories, so the QR stays scannable).
    func vCardLite(defaultCC cc: String = "") -> String {
        func num(_ n: String) -> String {
            let d = Self.waNum(n, cc: cc)
            let intl = n.trimmingCharacters(in: .whitespaces).hasPrefix("+") || n.hasPrefix("00") || !cc.isEmpty
            return (!d.isEmpty && intl) ? "+" + d : n
        }
        var L = ["BEGIN:VCARD", "VERSION:3.0", "FN:" + Self.esc(name), "N:;" + Self.esc(name) + ";;;"]
        if !company.isEmpty { L.append("ORG:" + Self.esc(company)) }
        if !title.isEmpty { L.append("TITLE:" + Self.esc(title)) }
        if !phone.isEmpty { L.append("TEL;TYPE=CELL:" + num(phone)) }
        if !wa.isEmpty && wa != phone { L.append("TEL;TYPE=CELL:" + num(wa)) }
        email.split(whereSeparator: { ",; \n".contains($0) }).filter { $0.contains("@") }
            .forEach { L.append("EMAIL;TYPE=INTERNET:" + $0) }
        if !addr.isEmpty { L.append("ADR;TYPE=HOME:;;" + Self.esc(addr) + ";;;;") }
        L.append("END:VCARD")
        return L.joined(separator: "\r\n")
    }

    /// What the card prints on the "WhatsApp" row (same fallback as the web card: wa, else phone).
    var whatsappDisplay: String { wa.isEmpty ? phone : wa }
}

// MARK: - Importing real RoloPro data

enum RoloImporter {
    /// RoloPro > Backup > "Backup file (.json)"  ->  { app: "RoloPro", version: 1, cards: [...] }
    /// (a bare array of cards is accepted too)
    static func contacts(fromBackupJSON data: Data) throws -> [RoloContact] {
        struct Backup: Decodable { let cards: [RoloContact] }
        let dec = JSONDecoder()
        if let b = try? dec.decode(Backup.self, from: data) { return b.cards }
        return try dec.decode([RoloContact].self, from: data)
    }

    /// RoloPro > Backup > "Contacts (.vcf)", or any vCard file. Needs no Contacts permission (parsing only).
    static func contacts(fromVCF data: Data) throws -> [RoloContact] {
        try CNContactVCardSerialization.contacts(with: data).map { c in
            var r = RoloContact(name: CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName)
            r.company = c.organizationName
            r.title = c.jobTitle
            r.phone = c.phoneNumbers.first?.value.stringValue ?? ""
            r.email = (c.emailAddresses.first?.value as String?) ?? ""
            if let a = c.postalAddresses.first?.value {
                r.addr = CNPostalAddressFormatter.string(from: a, style: .mailingAddress)
                    .replacingOccurrences(of: "\n", with: ", ")
            }
            return r
        }
    }

    static func contacts(from url: URL) throws -> [RoloContact] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return url.pathExtension.lowercased() == "vcf"
            ? try contacts(fromVCF: data)
            : try contacts(fromBackupJSON: data)
    }
}

// MARK: - Tiny on-device store (Documents/rolopro-contacts.json)

enum RoloStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rolopro-contacts.json")
    }

    static func load() -> [RoloContact] {
        guard let d = try? Data(contentsOf: fileURL) else { return [] }
        return (try? RoloImporter.contacts(fromBackupJSON: d)) ?? []
    }

    /// Saved in the same { "cards": [...] } shape as RoloPro's own backup file.
    static func save(_ list: [RoloContact]) {
        if let d = try? JSONEncoder().encode(["cards": list]) { try? d.write(to: fileURL, options: .atomic) }
    }
}
