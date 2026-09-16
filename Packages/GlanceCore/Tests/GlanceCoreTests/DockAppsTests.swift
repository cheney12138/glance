import XCTest
@testable import GlanceCore

/// Dock 名单解析的钉子。结构事实来源见 `DockApps.parse` 的注释(本机实测 + dockutil 先例)。
final class DockAppsTests: XCTestCase {
    private func tile(bundleID: String? = nil, name: String? = nil,
                      url: String? = "file:///Applications/Safari.app/", type: String = "file-tile") -> [String: Any] {
        var item: [String: Any] = ["tile-type": type]
        var data: [String: Any] = [:]
        if let bundleID { data["bundle-identifier"] = bundleID }
        if let name { data["file-label"] = name }
        if let url { data["file-data"] = ["_CFURLString": url, "_CFURLStringType": 15] }
        item["tile-data"] = data
        return item
    }

    func testParsesValidAppTile() {
        let apps = DockApps.parse(persistentApps: [
            tile(bundleID: "com.apple.Safari", name: "Safari"),
        ])
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].bundleID, "com.apple.Safari")
        XCTAssertEqual(apps[0].name, "Safari")
        XCTAssertEqual(apps[0].path, "/Applications/Safari.app")
    }

    func testKeepsDockOrderAndSkipsNonAppTiles() {
        // 文件夹/书签/形态不明的格一律跳过,顺序保持用户钉住的顺序
        let apps = DockApps.parse(persistentApps: [
            tile(bundleID: "b.first", type: "directory-tile"),
            tile(bundleID: "b.two"),
            tile(bundleID: "b.three", type: "url-tile"),
            ["GUID": "malformed"],
            tile(bundleID: "b.four"),
        ])
        XCTAssertEqual(apps.map(\.bundleID), ["b.two", "b.four"])
    }

    func testDecodesPercentEncodedPath() {
        let apps = DockApps.parse(persistentApps: [
            tile(bundleID: "x.y", url: "file:///Applications/My%20App.app/"),
        ])
        XCTAssertEqual(apps[0].path, "/Applications/My App.app")
    }

    func testAcceptsBarePathFallback() {
        // _CFURLStringType != 15 的老数据可能存裸路径
        let apps = DockApps.parse(persistentApps: [
            tile(bundleID: "x.y", url: "/Applications/Plain.app"),
        ])
        XCTAssertEqual(apps[0].path, "/Applications/Plain.app")
    }

    func testSkipsNonAppFileTiles() {
        let apps = DockApps.parse(persistentApps: [
            tile(bundleID: "x.y", url: "file:///Users/x/notes.txt"),
        ])
        XCTAssertTrue(apps.isEmpty)
    }

    func testMissingFileDataIsSkipped() {
        let apps = DockApps.parse(persistentApps: [
            ["tile-type": "file-tile", "tile-data": ["bundle-identifier": "x.y"]],
        ])
        XCTAssertTrue(apps.isEmpty)
    }

    func testNonArrayInputFailsClosed() {
        XCTAssertTrue(DockApps.parse(persistentApps: nil).isEmpty)
        XCTAssertTrue(DockApps.parse(persistentApps: "garbage").isEmpty)
        XCTAssertTrue(DockApps.parse(persistentApps: ["not", "dicts"]).isEmpty)
    }

    func testMissingOptionalFieldsStayNil() {
        let apps = DockApps.parse(persistentApps: [tile()])
        XCTAssertEqual(apps.count, 1)
        XCTAssertNil(apps[0].bundleID)
        XCTAssertNil(apps[0].name)
        XCTAssertEqual(apps[0].path, "/Applications/Safari.app")
    }
}
