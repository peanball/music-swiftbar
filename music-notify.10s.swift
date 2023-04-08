#! /usr/bin/swift

// metadata
// <xbar.title>iTunes Now Playing Notifier</xbar.title>
// <xbar.version>v0.2.0</xbar.version>
// <xbar.author>Alexander Lais</xbar.author>
// <xbar.author.github>peanball</xbar.author.github>
// <xbar.desc>Uses iTunes notifications for song changes to stream information to SwiftBar</xbar.desc>
// <xbar.abouturl>https://github.com/peanball/music-notify/README.md<xbar.abouturl>
// <xbar.image>https://raw.githubusercontent.com/peanball/music-notify/main/screenshot.png</xbar.image>
// <xbar.dependencies>swift</xbar.dependencies>
// <swiftbar.runInBash>false</swiftbar.runInBash>
// <swiftbar.type>streamable</swiftbar.type>

import AppKit
import CoreGraphics
import Darwin.C
import ScriptingBridge

@objc protocol MusicItem {
    @objc optional var container: SBObject { get }
    // the container of the item
    @objc optional func id() -> NSInteger
    // the id of the item
    @objc optional var index: NSInteger { get }
    // The index of the item in internal application order.
    @objc optional var name: NSString { get set }
    // the name of the item
    @objc optional var persistentID: NSString { get }
    // the id of the item as a hexadecimal string. This id does not change over time.
    @objc optional var properties: NSDictionary { get set }
    // every property of the item
    @objc optional func reveal()
    // reveal and select a track or playlist
}

extension SBObject: MusicItem {}

@objc protocol MusicArtwork: MusicItem {
    // data for this artwork, in the form of a picture
    @objc optional var data: NSImage { get set }

    // description of artwork as a string
    @objc optional var objectDescription: NSString { get set }

    // was this artwork downloaded by iTunes?
    @objc optional var downloaded: Bool { get }

    // the data format for this piece of artwork
    @objc optional var format: NSNumber { get }

    // kind or purpose of this piece of artwork
    @objc optional var kind: NSInteger { get set }

    // data for this artwork, in original format
    @objc optional var rawData: NSData { get set }
}

extension SBObject: MusicArtwork {}

// inspired by https://gist.github.com/pvieito/3aee709b97602bfc44961df575e2b696
@objc protocol MusicTrack {
    @objc var name: String { get }
    @objc var album: String { get }
    @objc var artist: String { get }
    @objc var albumArtist: String { get }
    @objc var year: Int { get }
    @objc var time: String { get }
    @objc optional func artworks() -> [MusicArtwork]
}

@objc protocol MusicApplication {
    var isRunning: Bool { get }
    @objc optional var name: String { get }
    @objc optional var currentStreamTitle: String { get }
    @objc optional var soundVolume: Int { get }
    @objc optional var playerState: Int32 { get }
    @objc optional var currentTrack: MusicTrack { get }
}

extension SBApplication: MusicApplication {}

enum PlayerState: String {
    case Playing = "kPSP"
    case Stopped = "kPSS"
    case Paused = "kPSp"
    case Forward = "kPSF"
    case Rewind = "kPSR"
    case Unknown = ""
}

func state<T>(from value: T) -> PlayerState where T: FixedWidthInteger {
    let bytes = withUnsafeBytes(of: value.bigEndian, Array.init)

    if let s = String(bytes: bytes, encoding: .utf8) {
        if let state = PlayerState(rawValue: s) {
            return state
        }
        print("unknown state \(s)")
    }

    return .Unknown
}

extension NSBitmapImageRep {
    var png: Data? { representation(using: .png, properties: [:]) }
}

extension Data {
    var bitmap: NSBitmapImageRep? { NSBitmapImageRep(data: self) }
}

extension NSImage {
    var png: Data? { tiffRepresentation?.bitmap?.png }
}

extension NSImage {
    func resizedCopy(w: CGFloat, h: CGFloat) -> NSImage {
        let destSize = NSMakeSize(w, h)
        let newImage = NSImage(size: destSize)

        newImage.lockFocus()

        draw(in: NSRect(origin: .zero, size: destSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: CGFloat(1))

        newImage.unlockFocus()

        guard let data = newImage.tiffRepresentation,
              let result = NSImage(data: data)
        else { return NSImage() }
        result.isTemplate = isTemplate
        return result
    }
}

class SwiftBarOutput {
    var dnc: DistributedNotificationCenter
    let logo = "playpause.circle"
    let player: MusicApplication
    let notificationName = Notification.Name("com.apple.iTunes.playerInfo")
    var timer: Timer? = .none
    let fontSize = 12
    // Set logo size explicitly as otherwise the auto-scaling becomes blurry on non-retina screens
    let logoSize = 20
    let artworkSize = CGFloat(75.0)

