//
//  NCShareExtension+Files.swift
//  Share
//
//  Created by Henrik Storch on 29.12.21.
//  Copyright © 2021 Henrik Storch. All rights reserved.
//
//  Author Henrik Storch <henrik.storch@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation

extension NCShareExtension {

    @objc func reloadDatasource(withLoadFolder: Bool) {

        layoutForView = NCUtility.shared.getLayoutForView(key: keyLayout, serverUrl: serverUrl)

        let metadatasSource = NCManageDatabase.shared.getMetadatas(predicate: NSPredicate(format: "account == %@ AND serverUrl == %@ AND directory == true", activeAccount.account, serverUrl))
        self.dataSource = NCDataSource(
            metadatasSource: metadatasSource,
            sort: layoutForView?.sort,
            ascending: layoutForView?.ascending,
            directoryOnTop: layoutForView?.directoryOnTop,
            favoriteOnTop: true,
            filterLivePhoto: true)

        if withLoadFolder {
            loadFolder()
        } else {
            self.refreshControl.endRefreshing()
        }

        collectionView.reloadData()
    }

    func createFolder(with fileName: String) {

        NCNetworking.shared.createFolder(fileName: fileName, serverUrl: serverUrl, account: activeAccount.account, urlBase: activeAccount.urlBase) { errorCode, errorDescription in

            DispatchQueue.main.async {
                if errorCode == 0 {

                    self.serverUrl += "/" + fileName
                    self.reloadDatasource(withLoadFolder: true)
                    self.setNavigationBar(navigationTitle: fileName)

                } else {
                    self.showAlert(title: "_error_createsubfolders_upload_", description: errorDescription)
                }
            }
        }
    }

    func loadFolder() {

        networkInProgress = true
        collectionView.reloadData()

        NCNetworking.shared.readFolder(serverUrl: serverUrl, account: activeAccount.account) { _, metadataFolder, _, _, _, _, errorCode, errorDescription in

            DispatchQueue.main.async {
                if errorCode != 0 {
                    self.showAlert(description: errorDescription)
                }
                self.networkInProgress = false
                self.metadataFolder = metadataFolder
                self.reloadDatasource(withLoadFolder: false)
            }
        }
    }
}

class NCFilesExtensionHandler {
    var itemsProvider: [NSItemProvider] = []
    lazy var filesName: [String] = []
    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss-"
        return formatter
    }()

    @discardableResult
    init(items: [NSExtensionItem], completion: @escaping ([String]) -> Void) {
        CCUtility.emptyTemporaryDirectory()
        var counter = 0

        self.itemsProvider = items.compactMap({ $0.attachments }).flatMap { $0.filter({
            $0.hasItemConformingToTypeIdentifier(kUTTypeItem as String) || $0.hasItemConformingToTypeIdentifier("public.url")
        }) }

        for (ix, provider) in itemsProvider.enumerated() {
            provider.loadItem(forTypeIdentifier: provider.typeIdentifier) { [self] item, error in
                defer {
                    counter += 1
                    if counter == itemsProvider.count { completion(self.filesName) }
                }
                guard error == nil else { return }
                var originalName = (dateFormatter.string(from: Date())) + String(ix)

                if let url = item as? URL, url.isFileURL, !url.lastPathComponent.isEmpty {
                    originalName = url.lastPathComponent
                }

                var fileName: String?
                switch item {
                case let image as UIImage:
                    fileName = getItem(image: image, fileName: originalName)
                case let url as URL:
                    fileName = getItem(url: url, fileName: originalName)
                case let data as Data:
                    fileName = getItem(data: data, fileName: originalName, provider: provider)
                case let text as String:
                    fileName = getItem(string: text, fileName: originalName)
                default: return
                }

                if let fileName = fileName, !filesName.contains(fileName) { filesName.append(fileName) }
            }
        }
    }

    // Image
    func getItem(image: UIImage, fileName: String) -> String? {
        var fileUrl = URL(fileURLWithPath: NSTemporaryDirectory() + fileName)
        if fileUrl.pathExtension.isEmpty { fileUrl.appendPathExtension("png") }
        guard let pngImageData = image.pngData(),
              (try? pngImageData.write(to: fileUrl, options: [.atomic])) != nil
        else { return nil }
        return fileUrl.lastPathComponent
    }

    // URL
    // Does not work for directories
    func getItem(url: URL, fileName: String) -> String? {
        var fileName = fileName
        guard url.isFileURL else {
            guard !filesName.contains(url.lastPathComponent) else { return nil }
            if !url.deletingPathExtension().lastPathComponent.isEmpty { fileName = url.deletingPathExtension().lastPathComponent }
            fileName += "." + (url.pathExtension.isEmpty ? "html" : url.pathExtension)
            let filenamePath = NSTemporaryDirectory() + fileName

            do {
                let downloadedContent = try Data(contentsOf: url)
                guard !FileManager.default.fileExists(atPath: filenamePath) else { return nil }
                try downloadedContent.write(to: URL(fileURLWithPath: filenamePath))
            } catch { print(error); return nil }
            return fileName
        }

        let filenamePath = NSTemporaryDirectory() + fileName

        try? FileManager.default.removeItem(atPath: filenamePath)

        do {
            try FileManager.default.copyItem(atPath: url.path, toPath: filenamePath)

            let attr = try FileManager.default.attributesOfItem(atPath: filenamePath)
            guard !attr.isEmpty else { return nil }
            return fileName
        } catch { return nil }
    }

    // Data
    func getItem(data: Data, fileName: String, provider: NSItemProvider) -> String? {
        guard !data.isEmpty else { return nil }
        var fileName = fileName

        if let url = URL(string: fileName), !url.pathExtension.isEmpty {
            fileName = url.lastPathComponent
        } else if let name = provider.suggestedName {
            fileName = name
        } else if let ext = provider.registeredTypeIdentifiers.last?.split(separator: ".").last {
            fileName += "." + ext
        } // else: no file information, use default name without ext

        // when sharing images in safari only data is retuned.
        // also, when sharing option "Automatic" is slected extension will return both raw data and a url, which will be downloaded, causing the image to appear twice with different names
        if let image = UIImage(data: data) {
            return getItem(image: image, fileName: fileName)
        }

        let filenamePath = NSTemporaryDirectory() + fileName
        FileManager.default.createFile(atPath: filenamePath, contents: data, attributes: nil)
        return fileName
    }

    // String
    func getItem(string: String, fileName: String) -> String? {
        guard !string.isEmpty else { return nil }
        let filenamePath = NSTemporaryDirectory() + fileName + ".txt"
        FileManager.default.createFile(atPath: filenamePath, contents: string.data(using: String.Encoding.utf8), attributes: nil)
        return fileName
    }
}

extension NSItemProvider {
    var typeIdentifier: String {
        if hasItemConformingToTypeIdentifier("public.url") { return "public.url" } else
        if hasItemConformingToTypeIdentifier(kUTTypeItem as String) { return kUTTypeItem as String } else { return "" }
    }
}
