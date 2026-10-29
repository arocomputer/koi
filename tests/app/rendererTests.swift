import AppKit
import Metal
import QuartzCore
import Testing
@testable import Koi

@MainActor extension SessionTests {
    /// Cursor opacity blends a complete block/inverse layer, preserving text at zero.
    @Test func cursorOpacityAlsoControlsItsInverseGlyph() throws {
        let saved = Config.current
        defer { Config.current = saved }
        Config.current.cursorHeight = 1
        let renderer = try #require(Renderer(metrics: FontMetrics(size: 13, scale: 1)))
        let terminal = VTTerminal(cols: 20, rows: 2)
        terminal.write(Array("A\u{1b}[H\u{1b}[2 q".utf8))
        for opacity in [0.0, 0.5, 1.0] {
            Config.current.cursorOpacity = opacity
            #expect(renderer.prepareFrame(terminal, force: true))
            let glyphs = renderer.quads.filter { $0.kind == 1 }
            #expect(glyphs.count == 1)
            let cursor = renderer.quads.filter { $0.kind == 4 }
            #expect(cursor.count == (opacity == 0 ? 0 : 1))
            if opacity > 0 { #expect(cursor.first?.color.w == Float(opacity)) }
        }
    }

    /// GPU pixels at half opacity must be halfway between cursor-off and
    /// cursor-on, including antialiased glyph edges, rather than darkened twice.
    @Test func blockCursorOpacityInterpolatesTheCompleteGlyphOnTheGPU() throws {
        let saved = Config.current
        defer { Config.current = saved }
        Config.current.cursorHeight = 1
        let renderer = try #require(Renderer(metrics: FontMetrics(size: 13, scale: 1)))
        let terminal = VTTerminal(cols: 20, rows: 2)
        terminal.write(Array("\u{1b}[31mA\u{1b}[H\u{1b}[2 q".utf8))
        let device = renderer.device
        let library = try device.makeLibrary(source: Renderer.shaders, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "quad_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "quad_fragment")
        let attachment = try #require(descriptor.colorAttachments[0])
        attachment.pixelFormat = .rgba16Float
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 32, mipmapped: false)
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget]
        let texture = try #require(device.makeTexture(descriptor: textureDescriptor))
        let queue = try #require(device.makeCommandQueue())
        let bg = Theme.current.background
        let background = SIMD4<Float>(Float(bg.r) / 255, Float(bg.g) / 255, Float(bg.b) / 255, 1)
        func pixels(opacity: Double) throws -> [Float] {
            Config.current.cursorOpacity = opacity
            #expect(renderer.prepareFrame(terminal, force: true))
            let command = try #require(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            let color = try #require(pass.colorAttachments[0])
            color.texture = texture
            color.loadAction = .clear
            color.storeAction = .store
            color.clearColor = MTLClearColorMake(Double(background.x), Double(background.y), Double(background.z), 1)
            let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
            let buffer = try #require(renderer.quads.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            })
            var view = SIMD4<Float>(64, 32, 0, 0), inverse = background
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&view, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setFragmentTexture(renderer.atlas.texture, index: 0)
            encoder.setFragmentBytes(&inverse, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: renderer.quads.count)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            try #require(command.status == .completed)
            var values = [Float16](repeating: 0, count: 64 * 32 * 4)
            values.withUnsafeMutableBytes { bytes in
                texture.getBytes(bytes.baseAddress!, bytesPerRow: 64 * 8, from: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0)
            }
            return values.map(Float.init)
        }
        let off = try pixels(opacity: 0), on = try pixels(opacity: 1), half = try pixels(opacity: 0.5)
        #expect(zip(off, on).contains { abs($0 - $1) > 0.1 }, "the rendered cursor changes actual pixels")
        let error = zip(zip(off, on), half).map { abs(($0.0 + $0.1) / 2 - $1) }.max() ?? 0
        #expect(error < 0.003)
    }
}

