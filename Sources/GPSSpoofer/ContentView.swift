// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GPSSpoofer contributors

import MapKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: LocationController

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 300, ideal: 330, max: 400)
        } detail: {
            mapView
        }
    }

    private var mapView: some View {
        MapReader { proxy in
            Map(position: $controller.cameraPosition) {
                if controller.waypoints.count > 1 {
                    MapPolyline(coordinates: controller.routePolyline)
                        .stroke(.blue.opacity(0.7), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 6]))
                }
                ForEach(Array(controller.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    Annotation(waypoint.name ?? "", coordinate: waypoint.coordinate) {
                        WaypointBadge(number: index + 1)
                    }
                }
                ForEach(controller.searchResults) { result in
                    Marker(result.name, systemImage: "magnifyingglass", coordinate: result.coordinate)
                        .tint(.orange)
                }
                if let target = controller.target, target != controller.applied {
                    Marker("目標", systemImage: "mappin", coordinate: target)
                        .tint(.red)
                }
                if let applied = controller.applied {
                    Annotation("iPhone 目前位置", coordinate: applied) {
                        Image(systemName: "iphone.gen3.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, .blue)
                            .shadow(radius: 3)
                    }
                }
            }
            .mapStyle(controller.useSatellite ? .hybrid : .standard)
            .mapControls {
                MapCompass()
                MapScaleView()
                MapZoomStepper()
                MapPitchToggle()
            }
            .onMapCameraChange { context in
                controller.visibleRegion = context.region
            }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    controller.mapTapped(at: coordinate)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 10) {
                Picker("", selection: $controller.useSatellite) {
                    Text("地圖").tag(false)
                    Text("衛星").tag(true)
                }
                .frame(width: 120)
                Picker("", selection: $controller.tapMode) {
                    Label("點擊傳送", systemImage: "location").tag(LocationController.TapMode.teleport)
                    Label("新增路線點", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .tag(LocationController.TapMode.addWaypoint)
                }
                .frame(width: 220)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
        }
    }
}

private struct WaypointBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.blue))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

// MARK: - 側邊欄

private struct Sidebar: View {
    @EnvironmentObject private var controller: LocationController

    var body: some View {
        Form {
            DeviceSection()
            SearchSection()

            Picker("", selection: $controller.sidebarTab) {
                Text("單點定位").tag(LocationController.SidebarTab.location)
                Text("多點路線").tag(LocationController.SidebarTab.route)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch controller.sidebarTab {
            case .location: LocationSection()
            case .route: RouteSection()
            }

            Section("記錄") {
                LogView(lines: controller.logs)
                    .frame(minHeight: 140)
            }
        }
        .formStyle(.grouped)
        .overlay(alignment: .bottom) {
            if controller.isBusy {
                ProgressView().controlSize(.small).padding(8)
            }
        }
    }
}

private struct DeviceSection: View {
    @EnvironmentObject private var controller: LocationController

