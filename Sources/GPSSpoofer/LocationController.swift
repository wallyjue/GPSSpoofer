// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GPSSpoofer contributors

import CoreLocation
import MapKit
import SwiftUI

@MainActor
final class LocationController: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected, connecting, connected(version: String)
    }

    enum TapMode: Hashable {
        case teleport, addWaypoint
    }

    enum SidebarTab: Hashable, CaseIterable {
        case device, search, location, route, log
    }

    @Published var devices: [DeviceInfo] = []
    @Published var selectedUDID: String?
    @Published var state: ConnectionState = .disconnected
    @Published var isBusy = false

    /// 地圖上點選、尚未（或已經）送出的目標點
    @Published var target: CLLocationCoordinate2D?
    /// 目前已套用到 iPhone 的座標
    @Published var applied: CLLocationCoordinate2D?
    @Published var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: .init(latitude: 25.0339, longitude: 121.5645),
                           span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)))
    /// 地圖目前可見範圍，搜尋時以此為中心
    var visibleRegion: MKCoordinateRegion?

    @Published var sidebarTab: SidebarTab = .device
    @Published var tapMode: TapMode = .teleport
    @Published var latitudeText = ""
    @Published var longitudeText = ""
    @Published var sendOnTap = true
    @Published var useSatellite = false
    @Published var logs: [String] = []

    // 地點搜尋（見 LocationController+Search.swift）
    @Published var searchQuery = ""
    @Published var searchResults: [SearchResult] = []
    @Published var isSearching = false

    // 多點路線（見 LocationController+Route.swift）
    @Published var waypoints: [Waypoint] = []
    @Published var speedKmh: Double = 5
    @Published var routeEndBehavior: RouteEndBehavior = .stop
    @Published var followDevice = true
    @Published var routeState: RouteState = .idle
    @Published var routeLeg: (index: Int, count: Int)?
    @Published var routeTraveledMeters: Double = 0
    var routeTask: Task<Void, Never>?

    let bridge = HelperBridge()

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    init() {
        bridge.onLog = { [weak self] text in
            Task { @MainActor in self?.appendLog(text) }
        }
        bridge.onTerminate = { [weak self] in
            Task { @MainActor in
                self?.stopRoute()
                self?.state = .disconnected
                self?.applied = nil
                self?.appendLog(L("helper 已結束"))
            }
        }
        do {
            try bridge.start()
        } catch {
            appendLog(L("啟動 helper 失敗：\(error.localizedDescription)"))
        }
        Task { await refreshDevices() }
    }

    func shutdown() {
        bridge.stop()
    }

    // MARK: - 裝置

    func refreshDevices() async {
        await run(L("掃描裝置")) {
            let devices = try await bridge.listDevices()
            self.devices = devices
            if self.selectedUDID == nil || !devices.contains(where: { $0.udid == self.selectedUDID }) {
                self.selectedUDID = devices.first?.udid
            }
            self.appendLog(L("找到 \(devices.count) 台裝置"))
        }
    }

    func toggleConnection() async {
        if isConnected {
            stopRoute()
            await run(L("中斷連線")) {
                _ = try await bridge.request("disconnect")
                self.state = .disconnected
                self.applied = nil
            }
            return
        }
        guard let udid = selectedUDID else { return }
        state = .connecting
        await run(L("連線（首次需下載並掛載 Developer Disk Image，可能要數十秒）")) {
            do {
                let result = try await bridge.request("connect", ["udid": udid]) as? [String: Any]
                self.state = .connected(version: result?["version"] as? String ?? "?")
            } catch {
                self.state = .disconnected
                throw error
            }
        }
    }

    // MARK: - 定位

    func mapTapped(at coordinate: CLLocationCoordinate2D) {
        switch tapMode {
        case .addWaypoint:
            addWaypoint(coordinate)
        case .teleport:
            setTarget(coordinate)
            if sendOnTap && isConnected {
                Task { await sendTarget() }
            }
        }
    }

    func setTarget(_ coordinate: CLLocationCoordinate2D) {
        target = coordinate
        latitudeText = String(format: "%.6f", coordinate.latitude)
        longitudeText = String(format: "%.6f", coordinate.longitude)
    }

    /// 解析輸入框的經緯度，並把地圖視圖移過去
    func moveViewToInput() {
        guard let coordinate = parsedInput() else {
            appendLog(L("經緯度格式錯誤：緯度 -90~90、經度 -180~180"))
            return
        }
        target = coordinate
        focusMap(on: coordinate)
    }

    func focusMap(on coordinate: CLLocationCoordinate2D, span: Double = 0.01) {
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(center: coordinate,
                                                        span: .init(latitudeDelta: span, longitudeDelta: span)))
        }
    }

    func sendTarget() async {
        guard let coordinate = target else { return }
        stopRoute()
        let text = String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
        await run(L("設定定位 \(text)")) {
            try await self.sendLocation(coordinate)
        }
    }

    func sendLocation(_ coordinate: CLLocationCoordinate2D) async throws {
        _ = try await bridge.request("set", ["lat": coordinate.latitude, "lon": coordinate.longitude])
        applied = coordinate
    }

    func clearLocation() async {
        stopRoute()
        await run(L("還原真實定位")) {
            _ = try await bridge.request("clear")
            self.applied = nil
        }
    }

    // MARK: - 工具

    private func parsedInput() -> CLLocationCoordinate2D? {
        // 也接受把「25.03, 121.56」整串貼進緯度欄
        let parts = latitudeText.split(whereSeparator: { $0 == "," || $0 == " " })
        if parts.count == 2, longitudeText.isEmpty || latitudeText.contains(",") {
            latitudeText = String(parts[0])
            longitudeText = String(parts[1])
        }
        guard let lat = Double(latitudeText.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitudeText.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func run(_ title: String, _ body: () async throws -> Void) async {
        isBusy = true
        appendLog("\(title)…")
        do {
            try await body()
        } catch {
            appendLog(L("❌ \(title)失敗：\(error.localizedDescription)"))
        }
        isBusy = false
    }

    func appendLog(_ text: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        for line in text.split(separator: "\n") {
            logs.append("[\(time)] \(line)")
        }
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }
}