/// Pins accounting and completion races without constructing a Metal device.
@Suite struct RendererDiagnosticsTests {
    /// Deferrals are retries, not frames; completion may precede the CPU
    /// timing of its own submission; only valid successful timestamps sample.
    @Test func completionsRetireFlightsInAnyOrderAndOnlyValidTimingsSample() {
        let stats = RenderDiagnosticsStats()
        for reason in [RenderDiagnosticsStats.Deferral.inflight, .noDrawable, .zeroSize, .buffer, .commandBuffer, .encoder, .inflight] {
            stats.deferFrame(reason)
        }
        let deferred = stats.snapshot()
        #expect(deferred.deferred == ["inflight": 2, "noDrawable": 1, "zeroSize": 1, "buffer": 1, "commandBuffer": 1, "encoder": 1])
        #expect(deferred.framesSubmitted == 0 && deferred.framesFailed == 0 && deferred.inFlight == 0)
        let first = stats.submitted()
        stats.completed(first, succeeded: true, gpuStartTime: 1, gpuEndTime: 1.25)
        stats.recordCPUFrame(8, for: first)
        let second = stats.submitted()
        stats.recordCPUFrame(3, for: second)
        let submitted = stats.snapshot()
        #expect(submitted.framesSubmitted == 2)
        #expect(submitted.framesCompleted == 1)
        #expect(submitted.framesFailed == 0)
        #expect(submitted.inFlight == 1)
        #expect(submitted.lastCPUFrameMS == 3)
        #expect(submitted.maxCPUFrameMS == 8)
        #expect(submitted.lastGPUFrameMS == 250)

        stats.completed(second, succeeded: false,
                        error: NSError(domain: MTLCommandBufferErrorDomain, code: 8))
        let completed = stats.snapshot()
        #expect(completed.framesCompleted == 1)
        #expect(completed.framesFailed == 1)
        #expect(completed.inFlight == 0)
        #expect(completed.lastGPUFrameMS == nil)
        #expect(completed.issues.last?.message == "GPU command failed (\(MTLCommandBufferErrorDomain), code 8).")
        let unavailable: [(Double, Double)] = [(0, 0), (0, 1), (-1, 1), (2, 1), (.nan, 3), (1, .infinity)]
        for (start, end) in unavailable {
            stats.completed(stats.submitted(), succeeded: true, gpuStartTime: 1, gpuEndTime: 1.25)
            #expect(stats.snapshot().lastGPUFrameMS == 250)
            stats.completed(stats.submitted(), succeeded: true, gpuStartTime: start, gpuEndTime: end)
            #expect(stats.snapshot().lastGPUFrameMS == nil)
        }
    }

    /// A reset starts a new reporting interval: outstanding flights still
    /// retire but never enter the new counters, even racing from completion threads.
    @Test func resetRetainsFlightsButRejectsTheirOldCountersTimingsAndErrors() async {
        let stats = RenderDiagnosticsStats()
        stats.completed(stats.submitted(), succeeded: true, gpuStartTime: 1, gpuEndTime: 2)
        stats.completed(stats.submitted(), succeeded: false)
        let oldSuccess = stats.submitted()
        let oldFailure = stats.submitted()
        stats.recordCPUFrame(20, for: oldSuccess)
        stats.deferFrame(.buffer)
        stats.atlasOverflow(omittedGlyphs: true)
        stats.reset()
        let reset = stats.snapshot()
        #expect(reset.inFlight == 2)
        #expect(reset.framesSubmitted == 0)
        #expect(reset.framesCompleted == 0)
        #expect(reset.framesFailed == 0)
        #expect(reset.lastCPUFrameMS == nil)
        #expect(reset.maxCPUFrameMS == nil)
        #expect(reset.lastGPUFrameMS == nil)
        #expect(reset.deferred.isEmpty)
        #expect(reset.issues.isEmpty)

        let current = stats.submitted()
        stats.recordCPUFrame(2, for: current)
        stats.completed(oldSuccess, succeeded: true, gpuStartTime: 1, gpuEndTime: 2)
        stats.completed(oldFailure, succeeded: false)
        stats.recordCPUFrame(99, for: oldSuccess)
        let retired = stats.snapshot()
        #expect(retired.inFlight == 1)
        #expect(retired.framesSubmitted == 1)
        #expect(retired.framesCompleted == 0)
        #expect(retired.framesFailed == 0)
        #expect(retired.lastCPUFrameMS == 2)
        #expect(retired.maxCPUFrameMS == 2)
        #expect(retired.lastGPUFrameMS == nil)
        #expect(retired.issues.isEmpty)
        stats.completed(current, succeeded: true)
        #expect(stats.snapshot().inFlight == 0)
        #expect(stats.snapshot().framesCompleted == 1)

        let raced = RenderDiagnosticsStats()
        let submissions = (0..<3).map { _ in raced.submitted() }
        await withTaskGroup(of: Void.self) { group in
            for submission in submissions {
                group.addTask { raced.completed(submission, succeeded: true, gpuStartTime: 1, gpuEndTime: 2) }
            }
            group.addTask { raced.reset() }
        }
        let snapshot = raced.snapshot()
        #expect(snapshot.inFlight == 0 && snapshot.framesSubmitted == 0 && snapshot.framesCompleted == 0)
        #expect(snapshot.lastGPUFrameMS == nil)
    }

