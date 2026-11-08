import XCTest
import EngineBindings
import Foundation
import SQLite3
@testable import Shared

/// Temporary Stage 3 parity harness (deleted with the GRDB code): dumps what the store returns for
/// a fixed sample into JSON so the GRDB run and the Rust run can be diffed.
final class ParityDumpTests: XCTestCase {
    func testDump() throws {
        guard let out = ProcessInfo.processInfo.environment["QS_PARITY_OUT"],
              let dbPath = ProcessInfo.processInfo.environment["QS_PARITY_DB"] else { throw XCTSkip("QS_PARITY_OUT unset") }
        let store = try CardStore(url: URL(fileURLWithPath: dbPath))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        func ids(_ sql: String) -> [String] {
            var st: OpaquePointer?; sqlite3_prepare_v2(db, sql, -1, &st, nil); defer { sqlite3_finalize(st) }
            var r: [String] = []
            while sqlite3_step(st) == SQLITE_ROW { r.append(String(cString: sqlite3_column_text(st, 0))) }
            return r
        }
        var sample = ids("SELECT id FROM cards WHERE name IN ('Plains','Island','Swamp','Mountain','Forest','Lightning Bolt','Sol Ring','Delver of Secrets // Insectile Aberration','Æther Vial','Lim-Dûl''s Vault','Jötun Grunt','Fire // Ice') OR name LIKE '%//%' AND name LIKE 'Ju%' OR name LIKE 'Æ%' OR name LIKE '%û%' OR name LIKE '%ö%' ORDER BY id")
        let all = ids("SELECT id FROM cards ORDER BY id")
        sample += stride(from: 0, to: all.count, by: max(1, all.count / 300)).map { all[$0] }
        sample += ["no-such-id"]
        var cards: [[String: Any]] = []
        for id in sample {
            guard let c = try store.card(id: id) else { cards.append(["id": id, "missing": true]); continue }
            let ps = try c.oracleID.map { try store.printings(forOracleID: $0) } ?? []
            cards.append([
                "id": c.id, "name": c.name, "manaCost": c.manaCost ?? NSNull(), "typeLine": c.typeLine ?? NSNull(),
                "oracleText": c.oracleText ?? NSNull(), "power": c.power ?? NSNull(), "toughness": c.toughness ?? NSNull(),
                "colors": c.colors, "imagePath": c.imagePath ?? NSNull(), "scryfallURI": c.scryfallURI,
                "oracleID": c.oracleID ?? NSNull(), "rarity": c.rarity ?? NSNull(), "cmc": c.cmc ?? NSNull(),
                "printings": ps.map { p in [
                    "printingID": p.printingID, "oracleID": p.oracleID ?? NSNull(), "setCode": p.setCode, "setName": p.setName,
                    "collectorNumber": p.collectorNumber ?? NSNull(), "releasedAt": p.releasedAt ?? NSNull(),
                    "rarity": p.rarity ?? NSNull(), "digital": p.digital, "games": p.games] as [String: Any] },
            ])
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone(identifier: "UTC"); df.locale = Locale(identifier: "en_US_POSIX")
        let recent = try store.recentlyAdded().map { r in
            ["id": r.id, "name": r.name, "identity": r.identity.rawValue, "setCode": r.setCode ?? NSNull(),
             "setName": r.setName ?? NSNull(), "firstSeen": df.string(from: r.firstSeen)] as [String: Any] }
        let arts = try store.loadArtworks().sorted { $0.illustrationID < $1.illustrationID }.map { a in
            ["i": a.illustrationID, "c": a.cardID, "n": a.cardName, "a": a.artist, "u": a.artCropURL,
             "col": a.colors, "s": a.setCode ?? NSNull()] as [String: Any] }
        let lists = try store.loadLists()
        let listDump = try lists.map { l in
            ["id": l.id, "name": l.name, "createdAt": l.createdAt, "updatedAt": l.updatedAt, "itemCount": l.itemCount,
             "items": try store.listItems(listID: l.id).map { m in
                ["id": m.id, "name": m.name, "identity": m.identity.rawValue, "setCodeLower": m.setCodeLower ?? NSNull(),
                 "setNameLower": m.setNameLower ?? NSNull(), "rarity": m.rarity ?? NSNull()] as [String: Any] }] as [String: Any] }
        let top: [String: Any] = [
            "count": try store.count(), "artworkCount": try store.artworkCount(),
            "meta": ["last_refresh", "bulk_updated_at", "artwork_updated_at", "nope"].map { (try? store.meta($0)).flatMap { $0 } ?? "<nil>" },
            "cards": cards, "recent": recent, "artworks": arts, "lists": listDump,
        ]
        let data = try JSONSerialization.data(withJSONObject: top, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: out))
    }

