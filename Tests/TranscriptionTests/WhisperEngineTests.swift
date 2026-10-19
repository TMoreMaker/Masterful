import AVFoundation
import AudioCapture
import Foundation
import MasterfulKit
import Testing
@testable import Transcription

@Suite("Whisper engine")
struct WhisperEngineTests {

    @Test("Silence and stray presses are never transcribed")
    func silence() {
        #expect(WhisperEngine.isSilent([Float](repeating: 0, count: 16_000 * 5)))
        #expect(WhisperEngine.isSilent([Float](repeating: 0.5, count: 1_000)))
        #expect(!WhisperEngine.isSilent([Float](repeating: 0.2, count: 16_000)))
    }

    @Test("The prompt read back as speech is discarded")
    func echo() {
        let prompt = WhisperEngine.prompt(vocabulary: ["Kgodisho", "Lesotho"])
        #expect(WhisperEngine.discardingEcho("Kgodisho, Lesotho.", prompt: prompt) == "")
        #expect(WhisperEngine.discardingEcho("My favourite colour is grey.", prompt: prompt) == "")
        #expect(WhisperEngine.discardingEcho("Kgodisho is from Lesotho.", prompt: prompt) == "Kgodisho is from Lesotho.")
    }

    @Test("The prompt leads with the spelling style, then the names")
    func prompt() {
        #expect(WhisperEngine.prompt(vocabulary: []) == WhisperEngine.stylePrompt)
        #expect(WhisperEngine.prompt(vocabulary: ["Kgodisho", "Lesotho"])
            == WhisperEngine.stylePrompt + " Kgodisho, Lesotho.")
    }
}

/// The real engine on a real recording, through the same calls the coordinator
/// makes. Opt-in: it needs the model on disk, and the first load compiles it.
///
///     MASTERFUL_LIVE_WHISPER=Eval/recordings/spontaneous/<file>.wav \
///     MASTERFUL_LIVE_WHISPER_EXPECT="Lesotho,Kgodisho,favourite" swift test --filter WhisperLive
@Suite("Whisper engine, live",
       .enabled(if: ProcessInfo.processInfo.environment["MASTERFUL_LIVE_WHISPER"] != nil))
struct WhisperLiveTests {

    @Test("A recorded answer comes back with the words it should contain")
    func recording() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MASTERFUL_LIVE_WHISPER"])
        let engine = WhisperEngine()
        let loadStart = Date()
        try await engine.load()
        print("load: \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s")

        let updates = try await engine.beginSession(vocabulary: ["Kgodisho", "Lesotho"])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer, frameCount: 4096)
            await engine.append(CapturedAudio(buffer: buffer))
        }
        let start = Date()
        try await engine.finish()
        var text = ""
        for try await update in updates where update.isFinal { text = update.text }
        print("transcribe: \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        print(text)
        #expect(!text.isEmpty)
        let expected = (ProcessInfo.processInfo.environment["MASTERFUL_LIVE_WHISPER_EXPECT"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for word in expected {
            #expect(text.contains(word), "Expected “\(word)”")
        }
    }
}
