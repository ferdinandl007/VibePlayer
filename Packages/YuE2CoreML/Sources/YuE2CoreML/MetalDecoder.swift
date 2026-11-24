import CoreML
import Darwin
import Foundation
import Metal

private struct MetalWeightIndex: Decodable {
    struct Projection: Decodable {
        let packed: Int
        let scale: Int
    }

    let version: Int
    let weightsBytes: Int
    let projections: [Projection]
    let norms: [Int]

    func validate(length: Int) throws {
        guard version == 1, weightsBytes == length,
              projections.count == TensorSpec.layers * 7 + 1,
              norms.count == TensorSpec.layers * 4 + 1 else {
            throw YuE2Failure.assets("Incompatible Metal weight index. Regenerate the index from this bundle.")
        }
        let layerWidths = [(2048, 2048), (1024, 2048), (1024, 2048), (2048, 2048),
                           (6144, 2048), (6144, 2048), (2048, 6144)]
        func fits(_ offset: Int, bytes: Int) -> Bool {
            offset >= 0 && offset % 4 == 0 && offset <= length - bytes
        }
        for (i, p) in projections.enumerated() {
            let (rows, columns) = i == projections.count - 1 ? (TensorSpec.logits, 2048) : layerWidths[i % 7]
            guard fits(p.packed, bytes: rows * columns / 2), fits(p.scale, bytes: rows * columns / 16) else {
                throw YuE2Failure.assets("A Metal projection exceeds its weight file.")
            }
        }
        for (i, offset) in norms.enumerated() {
            let values = i % 4 == 1 || i % 4 == 2 ? 128 : 2048
            guard fits(offset, bytes: values * 2) else {
                throw YuE2Failure.assets("A Metal normalization exceeds its weight file.")
            }
        }
    }
}

private struct DecoderKernels {
    let project: any MTLComputePipelineState
    let rms: any MTLComputePipelineState
    let rotary: any MTLComputePipelineState
    let attend: any MTLComputePipelineState
    let reduce: any MTLComputePipelineState
    let residual: any MTLComputePipelineState
    let gate: any MTLComputePipelineState

    init(_ device: any MTLDevice, paired: Bool) throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let source = bundle.url(forResource: "Decoder", withExtension: "metal") else {
            throw YuE2Failure.assets("Missing Metal decoder kernels.")
        }
        let options = MTLCompileOptions()
        if paired { options.preprocessorMacros = ["YUE2_PAIRED_LAYOUT": NSNumber(value: 1)] }
        let library = try device.makeLibrary(source: String(contentsOf: source, encoding: .utf8), options: options)
        func pipeline(_ name: String) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw YuE2Failure.assets("Missing Metal decoder kernel \(name).")
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            guard pipeline.threadExecutionWidth == 32, pipeline.maxTotalThreadsPerThreadgroup >= 128 else {
                throw YuE2Failure.inference("This GPU does not support the Metal decoder layout.")
            }
            return pipeline
        }
        project = try pipeline(paired ? "project_q4_paired" : "project_q4")
        rms = try pipeline("rms_hidden")
        rotary = try pipeline("rotate_and_append")
        attend = try pipeline("attend_tiles")
        reduce = try pipeline("finish_attention")
        residual = try pipeline("residual")
        gate = try pipeline("activate_gate")
    }
}

final class MetalDecoder {
    let frames: Int
    private let queue: any MTLCommandQueue
    private let kernels: DecoderKernels
    private let weights: any MTLBuffer
    private let index: MetalWeightIndex
    private let keyCache: any MTLBuffer
    private let valueCache: any MTLBuffer
    private let hidden: any MTLBuffer
    private let normalized: any MTLBuffer
    private let query: any MTLBuffer
    private let key: any MTLBuffer
    private let value: any MTLBuffer
    private let attention: any MTLBuffer
    private let residual: any MTLBuffer
    private let gate: any MTLBuffer
    private let up: any MTLBuffer
    private let tileSummary: any MTLBuffer
    private let rope: any MTLBuffer
    private let logits: any MTLBuffer

