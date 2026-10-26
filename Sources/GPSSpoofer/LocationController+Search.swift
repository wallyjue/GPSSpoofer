// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GPSSpoofer contributors

import CoreLocation
import MapKit

struct SearchResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
}

extension LocationController {
    /// 以目前地圖範圍為中心搜尋地點（Apple 地圖 POI 與地址）
    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region = visibleRegion {
            request.region = region
        }

        isSearching = true
        defer { isSearching = false }
        do {
            let response = try await MKLocalSearch(request: request).start()
            searchResults = response.mapItems.map { item in
                SearchResult(name: item.name ?? query,
                             address: item.placemark.title ?? "",
                             coordinate: item.placemark.coordinate)
            }
            if let first = searchResults.first {
                selectSearchResult(first)
            }
        } catch {
            searchResults = []
            appendLog(L("❌ 搜尋「\(query)」失敗：\(error.localizedDescription)"))
        }
    }

    func selectSearchResult(_ result: SearchResult) {
        setTarget(result.coordinate)
        focusMap(on: result.coordinate)
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
    }
}
