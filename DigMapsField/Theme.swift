//
//  Theme.swift
//  DigRallies "Workshop" theme — same palette as DigMaps web (build 9+):
//  charcoal band, gold brass accents, cream ink, detector-coil brand mark.
//

import SwiftUI

enum Workshop {
    static let bg        = Color(red: 0x14/255, green: 0x11/255, blue: 0x0d/255) // #14110d
    static let band      = Color(red: 0x1c/255, green: 0x18/255, blue: 0x14/255) // #1c1814
    static let panel     = Color(red: 0x2a/255, green: 0x24/255, blue: 0x1c/255) // #2a241c
    static let gold      = Color(red: 0xb8/255, green: 0x86/255, blue: 0x2c/255) // #b8862c
    static let goldBright = Color(red: 0xd4/255, green: 0xa2/255, blue: 0x48/255) // #d4a248
    static let glow      = Color(red: 0xf0/255, green: 0xc0/255, blue: 0x62/255) // #f0c062
    static let copper    = Color(red: 0xc6/255, green: 0x6a/255, blue: 0x2a/255) // #c66a2a
    static let cream     = Color(red: 0xed/255, green: 0xe4/255, blue: 0xd0/255) // #ede4d0
    static let creamDim  = Color(red: 0xc9/255, green: 0xbf/255, blue: 0xa4/255) // #c9bfa4
    static let green     = Color(red: 0x6f/255, green: 0xc8/255, blue: 0x50/255) // #6fc850

    static func wordmark(_ size: CGFloat) -> Font { .custom("Archivo-ExtraBold", size: size) }
    static func mono(_ size: CGFloat) -> Font { .custom("JetBrainsMono-Regular", size: size) }
    static func monoBold(_ size: CGFloat) -> Font { .custom("JetBrainsMono-Bold", size: size) }
}

/// The concentric detector-coil mark (ported from the web's .brand-mark CSS).
struct CoilMark: View {
    var size: CGFloat = 22
    var body: some View {
        ZStack {
            Circle().stroke(Workshop.gold, lineWidth: size * 0.09)
            Circle().stroke(Workshop.copper, lineWidth: size * 0.07).padding(size * 0.18)
            Circle().stroke(Workshop.goldBright, lineWidth: size * 0.07).padding(size * 0.34)
            Circle().fill(Workshop.glow).frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct Wordmark: View {
    var size: CGFloat = 15
    var body: some View {
        HStack(spacing: 0) {
            Text("DIG").font(Workshop.wordmark(size)).foregroundStyle(Workshop.cream)
            Text("MAPS").font(Workshop.wordmark(size)).foregroundStyle(Workshop.gold)
            Text(" FIELD").font(Workshop.wordmark(size * 0.72)).foregroundStyle(Workshop.creamDim)
        }
        .kerning(0.5)
    }
}
