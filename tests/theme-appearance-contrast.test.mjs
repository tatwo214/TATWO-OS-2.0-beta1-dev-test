import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { testScratch } from './helpers/test-scratch.mjs';

test('real theme colors retain contrast through light, dark, light transitions', { skip: process.platform !== 'darwin', timeout: 120_000 }, () => {
  const root = testScratch('tatwo-theme-contrast-');
  const probe = path.join(root, 'Probe.swift');
  fs.writeFileSync(probe, `
import AppKit
import SwiftUI

// Geometry-only dependencies; all tested colors are production sources.
enum LiquidGlassTokens {
    static let shapeStyle = RoundedCornerStyle.continuous
    static let radiusChip: CGFloat = 12
    static let strokeOpacity = 0.2
}
@main struct Probe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = CommandLine.arguments[1]
        func rgb(_ color: Color) -> NSColor { NSColor(color).usingColorSpace(.sRGB)! }
        func luminance(_ c: NSColor, on bg: NSColor) -> Double {
            let alpha = c.alphaComponent
            func linear(_ foreground: CGFloat, _ background: CGFloat) -> Double {
                let v = Double(foreground * alpha + background * (1 - alpha))
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return linear(c.redComponent, bg.redComponent) * 0.2126
                + linear(c.greenComponent, bg.greenComponent) * 0.7152
                + linear(c.blueComponent, bg.blueComponent) * 0.0722
        }
        for theme in TatwoTheme.all {
            let workbench = CLIWorkbenchAppearance.osTheme(theme.palette)
            let sample = VStack(alignment: .leading, spacing: 16) {
                Text("TATWO / " + theme.id.rawValue).font(.title2)
                Text("回覆文字 · Assistant reply").foregroundStyle(workbench.ink)
                Text("次要資訊 · Secondary text").foregroundStyle(workbench.secondaryInk)
                Text("輸入內容 · Composer text").foregroundStyle(Color(nsColor: .labelColor))
                    .padding().frame(maxWidth: .infinity, alignment: .leading).background(workbench.surface)
            }.padding(24).frame(width: 520, height: 240).background(workbench.canvas)
            let host = NSHostingView(rootView: sample)
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 240)
            for (index, name) in [NSAppearance.Name.aqua, .darkAqua, .aqua].enumerated() {
                let appearance = NSAppearance(named: name)!
                host.appearance = appearance
                appearance.performAsCurrentDrawingAppearance {
                    for bg in [rgb(workbench.canvas), rgb(workbench.surface)] {
                        for ink in [rgb(workbench.ink), rgb(workbench.secondaryInk)] {
                            let a = luminance(ink, on: bg), b = luminance(bg, on: bg)
                            let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                            precondition(contrast >= 4.5, "contrast below 4.5: \\(theme.id) \\(name) \\(contrast)")
                        }
                    }
                }
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                let data = rep.representation(using: .png, properties: [:])!
                try data.write(to: URL(fileURLWithPath: output + "/" + theme.id.rawValue + "-" + String(index) + ".png"))
            }
        }
        print("PASS: 24 contrast checks; 6 appearance snapshots")
    }
}
`);
  const build = spawnSync('swiftc', ['-swift-version', '5',
    'App/Sources/Tatwo2/Visual/TatwoTheme.swift', 'App/Sources/Tatwo2/CLI/CLIWorkbenchTheme.swift',
    probe, '-o', path.join(root, 'probe')], { encoding: 'utf8', timeout: 90_000 });
  assert.equal(build.status, 0, build.stdout + build.stderr);
  const result = spawnSync(path.join(root, 'probe'), [root], { encoding: 'utf8', timeout: 20_000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /PASS: 24 contrast checks/);
  for (const theme of ['aurora', 'fable5']) {
    const snapshot = index => fs.readFileSync(path.join(root, `${theme}-${index}.png`));
    assert.deepEqual(snapshot(0), snapshot(2), 'switching back restores the original rendered appearance');
    assert.notDeepEqual(snapshot(0), snapshot(1), 'the retained view redraws on a dark appearance switch');
  }
  console.log(result.stdout.trim(), root);
});