    func testDumpRust() throws {
        guard let out = ProcessInfo.processInfo.environment["QS_PARITY_OUT"],
              let dbPath = ProcessInfo.processInfo.environment["QS_PARITY_DB"] else { throw XCTSkip("QS_PARITY_OUT unset") }
        let store = try Database.open(dbPath: dbPath)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        func ids(_ sql: String) -> [String] {
            var st: OpaquePointer?; sqlite3_prepare_v2(db, sql, -1, &st, nil); defer { sqlite3_finalize(st) }
            var r: [String] = []
            while sqlite3_step(st) == SQLITE_ROW { r.append(String(cString: sqlite3_column_text(st, 0))) }
            return r
        }
        var sample = ids("SELECT id FROM cards WHERE name IN ('Plains','Island','Swamp','Mountain','Forest','Lightning Bolt','Sol Ring','Delver of Secrets // Insectile Aberration','Æther Vial','Lim-Dûl''s Vault','Jötun Grunt','Fire // Ice') OR name LIKE '%//%' AND name LIKE 'Ju%' OR name LIKE 'Æ%' OR name LIKE '%û%' OR name LIKE '%ö%' ORDER BY id")
        let all = ids("SELECT id FROM cards ORDER BY id")
        sample += stride(from: 0, to: all.count, by: max(1, all.count / 300)).map { all[$0] }
        sample += ["no-such-id"]
        func n(_ v: String?) -> Any { v ?? NSNull() }
        var cards: [[String: Any]] = []
        for id in sample {
            guard let c = try store.card(id: id) else { cards.append(["id": id, "missing": true]); continue }
            let ps = try c.oracleId.map { try store.printings(oracleId: $0) } ?? []
            cards.append([
                "id": c.id, "name": c.name, "manaCost": n(c.manaCost), "typeLine": n(c.typeLine),
                "oracleText": n(c.oracleText), "power": n(c.power), "toughness": n(c.toughness),
                "colors": c.colors, "imagePath": n(c.imagePath), "scryfallURI": c.scryfallUri,
                "oracleID": n(c.oracleId), "rarity": n(c.rarity), "cmc": c.cmc as Any? ?? NSNull(),
                "printings": ps.map { p in [
                    "printingID": p.printingId, "oracleID": n(p.oracleId), "setCode": p.setCode, "setName": p.setName,
                    "collectorNumber": n(p.collectorNumber), "releasedAt": n(p.releasedAt),
                    "rarity": n(p.rarity), "digital": p.digital, "games": p.games] as [String: Any] },
            ])
        }
        func ident(_ colors: [String]) -> String { ColorIdentity(colors: colors).rawValue }
        let recent = try store.recentlyAdded(lookbackDays: 30, limit: 200).map { r in
            ["id": r.id, "name": r.name, "identity": ident(r.colors), "setCode": n(r.setCode),
             "setName": n(r.setName), "firstSeen": r.firstSeen] as [String: Any] }
        let arts = try store.artworks().sorted { $0.illustrationId < $1.illustrationId }.map { a in
            ["i": a.illustrationId, "c": a.cardId, "n": a.cardName, "a": a.artist, "u": a.artCropUrl,
             "col": a.colors, "s": n(a.setCode)] as [String: Any] }
        let listDump = try store.loadLists().map { l in
            ["id": l.id, "name": l.name, "createdAt": l.createdAt, "updatedAt": l.updatedAt, "itemCount": Int(l.itemCount),
             "items": try store.listItems(listId: l.id).map { m in
                ["id": m.id, "name": m.name, "identity": ident(m.colors), "setCodeLower": n(m.setCode?.lowercased()),
                 "setNameLower": n(m.setName?.lowercased()), "rarity": n(m.rarity)] as [String: Any] }] as [String: Any] }
        let top: [String: Any] = [
            "count": Int(try store.cardCount()), "artworkCount": Int(try store.artworkCount()),
            "meta": ["last_refresh", "bulk_updated_at", "artwork_updated_at", "nope"].map { (try? store.meta(key: $0)).flatMap { $0 } ?? "<nil>" },
            "cards": cards, "recent": recent, "artworks": arts, "lists": listDump,
        ]
        let data = try JSONSerialization.data(withJSONObject: top, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: out))
    }
}
