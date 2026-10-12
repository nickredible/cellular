//
//  DownloadAppView.swift
//  Cellular
//
//  Created by Xuan Han on 11/6/23.
//

import SwiftUI

struct DownloadAppView: View {
    @Binding var path: NavigationPath
    
    private static let companionDownloadURL = "https://github.com/nickredible/cellular-companion/releases/latest"
    
    /// A QR code of the companion's download page, for the user to scan with their phone
    private let qrCodeNSImage: NSImage? = {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(companionDownloadURL.utf8), forKey: "inputMessage")
        guard let ciImage = filter.outputImage else { return nil }
        let representation = NSCIImageRep(ciImage: ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10)))
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }()
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("Install the Cellular Companion app")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Spacer()
                if let qrCodeNSImage {
                    Image(nsImage: qrCodeNSImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .padding(.bottom, 20)
                }
                Text("The Cellular Companion app will help your Mac connect to your Android device and control its mobile hotspot settings. Scan the QR code above with your phone's camera to download the latest version from GitHub, or open this link on your phone. If you already have it, click Continue.")
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 10)
                Link("github.com/nickredible/cellular-companion/releases", destination: URL(string: Self.companionDownloadURL)!)
                    .font(.title3)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.all, 30)
            Divider()
            HStack {
                Spacer()
                Button("Back") {
                    path.removeLast()
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .padding(.trailing, 5)
                NavigationLink(value: "qrCodeView") {
                    Text("Continue")
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.all, 15)
        }
        .frame(width: 900, height: 650, alignment: .center)
    }
}

struct DownloadAppView_Previews: PreviewProvider {
    static var previews: some View {
        DownloadAppView(path: .constant(NavigationPath()))
    }
}
