#! /usr/bin/env python3

# metadata
# <xbar.title>iTunes Now Playing Notifier</xbar.title>
# <xbar.version>v0.1.0</xbar.version>
# <xbar.author>Alexander Lais</xbar.author>
# <xbar.author.github>peanball</xbar.author.github>
# <xbar.desc>Uses iTunes notifications for song changes to stream information to SwiftBar</xbar.desc>
# <xbar.abouturl>https://github.com/peanball/music-notify/README.md<xbar.abouturl>
# <xbar.image>https://raw.githubusercontent.com/peanball/music-notify/main/screenshot.png</xbar.image>
# <xbar.dependencies>python3, </xbar.dependencies>
# <swiftbar.runInBash>false</swiftbar.runInBash>
# <swiftbar.type>streamable</swiftbar.type>

import sys
import re
import Foundation
import PyObjCTools.AppHelper
import objc
import datetime


class MusicNotify(object):
    def __init__(self):
        dnc = Foundation.NSDistributedNotificationCenter.defaultCenter()
        selector = objc.selector(self.receivedNotification_, signature=b"v@:@")
        dnc.addObserver_selector_name_object_(self, selector, "com.apple.iTunes.playerInfo", None)

    def receivedNotification_(self, notification):
        userinfo = dict(notification.userInfo())

        state = userinfo.get("Player State")

        if state == "Stopped":
            print_track(None, state)
            return

        track = {
            'artist': userinfo.get("Artist"),
            'album_artist': userinfo.get("Album Artist"),
            'title': userinfo.get("Name"),
            'album': userinfo.get("Album"),
            'track_number': userinfo.get("Track Number"),
            'duration': userinfo.get("Total Time", 0) // 1000 or None,
            'year': userinfo.get("Year"),
        }

        # print(notification)

        print_track(track, state)


def print_track(track, state):
    if state == "Stopped":
        print_flush("""~~~
♫ :stop.fill: | size=12 sfsize=11
""")
        return

    if track["duration"]:
        delta = datetime.timedelta(seconds=int(track["duration"]))
        stripped_delta = re.sub(r'^0:0?', "", str(delta))
        track["duration_formatted"] = f"({stripped_delta})"

    if not track["album_artist"]:
        track["album_artist"] = track["artist"]

    if not track['artist'] or not track['title']:
        query_itunes_subprocess()
        return

    if state == "Playing":
        play_mode = " :play.fill:"
    elif state == "Paused":
        play_mode = " :pause.fill:"
    elif state == "Paused":
        play_mode = " :stop.fill:"
    else:
        play_mode = ""

    track["state"] = play_mode

    print_flush("""~~~
♫{state} {title} - *{artist}* | size=12 md=True sfsize=11
---
{album} ({year}) | sfimage=play.circle
{title} {duration_formatted} | sfimage=music.note
{album_artist} | sfimage=music.mic
""".format(**track))


def print_flush(*args):
    """
    Flushes after printing. This is needed for the Core Foundation runloop, which buffers aggressively.
    :param args: Arbitrary args passed to print()
    :return: nothing
    """
    print(*args)
    sys.stdout.flush()


def print_empty():
    print_flush("""~~~
♫ ︎ | size=12
""")


def print_running_from_itunes():
    """
    Print the currently running song by querying iTunes/Music via Scripting Bridge
    """
    import ScriptingBridge

    # See https://www.macscripter.net/t/itunes-player-status/26310
    ITUNES_PLAYER_STATE_STOPPED = int.from_bytes(b'kPSS', byteorder="big")
    ITUNES_PLAYER_STATE_PLAYING = int.from_bytes(b'kPSP', byteorder="big")
    ITUNES_PLAYER_STATE_PAUSED = int.from_bytes(b'kPSp', byteorder="big")

    def map_player_state(state: int) -> str:
        if state == ITUNES_PLAYER_STATE_STOPPED:
            return "Stopped"
        elif state == ITUNES_PLAYER_STATE_PLAYING:
            return "Playing"
        elif state == ITUNES_PLAYER_STATE_PAUSED:
            return "Paused"

        return "Unknown"

    player = ScriptingBridge.SBApplication.applicationWithBundleIdentifier_("com.apple.Music")
    if not player:
        player = ScriptingBridge.SBApplication.applicationWithBundleIdentifier_("com.apple.iTunes")

    if not player:
        return

    if not player.isRunning():
        return

    state = map_player_state(player.playerState())

    if state == "Stopped":
        print_track(None, state)
        return

    current_track = player.currentTrack()

    track = {
        'artist': current_track.artist(),
        'album_artist': current_track.albumArtist(),
        'title': current_track.name(),
        'album': current_track.album(),
        'track_number': current_track.trackNumber(),
        'duration': current_track.duration(),
        'year': current_track.year(),
    }

    print_track(track, state)


def query_itunes_subprocess():
    """
    Retrieve the current state from iTunes / Music.

    Launches in a subprocess, so the ScriptingBridge showing a small Python rocket
    does not keep showing forever.
    """
    from multiprocessing import Process

    p = Process(target=print_running_from_itunes, args=())
    p.start()
    p.join()


if __name__ == '__main__':
    print_empty()
    query_itunes_subprocess()
    MusicNotify()
    PyObjCTools.AppHelper.runConsoleEventLoop(installInterrupt=True)