    /// Issues keep the sixteen most recent distinct messages, repeats keep
    /// their identity, and driver text never reaches a message.
    @Test func issueHistoryDeduplicatesEvictsAndNeverCopiesDriverText() throws {
        let stats = RenderDiagnosticsStats()
        for code in 0..<16 {
            stats.completed(stats.submitted(), succeeded: false,
                            error: NSError(domain: MTLCommandBufferErrorDomain, code: code))
        }
        let first = try #require(stats.snapshot().issues.first)
        stats.completed(stats.submitted(), succeeded: false,
                        error: NSError(domain: MTLCommandBufferErrorDomain, code: 0))
        let repeated = try #require(stats.snapshot().issues.last)
        #expect(repeated.id == first.id)
        #expect(repeated.count == 2)
        #expect(repeated.timestamp >= first.timestamp)
        stats.completed(stats.submitted(), succeeded: false,
                        error: NSError(domain: MTLCommandBufferErrorDomain, code: 16))
        let issues = stats.snapshot().issues
        #expect(issues.count == 16)
        #expect(issues.first?.message == "GPU command failed (\(MTLCommandBufferErrorDomain), code 2).")
        #expect(issues.contains { $0.id == first.id && $0.count == 2 })

        let foreign = RenderDiagnosticsStats()
        for domain in ["terminal fixture text", "another private fixture"] {
            foreign.completed(foreign.submitted(), succeeded: false,
                              error: NSError(domain: domain, code: 42, userInfo: [NSLocalizedDescriptionKey: "private fixture content"]))
        }
        #expect(foreign.snapshot().issues.map(\.message) == ["GPU command failed (unknown domain, code 42)."])
        #expect(foreign.snapshot().issues.first?.count == 2)
        foreign.completed(foreign.submitted(), succeeded: false)
        #expect(foreign.snapshot().issues.last?.message == "GPU command failed (error details unavailable).")
    }

    @Test func allocationTotalsIncludeReplacedResourcesUntilTheirLastFlightRetires() {
        let stats = RenderDiagnosticsStats()
        let identities = (0..<4).map { _ in NSObject() }
        withExtendedLifetime(identities) {
            let oldAtlas = RenderDiagnosticsStats.Allocation(id: ObjectIdentifier(identities[0]), bytes: 128)
            let oldBuffer = RenderDiagnosticsStats.Allocation(id: ObjectIdentifier(identities[1]), bytes: 64)
            let atlas = RenderDiagnosticsStats.Allocation(id: ObjectIdentifier(identities[2]), bytes: 256)
            let buffer = RenderDiagnosticsStats.Allocation(id: ObjectIdentifier(identities[3]), bytes: 96)
            let first = stats.submitted(atlas: oldAtlas, buffer: oldBuffer)
            let second = stats.submitted(atlas: oldAtlas, buffer: oldBuffer)
            let shared = stats.snapshot(atlas: oldAtlas, buffers: [oldBuffer])
            #expect(shared.atlasBytes == 128)
            #expect(shared.bufferBytes == 64)
            stats.reset()
            let allocated = stats.snapshot(atlas: atlas, buffers: [buffer])
            #expect(allocated.atlasBytes == 384)
            #expect(allocated.bufferBytes == 160)
            stats.completed(first, succeeded: true)
            let stillAllocated = stats.snapshot(atlas: atlas, buffers: [buffer])
            #expect(stillAllocated.atlasBytes == 384)
            #expect(stillAllocated.bufferBytes == 160)
            stats.completed(second, succeeded: true)
            let retired = stats.snapshot(atlas: atlas, buffers: [buffer])
            #expect(retired.atlasBytes == 256)
            #expect(retired.bufferBytes == 96)
        }
    }
}