    init(assets: ModelAssets, capacity: Int, weightFile: URL? = nil, paired: Bool = false) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw YuE2Failure.inference("Metal is unavailable on this device.")
        }
        self.queue = queue
        frames = capacity
        index = try readRecord(MetalWeightIndex.self, at: assets.url("metal-decoder.json"))
        weights = try Self.mapWeights(weightFile ?? assets.url("Autoregressive.mlmodelc/weights/weight.bin"),
                                      index: index, device: device)
        kernels = try DecoderKernels(device, paired: paired)

        func buffer(_ count: Int, options: MTLResourceOptions = .storageModePrivate) throws -> any MTLBuffer {
            guard count <= device.maxBufferLength,
                  let result = device.makeBuffer(length: count, options: options) else {
                throw YuE2Failure.inference("Metal could not allocate a \(count)-byte decoder buffer.")
            }
            return result
        }
        let cacheBytes = TensorSpec.layers * 2 * TensorSpec.heads * capacity * TensorSpec.headSize * 2
        keyCache = try buffer(cacheBytes, options: .storageModeShared)
        valueCache = try buffer(cacheBytes, options: .storageModeShared)
        hidden = try buffer(2 * 2048 * 2, options: .storageModeShared)
        normalized = try buffer(2 * 2048 * 2)
        query = try buffer(2 * 2048 * 2)
        key = try buffer(2 * 1024 * 2)
        value = try buffer(2 * 1024 * 2)
        attention = try buffer(2 * 2048 * 2)
        residual = try buffer(2 * 2048 * 2)
        gate = try buffer(2 * 6144 * 2)
        up = try buffer(2 * 6144 * 2)
        tileSummary = try buffer(32 * ((capacity + 127) / 128) * 130 * 4)
        rope = try buffer(2 * 128 * 2, options: .storageModeShared)
        logits = try buffer(2 * TensorSpec.logits * 2, options: .storageModeShared)
    }

    private static func mapWeights(_ url: URL, index: MetalWeightIndex,
                                   device: any MTLDevice) throws -> any MTLBuffer {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw YuE2Failure.assets("Could not open the shared Metal weights.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw YuE2Failure.assets("Could not inspect the shared Metal weights.") }
        let length = Int(info.st_size)
        try index.validate(length: length)
        let page = Int(getpagesize())
        let aligned = (length + page - 1) / page * page
        guard aligned <= device.maxBufferLength,
              let memory = mmap(nil, aligned, PROT_READ | PROT_WRITE, MAP_PRIVATE, descriptor, 0),
              memory != MAP_FAILED else {
            throw YuE2Failure.assets("Could not map the shared Metal weights.")
        }
        guard let buffer = device.makeBuffer(bytesNoCopy: memory, length: aligned, options: .storageModeShared,
                                             deallocator: { pointer, size in _ = munmap(pointer, size) }) else {
            munmap(memory, aligned)
            throw YuE2Failure.assets("Metal rejected the mapped weight buffer.")
        }
        return buffer
    }

    private func view(_ buffer: any MTLBuffer, shape: [Int]) throws -> MLMultiArray {
        var stride = 1
        let strides = shape.reversed().map { size -> NSNumber in
            defer { stride *= size }
            return NSNumber(value: stride)
        }.reversed()
        return try MLMultiArray(dataPointer: buffer.contents(), shape: shape.map(NSNumber.init(value:)),
                                dataType: .float16, strides: Array(strides))
    }

    func withArray(_ component: CacheComponent, _ body: (MLMultiArray) throws -> Void) throws {
        let buffer = component == .keys ? keyCache : valueCache
        try body(view(buffer, shape: TensorSpec.cache(batch: 2, frames: frames)))
    }

    func predict(embedding: MLMultiArray, sine: MLMultiArray, cosine: MLMultiArray,
                 positions: [Int]) throws -> any MLFeatureProvider {
        let input = try view(hidden, shape: [2, 1, TensorSpec.hidden])
        embedding.transfer(to: input)
        for (index, array) in [sine, cosine].enumerated() {
            array.withUnsafeBufferPointer(ofType: Float16.self) { values in
                let strides = array.strides.map(\.intValue)
                let dest = rope.contents().assumingMemoryBound(to: Float16.self)
                for batch in 0..<2 {
                    for channel in 0..<64 {
                        dest[batch * 128 + index * 64 + channel] = values[batch * strides[0] + channel * strides[3]]
                    }
                }
            }
        }

        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw YuE2Failure.inference("Could not schedule Metal decoder inference.")
        }
        command.label = "YuE2 decode token \(positions[0])"
        let tiles = (max(positions[0], positions[1]) + 128) / 128
        let layerBytes = 2 * TensorSpec.heads * frames * TensorSpec.headSize * 2

        func buffers(_ values: [any MTLBuffer]) {
            for (slot, buffer) in values.enumerated() { encoder.setBuffer(buffer, offset: 0, index: slot) }
        }
        func groups(_ x: Int, _ y: Int = 1, threads: Int = 128) {
            encoder.dispatchThreadgroups(MTLSize(width: x, height: y, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
        }
        func barrier() { encoder.memoryBarrier(scope: .buffers) }
        func project(_ offset: Int, from input: any MTLBuffer, to output: any MTLBuffer,
                     columns: UInt32 = 2048, rows: UInt32 = 2048) {
            encoder.setComputePipelineState(kernels.project)
            let p = index.projections[offset]
            encoder.setBuffer(weights, offset: p.packed, index: 0)
            encoder.setBuffer(weights, offset: p.scale, index: 1)
            encoder.setBuffer(input, offset: 0, index: 2)
            encoder.setBuffer(output, offset: 0, index: 3)
            var shape = SIMD2(columns, rows)
            encoder.setBytes(&shape, length: MemoryLayout.size(ofValue: shape), index: 4)
            groups((Int(rows) + 3) / 4)
        }
        func rms(_ offset: Int) {
            encoder.setComputePipelineState(kernels.rms)
            encoder.setBuffer(hidden, offset: 0, index: 0)
            encoder.setBuffer(weights, offset: index.norms[offset], index: 1)
            encoder.setBuffer(normalized, offset: 0, index: 2)
            var width: UInt32 = 2048
            encoder.setBytes(&width, length: 4, index: 3)
            groups(2)
            barrier()
        }
        func combine(_ kernel: any MTLComputePipelineState, first: any MTLBuffer, second: any MTLBuffer, count: Int) {
            encoder.setComputePipelineState(kernel)
            buffers([first, second])
            groups(count / 128)
            barrier()
        }

        for layer in 0..<TensorSpec.layers {
            let n = layer * 4, p = layer * 7
            let cacheOffset = layer * layerBytes
            rms(n)
            project(p, from: normalized, to: query)
            project(p + 1, from: normalized, to: key, rows: 1024)
            project(p + 2, from: normalized, to: value, rows: 1024)
            barrier()

            encoder.setComputePipelineState(kernels.rotary)
            buffers([query, key, value])
            encoder.setBuffer(keyCache, offset: cacheOffset, index: 3)
            encoder.setBuffer(valueCache, offset: cacheOffset, index: 4)
            encoder.setBuffer(weights, offset: index.norms[n + 1], index: 5)
            encoder.setBuffer(weights, offset: index.norms[n + 2], index: 6)
            encoder.setBuffer(rope, offset: 0, index: 7)
            var context = SIMD4(UInt32(positions[0]), UInt32(positions[1]), UInt32(frames), UInt32(tiles))
            encoder.setBytes(&context, length: MemoryLayout.size(ofValue: context), index: 8)
            groups(24, 2, threads: 32)
            barrier()

            encoder.setComputePipelineState(kernels.attend)
            encoder.setBuffer(query, offset: 0, index: 0)
            encoder.setBuffer(keyCache, offset: cacheOffset, index: 1)
            encoder.setBuffer(valueCache, offset: cacheOffset, index: 2)
            encoder.setBuffer(tileSummary, offset: 0, index: 3)
            encoder.setBytes(&context, length: MemoryLayout.size(ofValue: context), index: 4)
            groups(16, tiles)
            barrier()

            encoder.setComputePipelineState(kernels.reduce)
            buffers([tileSummary, attention])
            var count = UInt32(tiles)
            encoder.setBytes(&count, length: 4, index: 2)
            groups(32)
            barrier()
            project(p + 3, from: attention, to: residual)
            barrier()
            combine(kernels.residual, first: hidden, second: residual, count: 2 * 2048)

            rms(n + 3)
            project(p + 4, from: normalized, to: gate, rows: 6144)
            project(p + 5, from: normalized, to: up, rows: 6144)
            barrier()
            combine(kernels.gate, first: gate, second: up, count: 2 * 6144)
            project(p + 6, from: gate, to: residual, columns: 6144)
            barrier()
            combine(kernels.residual, first: hidden, second: residual, count: 2 * 2048)
        }

        rms(index.norms.count - 1)
        project(index.projections.count - 1, from: normalized, to: logits, rows: UInt32(TensorSpec.logits))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw YuE2Failure.inference(command.error?.localizedDescription ?? "Metal decoder command failed.")
        }
        return try provider(["logits": view(logits, shape: [2, 1, TensorSpec.logits])])
    }
}
