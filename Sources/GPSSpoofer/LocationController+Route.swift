// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GPSSpoofer contributors

import CoreLocation
import MapKit

struct Waypoint: Identifiable {
    let id = UUID()
    var coordinate: CLLocationCoordinate2D
    var name: String?
}

enum RouteEndBehavior: String, CaseIterable, Identifiable {
    case stop = "停在終點"
    case loop = "回到起點循環"
    case pingPong = "來回往返"

    var id: Self { self }

    var title: String { L(String.LocalizationValue(rawValue)) }
}

enum RouteState: Equatable {
    case idle, running, paused
}

struct SpeedPreset: Identifiable {
    let name: String
    let kmh: Double
    var id: String { name }

    static var all: [SpeedPreset] { [
        SpeedPreset(name: L("步行"), kmh: 5),
        SpeedPreset(name: L("慢跑"), kmh: 10),
        SpeedPreset(name: L("單車"), kmh: 20),
        SpeedPreset(name: L("汽車"), kmh: 60),
    ] }
}

/// 每隔多久更新一次 iPhone 位置
private let routeTickSeconds = 1.0

extension LocationController {
    // MARK: - 速度

    /// 上次儲存的自訂速度，跨啟動保留
    var customSpeedKmh: Double {
        get { UserDefaults.standard.object(forKey: "customSpeedKmh") as? Double ?? 15 }
        set { UserDefaults.standard.set(newValue, forKey: "customSpeedKmh") }
    }

    func selectPreset(_ preset: SpeedPreset) {
        usesCustomSpeed = false
        speedKmh = preset.kmh
    }

    func selectCustomSpeed() {
        speedKmh = customSpeedKmh
        usesCustomSpeed = true
    }

    // MARK: - 編輯路線點

    func addWaypoint(_ coordinate: CLLocationCoordinate2D, name: String? = nil) {
        waypoints.append(Waypoint(coordinate: coordinate, name: name))
    }

    func removeWaypoint(_ id: Waypoint.ID) {
        waypoints.removeAll { $0.id == id }
    }

    func moveWaypoint(at index: Int, by offset: Int) {
        let destination = index + offset
        guard waypoints.indices.contains(index), waypoints.indices.contains(destination) else { return }
        waypoints.swapAt(index, destination)
    }

    func clearWaypoints() {
        stopRoute()
        waypoints.removeAll()
    }

    /// 地圖上要畫的線；循環模式會把終點接回起點
    var routePolyline: [CLLocationCoordinate2D] {
        var points = waypoints.map(\.coordinate)
        if routeEndBehavior == .loop {
            points.append(points[0])
        }
        return points
    }

    /// 走完一趟的總距離（公尺）
    var routeDistanceMeters: Double {
        let points = routePolyline
        return zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    // MARK: - 播放

    func startRoute() {
        guard isConnected, waypoints.count >= 2 else { return }
        if routeState == .paused {
            routeState = .running
            return
        }
        guard routeTask == nil else { return }
        routeState = .running
        routeTraveledMeters = 0
        appendLog(L("開始沿路線移動（\(waypoints.count) 個點，\(formatSpeed(speedKmh))）"))
        routeTask = Task { await runRoute() }
    }

    func pauseRoute() {
        if routeState == .running { routeState = .paused }
    }

    func stopRoute() {
        routeTask?.cancel()
        routeTask = nil
        routeState = .idle
        routeLeg = nil
    }

    private func runRoute() async {
        var points = waypoints.map(\.coordinate)
        do {
            repeat {
                var legs = points
                if routeEndBehavior == .loop {
                    legs.append(points[0])
                }
                try await travel(along: legs)
                if routeEndBehavior == .pingPong {
                    points.reverse()
                }
            } while routeEndBehavior != .stop
            appendLog(L("✅ 已抵達終點"))
        } catch is CancellationError {
            appendLog(L("路線已停止"))
            return  // stopRoute() 已重設狀態
        } catch {
            appendLog(L("❌ 路線中斷：\(error.localizedDescription)"))
        }
        guard !Task.isCancelled else { return }
        routeTask = nil
        routeState = .idle
        routeLeg = nil
    }

    private func travel(along points: [CLLocationCoordinate2D]) async throws {
        guard let start = points.first else { return }
        try await sendLocation(start)
        follow(start)

        let legCount = points.count - 1
        for (index, (from, to)) in zip(points, points.dropFirst()).enumerated() {
            routeLeg = (index + 1, legCount)
            let legLength = distance(from, to)
            var covered = 0.0
            while covered < legLength {
                try await Task.sleep(for: .seconds(routeTickSeconds))
                while routeState == .paused {
                    try await Task.sleep(for: .milliseconds(200))
                }
                // 每一步都重新讀取速度，移動途中調整會立即生效
                let step = min(speedKmh / 3.6 * routeTickSeconds, legLength - covered)
                covered += step
                routeTraveledMeters += step
                let position = interpolate(from, to, fraction: legLength > 0 ? covered / legLength : 1)
                try await sendLocation(position)
                follow(position)
            }
        }
    }

    private func follow(_ coordinate: CLLocationCoordinate2D) {
        guard followDevice else { return }
        let span = visibleRegion?.span ?? .init(latitudeDelta: 0.01, longitudeDelta: 0.01)
        cameraPosition = .region(MKCoordinateRegion(center: coordinate, span: span))
    }

    // MARK: - 工具

    func formatSpeed(_ kmh: Double) -> String {
        String(format: "%.1f km/h", kmh)
    }

    func formatDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f km", meters / 1000) : String(format: "%.0f m", meters)
    }

    /// 以目前速度走完一趟所需時間
    var routeDurationText: String {
        guard speedKmh > 0 else { return "—" }
        let seconds = Int(routeDistanceMeters / (speedKmh / 3.6))
        return seconds >= 3600
            ? L("\(seconds / 3600) 小時 \(seconds % 3600 / 60) 分")
            : L("\(seconds / 60) 分 \(seconds % 60) 秒")
    }
}

private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    CLLocation(latitude: a.latitude, longitude: a.longitude)
        .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
}

/// 路線點之間距離不長，直接對經緯度做線性內插即可
private func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                         fraction: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                           longitude: a.longitude + (b.longitude - a.longitude) * fraction)
}
