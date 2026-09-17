extends AudioStreamPlayer

const DefaultTrack : String				= "LaJohanne"

var currentTrack : int					= DB.UnknownHash
var soundStream : AudioStreamOggVorbis	= null
var _http : HTTPRequest					= null
var _pendingTrack : int					= DB.UnknownHash
var _pendingCachePath : String			= ""

#
func _ready():
    _http = HTTPRequest.new()
    add_child(_http)
    _http.request_completed.connect(_OnMusicDownloadComplete)

func Stop():
    if is_playing():
        stop()
    currentTrack = DB.UnknownHash
    _pendingTrack = DB.UnknownHash
    _pendingCachePath = ""

func Load(soundID : int):
    if currentTrack != soundID:
        if soundStream:
            soundStream = null
            currentTrack = DB.UnknownHash

        var soundData : FileData = DB.MusicDB.get(soundID, null)
        if not soundData:
            if LauncherCommons.isWeb:
                _StreamMusicFromWeb(soundID)
                return
            Util.PrintLog("Audio", "music track not present: %s" % str(soundID))
            return

        soundStream = soundData._resource as AudioStreamOggVorbis
        if not soundStream:
            Util.PrintLog("Audio", "music stream failed to load: %s" % str(soundData._name))
            return

        soundStream.set_loop(true)
        set_stream(soundStream)
        currentTrack = soundID

        set_autoplay(true)
        play()

func _StreamMusicFromWeb(soundID : int):
    var cacheDir : String = "user://cache/music/"
    DirAccess.make_dir_recursive_absolute(cacheDir)
    var cachePath : String = cacheDir + str(soundID) + ".ogg"

    if FileAccess.file_exists(cachePath):
        var stream : AudioStreamOggVorbis = ResourceLoader.load(cachePath) as AudioStreamOggVorbis
        if stream:
            soundStream = stream
            currentTrack = soundID
            set_stream(stream)
            set_autoplay(true)
            play()
            return

    var serverAddress : String = NetworkCommons.ServerAddress
    if serverAddress.is_empty() or serverAddress == "som.manasource.org":
        Util.PrintLog("Audio", "music streaming skipped: no server address configured")
        return

    var scheme : String = "https" if not LauncherCommons.IsTesting else "http"
    var url : String = "%s://%s/music/%d.ogg" % [scheme, serverAddress, soundID]

    Util.PrintLog("Audio", "streaming music: %s" % url)
    _pendingTrack = soundID
    _pendingCachePath = cachePath
    var err : Error = _http.request(url)
    if err != OK:
        Util.PrintLog("Audio", "music request failed: %s" % err)

func _OnMusicDownloadComplete(result : int, responseCode : int, headers : PackedStringArray, body : PackedByteArray):
    if result != HTTPRequest.RESULT_SUCCESS or responseCode < 200 or responseCode >= 300 or body.is_empty():
        Util.PrintLog("Audio", "music download failed: result=%d code=%d" % [result, responseCode])
        return

    var soundID : int = _pendingTrack
    var cachePath : String = _pendingCachePath
    _pendingTrack = DB.UnknownHash
    _pendingCachePath = ""

    var file : FileAccess = FileAccess.open(cachePath, FileAccess.WRITE)
    if file:
        file.store_buffer(body)
        file.close()

    var stream : AudioStreamOggVorbis = ResourceLoader.load(cachePath) as AudioStreamOggVorbis
    if stream:
        soundStream = stream
        currentTrack = soundID
        set_stream(stream)
        set_autoplay(true)
        play()

func SetVolume(volume : float):
    set_volume_db(volume)

func Warped():
    if Launcher.Map.currentMapNode:
        var mapName : String = Launcher.Map.currentMapNode.get_meta("music", "")
        if not mapName.is_empty():
            Load(mapName.hash())
    else:
        Stop()

func PlayDefault():
    if DB.isInitialized and currentTrack == DB.UnknownHash:
        Load(DefaultTrack.hash())

#
func _post_launch():
    if not Launcher.dbInitialized.is_connected(PlayDefault):
        Launcher.dbInitialized.connect(PlayDefault)
    if Launcher.Map and not Launcher.Map.PlayerWarped.is_connected(Warped):
        Launcher.Map.PlayerWarped.connect(Warped)
        Warped()

func _notification(what):
    if what == NOTIFICATION_PREDELETE:
        if _http and _http.request_completed.is_connected(_OnMusicDownloadComplete):
            _http.request_completed.disconnect(_OnMusicDownloadComplete)