/// Exercises real atlas exhaustion through the same assembly path used by draw,
/// with small textures so eviction needs neither a window nor thousands of glyphs.
@Suite @MainActor struct RendererTests {
    /// Terminal callbacks and timeout tasks cannot retain a retired renderer.
    @Test func renderHoldCallbackDoesNotKeepItsRendererAlive() throws {
        let terminal = VTTerminal(cols: 20, rows: 2)
        weak var retired: Renderer?
        do {
            let renderer = try renderer()
            retired = renderer
            renderer.bind(to: terminal)
            terminal.write(Array("\u{1b}[?2026h".utf8))
        }
        #expect(retired == nil)
        terminal.write(Array("\u{1b}[?2026l\u{1b}[?2026hA\u{1b}[?2026l".utf8))
        #expect(terminal.text(x: 0, y: 0) == "A")
    }

    /// A split synchronized redraw must not expose its hidden cursor or partial text.
    @Test func synchronizedOutputKeepsTheCompletedFrameUntilRelease() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 20, rows: 2)
        renderer.bind(to: terminal)
        terminal.write(Array("A".utf8))
        #expect(renderer.prepareFrame(terminal))
        let count = renderer.quads.count
        terminal.write(Array("\u{1b}[?2026h\u{1b}[?25l\r\u{1b}[2KB".utf8))
        #expect(!renderer.prepareFrame(terminal))
        #expect(renderer.quads.count == count)
        try expectGlyph(renderer, text: "A", x: 0, y: 0)
        terminal.write(Array("\u{1b}[?25h\u{1b}[?2026l".utf8))
        #expect(renderer.prepareFrame(terminal))
        try expectGlyph(renderer, text: "B", x: 0, y: 0)
    }

    /// Hold boundaries capture completed frames even between writes or inside one write.
    @Test func consecutiveHoldsCaptureTheirOwnPrecedingFrame() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 20, rows: 2)
        renderer.bind(to: terminal)
        terminal.write(Array("A".utf8))
        #expect(renderer.prepareFrame(terminal))
        terminal.write(Array("\rB\u{1b}[?2026h\rC".utf8))
        #expect(renderer.prepareFrame(terminal))
        try expectGlyph(renderer, text: "B", x: 0, y: 0)
        terminal.write(Array("\u{1b}[?2026l\rC\u{1b}[?2026h\rA".utf8))
        #expect(renderer.prepareFrame(terminal))
        try expectGlyph(renderer, text: "C", x: 0, y: 0)
        terminal.write(Array("\u{1b}[?2026l".utf8))
        #expect(renderer.prepareFrame(terminal))
        try expectGlyph(renderer, text: "A", x: 0, y: 0)
    }

    /// Stuck applications release without more output; a later terminal retires the old callback.
    @Test func heldOutputTimesOutAndRebindingRetiresTheOldTerminal() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 20, rows: 2)
        renderer.bind(to: terminal)
        terminal.write(Array("A\u{1b}[?2026h\rB".utf8))
        var wakes = 0
        renderer.onFrameNeeded = { wakes += 1 }
        renderer.expireRenderHold(now: 0)
        #expect(terminal.mode(2026) && wakes == 0)
        renderer.expireRenderHold(now: .greatestFiniteMagnitude)
        #expect(!terminal.mode(2026) && wakes == 1)
        #expect(renderer.prepareFrame(terminal))
        try expectGlyph(renderer, text: "B", x: 0, y: 0)
        renderer.expireRenderHold(now: .greatestFiniteMagnitude)
        #expect(wakes == 1)
        let replacement = VTTerminal(cols: 20, rows: 2)
        renderer.bind(to: replacement)
        terminal.write(Array("\u{1b}[?2026h".utf8))
        replacement.write(Array("C".utf8))
        #expect(renderer.prepareFrame(replacement, force: true))
        try expectGlyph(renderer, text: "C", x: 0, y: 0)
    }

    /// A block cursor composites its inverse above ordinary text in one layer.
    @Test func blockCursorInversionIsAboveTheOriginalGlyph() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 20, rows: 2)
        terminal.write(Array("\u{1b}[31mA\u{1b}[H\u{1b}[2 q".utf8))
        #expect(renderer.prepareFrame(terminal))
        let cursor = try #require(renderer.quads.last)
        #expect(cursor.kind == 4)
        try expectGlyph(renderer, text: "A", x: 0, y: 0)
    }

    /// A reconnect inside synchronized output cannot publish an already partial snapshot.
    @Test func restoringAHeldSnapshotKeepsThePreviousCompletedImage() throws {
        let renderer = try renderer()
        let previous = VTTerminal(cols: 20, rows: 2)
        previous.write(Array("A".utf8))
        #expect(renderer.prepareFrame(previous))
        let partial = VTTerminal(cols: 20, rows: 2)
        partial.write(Array("\u{1b}[?2026hB\u{1b}[?25l".utf8))
        let restored = try #require(VTTerminal(snapshot: partial.snapshot()))
        renderer.bind(to: restored)
        _ = renderer.prepareFrame(restored, force: true)
        try expectGlyph(renderer, text: "A", x: 0, y: 0)
        restored.write(Array("\u{1b}[?25h\u{1b}[?2026l".utf8))
        #expect(renderer.prepareFrame(restored))
        try expectGlyph(renderer, text: "B", x: 0, y: 0)
        let initial = try self.renderer()
        initial.bind(to: partial)
        #expect(!initial.prepareFrame(partial, force: true))
        #expect(initial.quads.isEmpty, "a first attach has no complete frame to expose yet")
    }

    /// Explicit user viewport interaction follows Ghostty's permitted hold-interruption policy.
    @Test func localScrollingCanInterruptARenderHold() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 20, rows: 2)
        renderer.bind(to: terminal)
        terminal.write(Array("A\r\nB\r\nC".utf8))
        #expect(renderer.prepareFrame(terminal))
        terminal.write(Array("\u{1b}[?2026h".utf8))
        terminal.scroll(rows: -1)
        #expect(!terminal.mode(2026))
        #expect(renderer.prepareFrame(terminal))
        #expect(renderer.quads.contains { $0.kind == 3 })
    }

    /// An erased prediction owns the cell beneath its caret; the old grid glyph cannot return.
    @Test func predictedEraseDoesNotResurrectTheCoveredGlyph() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 20, rows: 2)
        terminal.write(Array("A\u{1b}[2 q".utf8))
        renderer.overlay = .init(cells: [.init(x: 0, y: 0, text: " ")], caret: (x: 0, y: 0))
        #expect(renderer.prepareFrame(terminal))
        try expectGlyph(renderer, text: "A", x: 0, y: 0)
        #expect(renderer.quads.last?.kind == 0, "the caret stays above the blank prediction")
    }

    /// Failed completion wakes an idle view and retains the latest frame for retry.
    @Test func failedCompletionRequestsPresentationWithoutMoreOutput() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 20, rows: 2)
        terminal.write(Array("A".utf8))
        #expect(renderer.prepareFrame(terminal))
        var wakes = 0
        renderer.onFrameNeeded = { wakes += 1 }
        renderer.retryFailedPresentation()
        #expect(wakes == 1 && renderer.diagnostics.pendingFrame)
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.drawableSize = .zero
        #expect(!renderer.render(terminal, into: layer))
        #expect(renderer.diagnostics.deferred["zeroSize"] == 1)
    }

    /// Scrolled-back output fades out under the top edge; the live screen
    /// never does, so the first row of a prompt stays crisp.
    @Test func scrollingBackFadesTheTopEdgeOnly() throws {
        let renderer = try renderer()
        renderer.padding = [4, 6]
        let terminal = VTTerminal(cols: 20, rows: 3)
        terminal.write(Array((0..<12).map { "l\($0)" }.joined(separator: "\r\n").utf8))
        #expect(renderer.prepareFrame(terminal, force: true))
        #expect(!renderer.quads.contains { $0.kind == 3 })
        terminal.scroll(rows: -2)
        #expect(renderer.prepareFrame(terminal))
        let fade = try #require(renderer.quads.last)
        #expect(fade.kind == 3 && fade.origin == [-4, -6])
        terminal.scrollToBottom()
        #expect(renderer.prepareFrame(terminal))
        #expect(!renderer.quads.contains { $0.kind == 3 })
    }

    /// A small atlas with room for several ordinary glyphs, but not an ASCII row.
    private func renderer() throws -> Renderer {
        let metrics = FontMetrics(size: 13, scale: 1)
        let pad = max(2, metrics.cellWidth / 2)
        let size = max(metrics.cellWidth + 2 * pad, metrics.cellHeight + 2 * pad) * 2
        return try #require(Renderer(metrics: metrics, atlasSize: size))
    }

    /// Uses distinct offscreen keys to fill the actual packer without evicting.
    private func fill(_ atlas: GlyphAtlas) {
        atlas.beginFrame()
        defer { atlas.endFrame() }
        for i in 0..<1000 {
            if atlas.entry(key("unused-\(i)")) == nil { return }
        }
        Issue.record("Small atlas did not fill")
    }

    private func key(_ text: String) -> GlyphAtlas.Key {
        .init(text: text, bold: false, italic: false, wide: false)
    }

    /// Checks each emitted glyph against its key in the CURRENT texture. Pinning
    /// ensures a missing entry fails the test instead of hiding another eviction.
    private func expectGlyph(_ renderer: Renderer, text: String, x: Int, y: Int,
                             count: Int = 1) throws {
        let atlas = renderer.atlas
        atlas.beginFrame()
        defer { atlas.endFrame() }
        let entry = try #require(atlas.entry(key(text)))
        let origin = SIMD2<Float>(Float(x * atlas.metrics.cellWidth - atlas.pad),
                                  Float(y * atlas.metrics.cellHeight - atlas.pad))
        let glyphs = renderer.quads.filter { $0.kind != 0 && $0.origin == origin }
        #expect(glyphs.count == count)
        for glyph in glyphs {
            #expect(glyph.uvOrigin == SIMD2<Float>(Float(entry.x), Float(entry.y)))
            #expect(glyph.size == SIMD2<Float>(Float(entry.width), Float(entry.height)))
        }
    }

    @Test func overlayEvictionRebuildsCleanRowsAndBlockCursor() throws {
        let renderer = try renderer()
        func expectCursorMask() throws {
            let mask = try #require(renderer.quads.last)
            let glyph = try #require(renderer.quads.first { $0.kind == 1 })
            #expect(mask.kind == 4)
            #expect(mask.uvOrigin == glyph.uvOrigin + mask.origin - glyph.origin)
        }
        let terminal = VTTerminal(cols: 20, rows: 2)
        terminal.write(Array("A\u{1b}[1;1H\u{1b}[2 q".utf8))
        #expect(renderer.prepareFrame(terminal))
        #expect(!renderer.prepareFrame(terminal)) // engine and cursor are clean
        fill(renderer.atlas)
        let generation = renderer.atlas.generation
        let texture = renderer.atlas.texture
        renderer.overlay = .init(cells: [.init(x: 1, y: 0, text: "Z")], caret: (x: 0, y: 0))
        #expect(renderer.prepareFrame(terminal))
        #expect(renderer.atlas.generation == generation + 1)
        #expect(renderer.atlas.texture !== texture)
        try expectGlyph(renderer, text: "A", x: 0, y: 0)
        try expectCursorMask()
        try expectGlyph(renderer, text: "Z", x: 1, y: 0)
        // Removing prediction must keep the rebuilt grid and cursor UVs valid.
        renderer.overlay = .init()
        #expect(renderer.prepareFrame(terminal))
        try expectGlyph(renderer, text: "A", x: 0, y: 0)
        try expectCursorMask()
    }

    @Test func visibleSetLargerThanAtlasStopsAfterOneEviction() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 80, rows: 3)
        let text = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        terminal.write(Array((text + "\r\n" + text + "\u{1b}[?25l").utf8))
        let generation = renderer.atlas.generation
        #expect(renderer.prepareFrame(terminal))
        #expect(renderer.atlas.generation == generation + 1)
        let glyphs = renderer.quads.filter { $0.kind != 0 }
        #expect(renderer.diagnostics.issues.contains {
            $0.message == "Glyph atlas capacity exceeded; some glyphs were omitted."
        })
        #expect(!glyphs.isEmpty)
        #expect(glyphs.count < text.count * 2)
        for glyph in glyphs {
            let x = Int((glyph.origin.x + Float(renderer.atlas.pad)) / Float(renderer.atlas.metrics.cellWidth))
            let y = Int((glyph.origin.y + Float(renderer.atlas.pad)) / Float(renderer.atlas.metrics.cellHeight))
            try expectGlyph(renderer, text: String(Array(text)[x]), x: x, y: y)
        }
        #expect(!renderer.prepareFrame(terminal))
        // Repeated full rebuilds stay bounded and coherent, even though this
        // working set can never fit. No row may retain UVs from a prior retry.
        #expect(renderer.prepareFrame(terminal, force: true))
        #expect(renderer.atlas.generation == generation + 2)
        try expectGlyph(renderer, text: "A", x: 0, y: 0)
        try expectGlyph(renderer, text: "A", x: 0, y: 1)
    }

    @Test func externalEvictionInvalidatesTheNoDirtyFastPath() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 20, rows: 2)
        terminal.write(Array("AB\u{1b}[?25l".utf8))
        #expect(renderer.prepareFrame(terminal))
        #expect(!renderer.prepareFrame(terminal))
        fill(renderer.atlas)
        let texture = renderer.atlas.texture
        let generation = renderer.atlas.generation
        _ = try #require(renderer.atlas.entry(key("evicts")))
        #expect(renderer.atlas.generation == generation + 1)
        #expect(renderer.atlas.texture !== texture)
        #expect(renderer.prepareFrame(terminal))
        try expectGlyph(renderer, text: "A", x: 0, y: 0)
        try expectGlyph(renderer, text: "B", x: 1, y: 0)
    }

    /// An empty snapshot's cursor stays hidden until output arrives; toggling
    /// it is a change the clean-terminal fast path must still draw.
    @Test func hiddenCursorDrawsNoCursorAndRedrawsWhenShown() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 20, rows: 2)
        renderer.hidesCursor = true
        #expect(renderer.prepareFrame(terminal))
        #expect(renderer.quads.isEmpty)
        renderer.hidesCursor = false
        #expect(renderer.prepareFrame(terminal))
        #expect(!renderer.quads.isEmpty)
    }

    /// A zero-size layer keeps terminal and clear frames pending; a second
    /// call still owes a presentation even with a clean terminal.
    @Test func failedPresentationDoesNotConsumeThePendingFrame() throws {
        let renderer = try renderer()
        let terminal = VTTerminal(cols: 20, rows: 2)
        terminal.write(Array("ready".utf8))
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.drawableSize = .zero
        #expect(!renderer.render(terminal, into: layer))
        #expect(!renderer.render(terminal, into: layer))
        let snapshot = renderer.diagnostics
        #expect(snapshot.pendingFrame)
        #expect(snapshot.deferred == ["zeroSize": 2])
        #expect(snapshot.framesSubmitted == 0)
        #expect(snapshot.framesFailed == 0)
        #expect(snapshot.atlasBytes == renderer.atlas.texture.allocatedSize)
        #expect(snapshot.bufferBytes == 0)
        renderer.resetDiagnostics()
        #expect(renderer.diagnostics.pendingFrame)
        #expect(renderer.diagnostics.deferred.isEmpty)
        // Polling sees the layer's current requested size even before a retry.
        layer.drawableSize = CGSize(width: 80, height: 40)
        #expect(renderer.diagnostics.drawableWidth == 80)
        #expect(renderer.diagnostics.drawableHeight == 40)
        // Metal can retain the previous allocation when a sized layer is set
        // back to zero. A fresh unsized layer exercises the actual retry contract.
        let unsized = CAMetalLayer()
        unsized.device = renderer.device
        unsized.drawableSize = .zero
        #expect(!renderer.clear(into: unsized))
        #expect(renderer.diagnostics.pendingFrame)
        #expect(renderer.diagnostics.deferred == ["zeroSize": 1])
    }

    @Test func oversizedGlyphDoesNotRecursivelyReset() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = GlyphAtlas(device: device, metrics: FontMetrics(size: 13, scale: 1), size: 1)
        let texture = atlas.texture
        #expect(atlas.entry(key("A")) == nil)
        #expect(atlas.generation == 0)
        #expect(atlas.texture === texture)
    }
}