    var body: some View {
        Section("裝置") {
            Picker("iPhone", selection: $controller.selectedUDID) {
                if controller.devices.isEmpty {
                    Text("未偵測到裝置").tag(String?.none)
                }
                ForEach(controller.devices) { device in
                    Text(device.displayName).tag(Optional(device.udid))
                }
            }
            .disabled(controller.isConnected)

            HStack {
                Button("重新整理") { Task { await controller.refreshDevices() } }
                    .disabled(controller.isConnected)
                Spacer()
                Button(controller.isConnected ? "中斷連線" : "連線") {
                    Task { await controller.toggleConnection() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.selectedUDID == nil || controller.state == .connecting)
            }
            statusLabel

            if let applied = controller.applied {
                LabeledContent("目前模擬",
                               value: String(format: "%.6f, %.6f", applied.latitude, applied.longitude))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.state {
        case .disconnected:
            Label("未連線", systemImage: "circle").foregroundStyle(.secondary)
        case .connecting:
            Label("連線中…", systemImage: "circle.dotted").foregroundStyle(.orange)
        case .connected(let version):
            Label("已連線（iOS \(version)）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

private struct SearchSection: View {
    @EnvironmentObject private var controller: LocationController

    var body: some View {
        Section("搜尋地點") {
            HStack {
                TextField("地點、地址或店名", text: $controller.searchQuery, prompt: Text("例如：台北車站"))
                    .labelsHidden()
                    .onSubmit { Task { await controller.search() } }
                if controller.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Button("搜尋") { Task { await controller.search() } }
                        .disabled(controller.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !controller.searchResults.isEmpty {
                ForEach(controller.searchResults.prefix(8)) { result in
                    SearchResultRow(result: result)
                }
                Button("清除搜尋結果", role: .destructive) { controller.clearSearch() }
                    .buttonStyle(.link)
            }
        }
    }
}

private struct SearchResultRow: View {
    @EnvironmentObject private var controller: LocationController
    let result: SearchResult

    var body: some View {
        HStack {
            Button {
                controller.selectSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name).lineLimit(1)
                    if !result.address.isEmpty {
                        Text(result.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("移動地圖到此地點並設為目標")

            Button {
                controller.addWaypoint(result.coordinate, name: result.name)
                controller.sidebarTab = .route
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("加入路線")
        }
    }
}

private struct LocationSection: View {
    @EnvironmentObject private var controller: LocationController

    var body: some View {
        Section("座標") {
            TextField("緯度", text: $controller.latitudeText, prompt: Text("25.033964"))
            TextField("經度", text: $controller.longitudeText, prompt: Text("121.564468"))
                .onSubmit { controller.moveViewToInput() }
            Button("移動地圖到此座標") { controller.moveViewToInput() }
            Toggle("點擊地圖後立即傳送", isOn: $controller.sendOnTap)
        }

        Section("iPhone 定位") {
            Button {
                Task { await controller.sendTarget() }
            } label: {
                Label("傳送目標座標到 iPhone", systemImage: "location.fill")
            }
            .disabled(!controller.isConnected || controller.target == nil)

            Button {
                if let target = controller.target { controller.addWaypoint(target) }
            } label: {
                Label("把目標加入路線", systemImage: "plus")
            }
            .disabled(controller.target == nil)

            Button(role: .destructive) {
                Task { await controller.clearLocation() }
            } label: {
                Label("還原真實定位", systemImage: "location.slash")
            }
            .disabled(!controller.isConnected)
        }
    }
}

private struct RouteSection: View {
    @EnvironmentObject private var controller: LocationController

    var body: some View {
        Section {
            if controller.waypoints.isEmpty {
                Text("切換到地圖上方的「新增路線點」後點擊地圖，或從搜尋結果按 ⊕ 加入。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(controller.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                WaypointRow(index: index, waypoint: waypoint)
            }
        } header: {
            HStack {
                Text("路線點（\(controller.waypoints.count)）")
                Spacer()
                if !controller.waypoints.isEmpty {
                    Button("全部清除", role: .destructive) { controller.clearWaypoints() }
                        .buttonStyle(.link)
                        .disabled(controller.routeState != .idle)
                }
            }
        } footer: {
            if controller.waypoints.count > 1 {
                Text("全程 \(controller.formatDistance(controller.routeDistanceMeters))，約需 \(controller.routeDurationText)")
            }
        }

        Section("移動速度") {
            HStack {
                Slider(value: $controller.speedKmh, in: 1...120, step: 1)
                TextField("", value: $controller.speedKmh, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Text("km/h").foregroundStyle(.secondary)
            }
            HStack {
                ForEach(SpeedPreset.all) { preset in
                    Button(preset.name) { controller.speedKmh = preset.kmh }
                        .buttonStyle(.bordered)
                        .tint(controller.speedKmh == preset.kmh ? .accentColor : nil)
                }
            }
            Picker("抵達終點後", selection: $controller.routeEndBehavior) {
                ForEach(RouteEndBehavior.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(controller.routeState != .idle)
            Toggle("地圖跟隨 iPhone 位置", isOn: $controller.followDevice)
        }

        Section("執行") {
            HStack {
                if controller.routeState == .running {
                    Button {
                        controller.pauseRoute()
                    } label: {
                        Label("暫停", systemImage: "pause.fill")
                    }
                } else {
                    Button {
                        controller.startRoute()
                    } label: {
                        Label(controller.routeState == .paused ? "繼續" : "開始移動", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.isConnected || controller.waypoints.count < 2)
                }
                Button(role: .destructive) {
                    controller.stopRoute()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(controller.routeState == .idle)
            }

            if let leg = controller.routeLeg {
                LabeledContent("進度", value: "第 \(leg.index)/\(leg.count) 段")
                LabeledContent("已移動", value: controller.formatDistance(controller.routeTraveledMeters))
            }
            if !controller.isConnected {
                Text("請先連線 iPhone").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct WaypointRow: View {
    @EnvironmentObject private var controller: LocationController
    let index: Int
    let waypoint: Waypoint

    var body: some View {
        HStack(spacing: 8) {
            WaypointBadge(number: index + 1)
            Button {
                controller.focusMap(on: waypoint.coordinate)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    if let name = waypoint.name {
                        Text(name).lineLimit(1)
                    }
                    Text(String(format: "%.5f, %.5f", waypoint.coordinate.latitude, waypoint.coordinate.longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Group {
                Button { controller.moveWaypoint(at: index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { controller.moveWaypoint(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == controller.waypoints.count - 1)
                Button { controller.removeWaypoint(waypoint.id) } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)
            .disabled(controller.routeState != .idle)
        }
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}
