import XCTest
@testable import Shared

final class BulkIndexDecodeTests: XCTestCase {
    // Trimmed copy of the live https://api.scryfall.com/bulk-data response (Nov 2026):
    // `download_uri`/`size` are gone, replaced by `jsonl_download_uri`/`compressed_size`.
    // The last entry has no URL at all to prove siblings don't break decoding.
    let json = """
    {"object":"list","has_more":false,"data":[
     {"object":"bulk_data","id":"27bf3214-1271-490b-bdfe-c0be6c23d02e","type":"oracle_cards",
      "updated_at":"2026-11-07T22:02:07.434+00:00","uri":"https://api.scryfall.com/bulk-data/27bf3214-1271-490b-bdfe-c0be6c23d02e",
      "name":"Oracle Cards","description":"x",
      "jsonl_download_uri":"https://data.scryfall.io/oracle-cards/oracle-cards-20261107220207.jsonl.gz","compressed_size":25360662},
     {"object":"bulk_data","id":"e2ef41e3-5778-4bc2-af3f-78eca4dd9c23","type":"default_cards",
      "updated_at":"2026-11-07T22:06:35.611+00:00","uri":"u","name":"Default Cards","description":"x",
      "jsonl_download_uri":"https://data.scryfall.io/default-cards/default-cards-20261107220635.jsonl.gz","compressed_size":80897764},
     {"object":"bulk_data","id":"z","type":"future_thing","updated_at":"2026-11-07T22:00:00.000+00:00","uri":"u","name":"n","description":"x"}
    ]}
    """

    func testDecodesCurrentIndexShape() throws {
        let infos = try ScryfallBulk.decodeIndex(Data(json.utf8))
        XCTAssertEqual(infos.count, 3)
        XCTAssertEqual(infos[0].jsonl_download_uri,
                       "https://data.scryfall.io/oracle-cards/oracle-cards-20261107220207.jsonl.gz")
        XCTAssertEqual(infos[0].compressed_size, 25360662)
        XCTAssertNil(infos[2].jsonl_download_uri)
    }
}