    init?(_ dnc: DistributedNotificationCenter) {
        self.dnc = dnc

        if let music = SBApplication(bundleIdentifier: "com.apple.Music") {
            player = music
        } else if let itunes = SBApplication(bundleIdentifier: "com.apple.iTunes") {
            player = itunes
        } else {
            return nil
        }

        update()
        self.dnc.addObserver(
            self,
            selector: #selector(handleNotification(_:)),
            name: notificationName,
            object: nil
        )
        pollForUpdate()
    }

    func update() {
        if player.isRunning {
            printFromPlayer()
        } else {
            printEmpty()
        }
    }

    func printFromPlayer() {
        let state = state(from: player.playerState!)
        if state == .Stopped {
            printEmpty()
            return
        }

        let track = player.currentTrack!

        var image: NSImage?
        if let trackArtwork = track.artworks?()[0] {
            image = trackArtwork.data
        }

        printTrack(
            playerState: state, title: track.name, artist: track.artist, albumArtist: track.albumArtist,
            album: track.album, year: track.year > 0 ? track.year : nil, duration: track.time, image: image
        )
    }

    func printTrack(
        playerState: PlayerState, title: String, artist: String, albumArtist: String, album: String,
        year: Int?, duration: String?, image: NSImage?
    ) {
        let playMode = {
            switch playerState {
            case .Paused:
                return "pause.circle"
            case .Playing:
                return "play.circle"
            case .Stopped:
                return "stop.circle"
            case .Forward:
                return "forward.circle"
            case .Rewind:
                return "backward.circle"
            default:
                return ""
            }
        }()

        if artist != "",
           album != "",
           duration != nil
        {
            let displayArtist = albumArtist != "" ? albumArtist : artist
            let optionalYear = year != nil ? " (\(year!))" : ""

            var detail = """
            \(displayArtist) | sfimage=music.mic refresh=true
            \(title) - \(duration!) | sfimage=music.note refresh=true
            \(album)\(optionalYear) | sfimage=play.circle refresh=true
            """
            
            if let swiftbarVersion = ProcessInfo.processInfo.environment["SWIFTBAR_VERSION"], swiftbarVersion >= "1.5.0" {
                let smallImage = image?.resizedCopy(w: artworkSize, h: artworkSize)
                let base64Image = smallImage?.png?.base64EncodedString()
           
                if base64Image != nil {
                    detail = ":music.mic: \(displayArtist)\\n :music.note:   \(title) - \(duration!)\\n:play.circle:  \(album)\(optionalYear) | image=\"\(base64Image!)\" refresh=true"
                }
            }
            printFlush(
                """
                ~~~
                \(title) - *\(artist)* | size=\(fontSize) md=True sfsize=\(fontSize) sfimage=\(playMode) width=\(logoSize) height=\(logoSize)
                ---
                \(detail)
                """)

        } else {
            // print("artist: \(artist) album: \(album) year: \(year ?? -1) duration: \(duration)")
            printFlush(
                """
                ~~~
                \(title) | size=\(fontSize) sfimage=\(playMode) width=\(logoSize) height=\(logoSize)
                """)
        }
    }

    func printEmpty() {
        printFlush(
            """
            ~~~
            | size=\(fontSize) sfimage=\(logo) width=\(logoSize) height=\(logoSize)
            """)
    }

    func printFlush(_ s: Any) {
        print(s)
        fflush(stdout)
    }

    func pollForUpdate() {
        if let _ = timer {
            return
        }

        timer = Timer.scheduledTimer(
            withTimeInterval: 1, repeats: true,
            block: {
                _ in
                self.update()
            }
        )
    }

    func stopPollForUpdate() {
        timer?.invalidate()
        timer = .none
    }

    @objc func handleNotification(_ notification: NSNotification) {
        if let info = notification.userInfo as? [String: Any] {
            let state: PlayerState = {
                switch info["Player State"] as? String {
                case "Playing":
                    return .Playing
                case "Paused":
                    return .Paused
                case "Stopped":
                    return .Stopped
                default:
                    return .Unknown
                }
            }()

            if state == .Stopped || state == .Unknown {
                printEmpty()
                return
            }

            if let _ = info["Name"] as? String,
               let _ = info["Artist"] as? String,
               let _ = info["Album"] as? String
            {
                stopPollForUpdate()
                update()
                return
            } else {
                if let _ = info["Name"] as? String {
                    print(notification)
                    update()
                    if state != .Playing {
                        stopPollForUpdate()
                    } else {
                        pollForUpdate()
                    }
                }
            }
        }
    }

    deinit {
        self.dnc.removeObserver(self)
        print("Deregistering.")
    }
}

var handler = SwiftBarOutput(DistributedNotificationCenter.default())

signal(SIGINT, SIG_IGN) // // Make sure the signal does not terminate the application.

let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler {
    print("Got SIGINT")
    handler = nil
    // ...
    exit(0)
}

sigintSrc.resume()

RunLoop.main.run()
