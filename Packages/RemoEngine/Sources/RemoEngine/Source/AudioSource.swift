/// A frame source that also captures system audio, which the server streams alongside.
protocol AudioSource: ScreenFrameSource {
    var audioMessages: AsyncThrowingStream<AudioMessage, Error> { get }
}
